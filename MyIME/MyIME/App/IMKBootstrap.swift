import AppKit
import InputMethodKit
import IMEKit
import os
import SwiftUI

@MainActor
final class NSManualApplication: NSApplication {
    private let inputMethodDelegate = AppDelegate()

    override init() {
        super.init()
        delegate = inputMethodDelegate
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

@main @MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: IMKServer?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var shouldStartServer = true
    private let logger = Logger(subsystem: "fudan.miniS.MyIME", category: "bootstrap")

    func applicationWillFinishLaunching(_ notification: Notification) {
        shouldStartServer = SelfInstaller.prepareInstalledCopy(logger: logger)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard shouldStartServer else { return }
        _ = IMEEnvironment.shared
        server = IMKServer(name: "MyIME_1_Connection", bundleIdentifier: Bundle.main.bundleIdentifier)
        if !SelfInstaller.ensureRegistered(logger: logger) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [logger] in
                _ = SelfInstaller.ensureRegistered(logger: logger)
            }
        }
        NSApp.setActivationPolicy(.accessory)
        installStatusMenu()
        if let message = IMEEnvironment.shared.resourceError {
            logger.error("\(message, privacy: .public)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

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
