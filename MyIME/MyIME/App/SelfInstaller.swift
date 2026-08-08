import AppKit
import Carbon
import os

enum SelfInstaller {
    private static let installedURL = URL(fileURLWithPath: "/Library/Input Methods/MyIME.app", isDirectory: true)
    private static let inputModeID = "fudan.miniS.inputmethod.MyIME.Chinese"

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

    @discardableResult
    private static func register(_ appURL: URL, logger: Logger) -> Bool {
        guard let modes = Bundle(url: appURL)?.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any],
              let modeList = modes["tsInputModeListKey"] as? [String: Any] else { return false }

        let status = TISRegisterInputSource(appURL as CFURL)
        if status != noErr {
            logger.error("输入法注册失败，状态码：\(status)")
            return false
        }
        var enabledModeCount = 0
        for identifier in modeList.keys {
            if isEnabledInputSource(identifier) {
                enabledModeCount += 1
                continue
            }
            let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
            guard let result = TISCreateInputSourceList(filter, true) else { continue }
            for case let source as TISInputSource in result.takeRetainedValue() as NSArray {
                let enableStatus = TISEnableInputSource(source)
                if enableStatus != noErr {
                    logger.error("输入模式启用失败，状态码：\(enableStatus)")
                } else {
                    enabledModeCount += 1
                }
            }
        }
        guard enabledModeCount == modeList.count else { return false }
        logger.notice("MyIME 输入源已经注册并启用")
        return true
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
        guard let source = inputSource(withID: inputModeID) else {
            if enabled {
                return register(installedURL, logger: logger)
            }
            logger.error("找不到 MyIME 输入模式")
            return false
        }
        let status = enabled ? TISEnableInputSource(source) : TISDisableInputSource(source)
        if status != noErr {
            logger.error("输入模式\(enabled ? "启用" : "停用")失败，状态码：\(status)")
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
