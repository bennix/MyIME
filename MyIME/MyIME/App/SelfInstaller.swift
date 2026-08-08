import AppKit
import Carbon
import os

enum SelfInstaller {
    private static let installedURL = URL(fileURLWithPath: "/Library/Input Methods/MyIME.app", isDirectory: true)

    static func prepareInstalledCopy(logger: Logger) -> Bool {
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let installed = installedURL.resolvingSymlinksInPath().standardizedFileURL

        if current == installed {
            return true
        }

        do {
            try installWithAdministratorPrivileges(from: current, to: installed)
            _ = register(installed, logger: logger)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "sleep 1; /usr/bin/killall MyIME 2>/dev/null; sleep 1; /usr/bin/open \(shellQuote(installed.path))"]
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
        let status = TISRegisterInputSource(appURL as CFURL)
        if status != noErr {
            logger.error("输入法注册失败，状态码：\(status)")
            return false
        }
        guard let modes = Bundle(url: appURL)?.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any],
              let modeList = modes["tsInputModeListKey"] as? [String: Any] else { return false }
        var enabledModeCount = 0
        for identifier in modeList.keys {
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
        logger.notice("输入法已自动注册并启用")
        return true
    }

    private static func installWithAdministratorPrivileges(from source: URL, to destination: URL) throws {
        let userCopy = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/MyIME.app", isDirectory: true)
        let command = [
            "/bin/mkdir -p \(shellQuote(destination.deletingLastPathComponent().path))",
            "/bin/rm -rf \(shellQuote(destination.path))",
            "/usr/bin/ditto \(shellQuote(source.path)) \(shellQuote(destination.path))",
            "/usr/sbin/chown -R root:wheel \(shellQuote(destination.path))",
            "/bin/rm -rf \(shellQuote(userCopy.path))"
        ].joined(separator: " && ")
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
