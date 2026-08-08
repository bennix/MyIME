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
        let server: IMKServer? = if SelfInstaller.isRunningInstalledCopy {
            IMKServer(
                name: Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String,
                bundleIdentifier: Bundle.main.bundleIdentifier
            )
        } else {
            nil
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
        _ = SelfInstaller.ensureRegistered(logger: logger)
        SelfInstaller.ensureLoginRegistration(logger: logger)
        installStatusMenu()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        updateStatusItemVisibility()
        if let message = IMEEnvironment.shared.resourceError {
            logger.error("\(message, privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        updateStatusItemVisibility()
        MyIMEInputController.finalizeStrandedCompositionIfNeeded()
    }

    private func updateStatusItemVisibility() {
        statusItem?.isVisible = SelfInstaller.isCurrentInputSource
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "MyIME")
        let menu = NSMenu()
        menu.addItem(withTitle: "打开设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 MyIME", action: #selector(terminate), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
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
