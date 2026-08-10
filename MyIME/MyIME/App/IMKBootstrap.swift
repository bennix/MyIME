import AppKit
import Carbon
import InputMethodKit
import IMEKit
import os
import SwiftUI

@main @MainActor
struct MyIMEApplication {
    static func main() {
        let logger = Logger(subsystem: "fudan.miniS.MyIME", category: "command")
        if SelfInstaller.performCommandIfRequested(logger: logger) {
            return
        }
        let server: IMKServer?
        if SelfInstaller.isRunningInstalledCopy,
           let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String {
            server = IMKServer(name: connectionName, bundleIdentifier: Bundle.main.bundleIdentifier)
        } else {
            server = nil
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(server: server)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

private struct EmptyStore: CandidateLookup {
    func lookup(pinyinKey: String, initials: String, disabledSourceMask: Int, limit: Int) -> [StoreEntry] { [] }
    func userBoost(word: String, pinyin: String) -> Double { 0 }
    func bigramBoost(previous: String?, word: String) -> Double { 0 }
}

final class IMEEnvironment {
    static let shared = IMEEnvironment()

    let systemStore: SQLiteStore?
    let userStore: UserStore?
    let engine: Engine
    let resourceError: String?

    private init() {
        userStore = UserStore(path: RuntimePaths.userDatabase)
        let replacement = RuntimePaths.replacementSystemDatabase
        let path = FileManager.default.fileExists(atPath: replacement)
            ? replacement
            : Bundle.main.path(forResource: "system", ofType: "sqlite")
        if let path,
           let store = SQLiteStore(path: path), store.integrityCheck() {
            systemStore = store
            resourceError = nil
            engine = Engine(store: store, userStore: userStore)
        } else {
            systemStore = nil
            resourceError = "内置词库缺失或损坏，当前仅能使用英文直通。"
            engine = Engine(store: EmptyStore(), userStore: userStore)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let server: IMKServer?
    private var statusItem: NSStatusItem?
    private var switchInputSourceItem: NSMenuItem?
    private var settingsWindow: NSWindow?
    private var shouldStartServer = true
    private let logger = Logger(subsystem: "fudan.miniS.MyIME", category: "bootstrap")

    init(server: IMKServer?) {
        self.server = server
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        shouldStartServer = SelfInstaller.prepareInstalledCopy(logger: logger)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldStartServer else { return }
        guard server != nil else {
            logger.error("已安装输入法未能建立 IMK 服务")
            return
        }
        _ = IMEEnvironment.shared
        let registered = SelfInstaller.ensureRegistered(logger: logger)
        SelfInstaller.removeLegacyLoginRegistration(logger: logger)
        installStatusMenu()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        updateStatusMenu()
        if SelfInstaller.isPostInstallLaunch {
            let selected = registered && SelfInstaller.isCurrentInputSource
            updateStatusMenu()
            presentPostInstallResult(selected: selected)
        }
        if let message = IMEEnvironment.shared.resourceError {
            logger.error("\(message, privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        updateStatusMenu()
        MyIMEInputController.finalizeStrandedCompositionIfNeeded()
    }

    private func updateStatusMenu() {
        // Keep this recovery entry visible even when the system input menu has lost MyIME.
        statusItem?.isVisible = true
        let isCurrent = SelfInstaller.isCurrentInputSource
        // Show real TIS state — a permanent "中" misleads when Notes has fallen back to ABC.
        statusItem?.button?.title = isCurrent ? "中" : "A"
        statusItem?.button?.toolTip = isCurrent ? "MyIME 已选中" : "MyIME 未选中（当前为其他输入源）"
        switchInputSourceItem?.title = isCurrent
            ? "MyIME 已连接"
            : "如何切换到 MyIME…"
        switchInputSourceItem?.isEnabled = !isCurrent
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A 16 pt line-art icon is easy to miss or collapse among modern macOS status items.
        // Keep the recovery entry unmistakable even when the system input menu loses MyIME.
        item.button?.image = nil
        item.button?.title = SelfInstaller.isCurrentInputSource ? "中" : "A"
        item.button?.font = .boldSystemFont(ofSize: 14)
        item.button?.setAccessibilityLabel("MyIME 中文输入法")
        item.button?.toolTip = "MyIME 输入法"
        let menu = NSMenu()
        let switchItem = menu.addItem(
            withTitle: "如何切换到 MyIME…",
            action: #selector(showInputSourceHelp),
            keyEquivalent: ""
        )
        switchInputSourceItem = switchItem
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MyIME", action: #selector(terminate), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func presentPostInstallResult(selected: Bool) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = selected ? .informational : .warning
        alert.messageText = selected ? "MyIME 已安装并切换" : "MyIME 已安装，等待系统授权"
        alert.informativeText = selected
            ? "现在可以在 Notes、文本编辑、微信、WPS 和浏览器中直接输入中文。菜单栏的“中 / A”是 MyIME 的恢复入口。"
            : "请在系统弹出的安全窗口中点“允许”，或到“系统设置 → 键盘 → 文本输入 → 编辑”启用 MyIME。完成后通过系统输入法菜单或 Control–空格切换到 MyIME。"
        alert.addButton(withTitle: selected ? "开始使用" : "打开键盘设置")
        if !selected {
            alert.addButton(withTitle: "稍后")
        }
        let response = alert.runModal()
        if !selected, response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func showInputSourceHelp() {
        let alert = NSAlert()
        alert.messageText = "请通过 macOS 切换到 MyIME"
        alert.informativeText = "按 Control–空格，或点击 macOS 菜单栏的系统输入法图标并选择 MyIME。系统完成切换后会建立新的中文输入会话。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开键盘设置")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MyIME 设置"
            window.minSize = NSSize(width: 760, height: 600)
            window.contentViewController = NSHostingController(
                rootView: SettingsView().frame(minWidth: 760, minHeight: 600)
            )
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func terminate() {
        NSApp.terminate(nil)
    }
}
