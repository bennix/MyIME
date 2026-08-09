import AppKit
import Carbon
import os

enum SelfInstaller {
    private static let installedURL = URL(fileURLWithPath: "/Library/Input Methods/MyIME.app", isDirectory: true)
    private static let inputModeID = "fudan.miniS.inputmethod.MyIME.Chinese"
    private static let needsClientRebindKey = "NeedsClientRebind"

    static var isRunningInstalledCopy: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            == installedURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static var isCurrentInputSource: Bool {
        currentInputSourceID() == inputModeID
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
            _ = selectInputSource(logger: logger)
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
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let installed = installedURL.resolvingSymlinksInPath().standardizedFileURL

        if isRunningInstalledCopy {
            return true
        }

        do {
            try installWithAdministratorPrivileges(from: current, to: installed)
            // 旧进程被 kill 后，仍选中 MyIME 的 App 会持有死会话；新进程注册完后重绑前台客户端。
            UserDefaults.standard.set(true, forKey: needsClientRebindKey)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            let executable = installed.appendingPathComponent("Contents/MacOS/MyIME").path
            process.arguments = [
                "-c",
                "sleep 1; /usr/bin/killall MyIME 2>/dev/null; sleep 1; \(shellQuote(executable)) --register-input-source"
            ]
            try process.run()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return false
        } catch {
            logger.error("自动安装失败：\(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    static func ensureRegistered(logger: Logger) -> Bool {
        register(installedURL, logger: logger)
    }

    /// 安装登录时自动运行 `--register-input-source` 的 LaunchAgent，
    /// 保证重启后输入源的注册与启用不依赖系统缓存状态。
    static func ensureLoginRegistration(logger: Logger) {
        let agentDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let agentURL = agentDirectory.appendingPathComponent("fudan.miniS.inputmethod.MyIME.register.plist")
        let plist: [String: Any] = [
            "Label": "fudan.miniS.inputmethod.MyIME.register",
            "ProgramArguments": [
                installedURL.appendingPathComponent("Contents/MacOS/MyIME").path,
                "--register-input-source",
            ],
            "RunAtLoad": true,
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            if (try? Data(contentsOf: agentURL)) == data { return }
            try FileManager.default.createDirectory(at: agentDirectory, withIntermediateDirectories: true)
            try data.write(to: agentURL)
            logger.notice("已安装登录自动注册 LaunchAgent")
        } catch {
            logger.error("安装 LaunchAgent 失败：\(error.localizedDescription, privacy: .public)")
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
            UserDefaults.standard.set(true, forKey: needsClientRebindKey)
        }
        // 必须先启用父输入法：重启后系统启用列表可能被清空，
        // 而子模式只有在父源已启用时才能真正被启用（否则静默失败）。
        if let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            let parentFilter = [kTISPropertyInputSourceID as String: bundleID] as CFDictionary
            if let parents = TISCreateInputSourceList(parentFilter, true) {
                for case let source as TISInputSource in parents.takeRetainedValue() as NSArray {
                    let parentStatus = TISEnableInputSource(source)
                    if parentStatus != noErr {
                        logger.error("父输入法启用失败，状态码：\(parentStatus)")
                    }
                }
            }
        }
        var enabledModeCount = 0
        for identifier in modeList.keys {
            // 不依赖 kTISPropertyInputSourceIsEnabled：重启后该标记可能残留为
            // “已启用”，而实际启用列表已丢失。重复启用已启用的源是无害的。
            let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
            guard let result = TISCreateInputSourceList(filter, true) else { continue }
            var enabled = false
            for case let source as TISInputSource in result.takeRetainedValue() as NSArray {
                let enableStatus = TISEnableInputSource(source)
                if enableStatus != noErr {
                    logger.error("输入模式启用失败，状态码：\(enableStatus)")
                } else {
                    enabled = true
                }
            }
            if enabled { enabledModeCount += 1 }
        }
        guard enabledModeCount == modeList.count else { return false }
        logger.notice("MyIME 输入源已经注册并启用")
        if UserDefaults.standard.bool(forKey: needsClientRebindKey) {
            rebindFrontmostClient(logger: logger)
            UserDefaults.standard.set(false, forKey: needsClientRebindKey)
        }
        return true
    }

    /// 前台 App 在 MyIME 进程被替换后常持有失效 IMK 连接。短暂切到 ABC 再切回，强制重连。
    private static func rebindFrontmostClient(logger: Logger) {
        guard isCurrentInputSource else { return }
        guard let myIME = inputSource(withID: inputModeID) else { return }
        let abcCandidates = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        var fallback: TISInputSource?
        for identifier in abcCandidates {
            let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
            if let list = TISCreateInputSourceList(filter, true),
               let source = (list.takeRetainedValue() as! [TISInputSource]).first {
                fallback = source
                break
            }
        }
        guard let fallback else {
            logger.error("找不到 ABC/US 键盘，跳过客户端重绑")
            return
        }
        let away = TISSelectInputSource(fallback)
        if away != noErr {
            logger.error("切换到后备键盘失败，状态码：\(away)")
            return
        }
        Thread.sleep(forTimeInterval: 0.2)
        let back = TISSelectInputSource(myIME)
        if back != noErr {
            logger.error("重选 MyIME 失败，状态码：\(back)")
            return
        }
        logger.notice("已重绑前台输入客户端")
    }

    private static func isEnabledInputSource(_ identifier: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let result = TISCreateInputSourceList(filter, true) else { return false }
        for case let source as TISInputSource in result.takeRetainedValue() as NSArray {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled),
                  let enabled = unsafeBitCast(pointer, to: CFBoolean?.self),
                  CFBooleanGetValue(enabled) else { continue }
            return true
        }
        return false
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

    @discardableResult
    private static func selectInputSource(logger: Logger) -> Bool {
        guard let source = inputSource(withID: inputModeID) else {
            logger.error("找不到 MyIME 输入模式")
            return false
        }
        guard isEnabledInputSource(inputModeID) else {
            logger.error("MyIME 尚未启用")
            return false
        }
        let status = TISSelectInputSource(source)
        if status != noErr {
            logger.error("选择 MyIME 失败，状态码：\(status)")
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

    private static func installWithAdministratorPrivileges(from source: URL, to destination: URL) throws {
        let userCopy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/MyIME.app", isDirectory: true)
        let installID = UUID().uuidString
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".MyIME-installing-\(installID).app", isDirectory: true)
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".MyIME-previous-\(installID).app", isDirectory: true)
        let command = """
        /bin/mkdir -p \(shellQuote(destination.deletingLastPathComponent().path)) &&
        /bin/rm -rf \(shellQuote(staging.path)) \(shellQuote(backup.path)) &&
        /usr/bin/ditto \(shellQuote(source.path)) \(shellQuote(staging.path)) &&
        /usr/sbin/chown -R root:wheel \(shellQuote(staging.path)) &&
        { if [ -e \(shellQuote(destination.path)) ]; then /bin/mv \(shellQuote(destination.path)) \(shellQuote(backup.path)); fi; } &&
        { if /bin/mv \(shellQuote(staging.path)) \(shellQuote(destination.path)); then
            /bin/rm -rf \(shellQuote(backup.path));
          else
            if [ -e \(shellQuote(backup.path)) ]; then /bin/mv \(shellQuote(backup.path)) \(shellQuote(destination.path)); fi;
            exit 1;
          fi; } &&
        /bin/rm -rf \(shellQuote(userCopy.path))
        """
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "do shell script \"\(escapedCommand)\" with administrator privileges")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "MyIMESelfInstaller", code: 1, userInfo: error as? [String: Any])
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
