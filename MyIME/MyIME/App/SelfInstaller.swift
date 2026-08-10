import AppKit
import Carbon
import Darwin
import os

enum SelfInstaller {
    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/MyIME.app", isDirectory: true)
    }
    private static let legacySystemURL = URL(
        fileURLWithPath: "/Library/Input Methods/MyIME.app",
        isDirectory: true
    )
    static let inputModeID = "fudan.miniS.inputmethod.MyIME.Chinese"

    static var isRunningInstalledCopy: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            == installedURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static var isCurrentInputSource: Bool {
        currentInputSourceID() == inputModeID
    }

    static var isPostInstallLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains("--post-install")
    }

    static func performCommandIfRequested(logger: Logger) -> Bool {
        guard let command = ProcessInfo.processInfo.arguments.dropFirst().first else { return false }
        switch command {
        case "--register-input-source", "--install":
            _ = ensureRegistered(logger: logger)
        case "--enable-input-source":
            _ = setInputSourceEnabled(true, logger: logger)
        case "--disable-input-source":
            _ = setInputSourceEnabled(false, logger: logger)
        case "--select-input-source":
            // Programmatic TIS selection can leave a visually selected but disconnected IMK
            // session on recent macOS releases. Keep this legacy command registration-only;
            // the user must select MyIME through the system input menu or keyboard shortcut.
            _ = ensureRegistered(logger: logger)
        case "--quit":
            let bundleID = Bundle.main.bundleIdentifier ?? "fudan.miniS.inputmethod.MyIME"
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                .forEach { $0.terminate() }
        default:
            return false
        }
        // 命令模式是短命进程：TIS 的注册/启用变更经 XPC 异步提交，
        // 立即退出会导致变更丢失，退出前稍作等待确保提交完成。
        Thread.sleep(forTimeInterval: 1)
        return true
    }

    static func prepareInstalledCopy(logger: Logger) -> Bool {
        // Unit tests host the app from DerivedData. They must never invoke the privileged
        // self-installer or terminate the XCTest runner while it is bootstrapping.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let installed = installedURL.resolvingSymlinksInPath().standardizedFileURL

        if isRunningInstalledCopy {
            return true
        }

        do {
            try installForCurrentUser(from: current, to: installed)
            try removeLegacySystemCopyIfPresent(logger: logger)
            removeLegacyLoginRegistration(logger: logger)

            // Register from the process the user has already approved through Gatekeeper.
            // A freshly copied development/local build may be rejected when executed from
            // /Library, which previously made the deferred registration silently disappear.
            guard register(installed, logger: logger) else {
                presentRegistrationFailure()
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return false
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "sleep 1; /usr/bin/killall MyIME 2>/dev/null; sleep 1; "
                    + "/usr/bin/open \(shellQuote(installed.path)) --args --post-install"
            ]
            try process.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        } catch {
            logger.error("自动安装失败：\(error.localizedDescription, privacy: .public)")
            presentInstallFailure(error)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        }
    }

    private static func presentInstallFailure(_ error: Error) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "MyIME 自动安装失败"
        alert.informativeText = "没有改动当前已安装的输入法。请重新打开 MyIME.app。若正在从 1.0.8 或更早版本升级，系统会要求管理员密码以移除旧的系统级副本。\n\n错误：\(error.localizedDescription)"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func presentRegistrationFailure() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "MyIME 已复制，但输入法注册失败"
        alert.informativeText = "系统没有识别 ~/Library/Input Methods/MyIME.app，因此它不会出现在输入法列表中。请退出登录并重新登录一次；如果仍未出现，请重新运行安装包。"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    static func ensureRegistered(logger: Logger) -> Bool {
        register(installedURL, logger: logger)
    }

    /// 1.0.7 and earlier installed a login LaunchAgent for registration recovery. On recent
    /// macOS versions it appears as an "App Background Activity" toggle. Disabling that item
    /// can terminate the active IMK service and strand clients such as Notes. Registration is
    /// now completed during installation; macOS owns the only process needed while selected.
    static func removeLegacyLoginRegistration(logger: Logger) {
        let label = "fudan.miniS.inputmethod.MyIME.register"
        let agentDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let agentURL = agentDirectory.appendingPathComponent("\(label).plist")
        guard FileManager.default.fileExists(atPath: agentURL.path) else { return }

        // Removing the file alone leaves the job loaded until the next login. Boot it out so
        // System Settings also stops treating MyIME as a user-managed background activity.
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? launchctl.run()
        launchctl.waitUntilExit()

        do {
            try FileManager.default.removeItem(at: agentURL)
            logger.notice("已移除旧版登录注册 LaunchAgent")
        } catch {
            logger.error("移除旧版 LaunchAgent 失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    @discardableResult
    private static func register(_ appURL: URL, logger: Logger) -> Bool {
        guard let modes = Bundle(url: appURL)?.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any],
              let modeList = modes["tsInputModeListKey"] as? [String: Any] else { return false }

        // 仅在系统尚未发现任一输入模式、或包版本变化（Info.plist 元数据需刷新）时才注册：
        // 对已注册的输入源重复调用 TISRegisterInputSource 会清空其启用状态。
        let versionKey = "LastRegisteredBundleVersion"
        let bundleVersion = Bundle(url: appURL)?.infoDictionary?["CFBundleVersion"] as? String
        let needsRegistration = modeList.keys.contains(where: { inputSource(withID: $0) == nil })
            || UserDefaults.standard.string(forKey: versionKey) != bundleVersion
        if needsRegistration {
            let status = TISRegisterInputSource(appURL as CFURL)
            if status != noErr {
                logger.error("输入法注册失败，状态码：\(status)")
                return false
            }
            UserDefaults.standard.set(bundleVersion, forKey: versionKey)
        }
        // 必须先启用父输入法，但切勿对已启用的源重复调用 TISEnableInputSource：
        // macOS 26 会把每一次调用都视为新的敏感权限请求并再次弹出授权框。
        if let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            let parentFilter = [kTISPropertyInputSourceID as String: bundleID] as CFDictionary
            if let parents = TISCreateInputSourceList(parentFilter, true) {
                for case let source as TISInputSource in parents.takeRetainedValue() as NSArray {
                    if isEnabledInputSource(source) { continue }
                    let parentStatus = TISEnableInputSource(source)
                    if parentStatus != noErr {
                        logger.error("父输入法启用失败，状态码：\(parentStatus)")
                    }
                }
            }
        }
        var registeredModeCount = 0
        var enabledModeCount = 0
        for identifier in modeList.keys {
            let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
            guard let result = TISCreateInputSourceList(filter, true) else { continue }
            let sources = result.takeRetainedValue() as NSArray
            guard sources.count > 0 else { continue }
            registeredModeCount += 1
            var enabled = false
            for case let source as TISInputSource in sources {
                if isEnabledInputSource(source) {
                    enabled = true
                    continue
                }
                let enableStatus = TISEnableInputSource(source)
                if enableStatus != noErr {
                    logger.error("输入模式启用失败，状态码：\(enableStatus)")
                } else {
                    enabled = true
                }
            }
            if enabled { enabledModeCount += 1 }
        }
        guard registeredModeCount == modeList.count else {
            logger.error("输入模式注册不完整：\(registeredModeCount)/\(modeList.count)")
            return false
        }
        if enabledModeCount == modeList.count {
            logger.notice("MyIME 输入源已经注册并启用")
        } else {
            // Registration controls whether MyIME appears in the add-input-source sheet.
            // Enabling is a separate user-authorized operation on recent macOS versions.
            logger.notice("MyIME 输入源已经注册，等待用户启用：\(enabledModeCount)/\(modeList.count)")
        }
        return true
    }

    private static func isEnabledInputSource(_ identifier: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let result = TISCreateInputSourceList(filter, true) else { return false }
        for case let source as TISInputSource in result.takeRetainedValue() as NSArray
            where isEnabledInputSource(source) { return true }
        return false
    }

    private static func isEnabledInputSource(_ source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
              let enabled = unsafeBitCast(pointer, to: CFBoolean?.self) else { return false }
        return CFBooleanGetValue(enabled)
    }

    @discardableResult
    private static func setInputSourceEnabled(_ enabled: Bool, logger: Logger) -> Bool {
        if enabled {
            // 走完整注册路径：父输入法未启用时单独启用子模式会静默失败。
            return register(installedURL, logger: logger)
        }
        guard let source = inputSource(withID: inputModeID) else {
            logger.error("找不到 MyIME 输入模式")
            return false
        }
        let status = TISDisableInputSource(source)
        if status != noErr {
            logger.error("输入模式停用失败，状态码：\(status)")
            return false
        }
        return true
    }

    private static func inputSource(withID identifier: String) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let result = TISCreateInputSourceList(filter, true) else { return nil }
        return (result.takeRetainedValue() as! [TISInputSource]).first
    }

    private static func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return unsafeBitCast(pointer, to: CFString?.self) as String?
    }

    private static func installForCurrentUser(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let installID = UUID().uuidString
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".MyIME-installing-\(installID).app", isDirectory: true)
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".MyIME-previous-\(installID).app", isDirectory: true)

        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        terminateOtherCopies()

        if fileManager.fileExists(atPath: staging.path) { try fileManager.removeItem(at: staging) }
        if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
        try fileManager.copyItem(at: source, to: staging)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.moveItem(at: destination, to: backup)
        }
        do {
            try fileManager.moveItem(at: staging, to: destination)
            if fileManager.fileExists(atPath: backup.path) { try fileManager.removeItem(at: backup) }
        } catch {
            if fileManager.fileExists(atPath: backup.path),
               !fileManager.fileExists(atPath: destination.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private static func terminateOtherCopies() {
        let bundleID = Bundle.main.bundleIdentifier ?? "fudan.miniS.inputmethod.MyIME"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        others.forEach { $0.terminate() }
        Thread.sleep(forTimeInterval: 0.5)
        others.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// 1.0.8 and earlier installed a root-owned system-wide copy. Keeping both copies gives
    /// Text Input Sources two bundles with the same identifier and can leave System Settings
    /// bound to the stale system record. Remove it once during migration; clean installs need
    /// no administrator access.
    private static func removeLegacySystemCopyIfPresent(logger: Logger) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacySystemURL.path) else { return }
        guard Bundle(url: legacySystemURL)?.bundleIdentifier == "fudan.miniS.inputmethod.MyIME" else {
            throw NSError(
                domain: "MyIMESelfInstaller",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "系统输入法目录中存在同名但来源不明的 MyIME.app，未自动删除。"]
            )
        }

        let executable = legacySystemURL.appendingPathComponent("Contents/MacOS/MyIME").path
        let processPattern = "^\(executable)( |$)"
        let command = """
        { /usr/bin/pkill -f \(shellQuote(processPattern)) 2>/dev/null || true; } &&
        /bin/rm -rf \(shellQuote(legacySystemURL.path))
        """
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escapedCommand)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "MyIMESelfInstaller", code: 3, userInfo: error as? [String: Any])
        }
        logger.notice("已移除旧版系统级 MyIME 副本")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
