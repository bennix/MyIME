//
//  MyIMETests.swift
//  MyIMETests
//
//  Created by Nelle Rtcai on 8/8/26.
//

import Foundation
import Testing
@testable import MyIME

struct MyIMETests {

    @Test func usesStableSimplifiedChineseInputModeIdentifier() {
        #expect(SelfInstaller.inputModeID == "fudan.miniS.inputmethod.MyIME.Chinese")
    }

    @Test func installsForTheCurrentUser() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/MyIME.app", isDirectory: true)
        #expect(SelfInstaller.installedURL == expected)
    }

    @Test func installedCopyDoesNotPreserveQuarantine() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("MyIME-quarantine-test-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source.app", isDirectory: true)
        let destination = root.appendingPathComponent("destination.app", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
        let marker = source.appendingPathComponent("marker.txt")
        try Data("signed bundle payload".utf8).write(to: marker)

        let setAttribute = Process()
        setAttribute.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        setAttribute.arguments = ["-w", "com.apple.quarantine", "0081;test;MyIMETests;", source.path]
        try setAttribute.run()
        setAttribute.waitUntilExit()
        #expect(setAttribute.terminationStatus == 0)

        try SelfInstaller.copyWithoutQuarantine(from: source, to: destination)

        #expect(fileManager.fileExists(atPath: destination.appendingPathComponent("marker.txt").path))
        let readAttribute = Process()
        readAttribute.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        readAttribute.arguments = ["-p", "com.apple.quarantine", destination.path]
        try readAttribute.run()
        readAttribute.waitUntilExit()
        #expect(readAttribute.terminationStatus != 0)
    }

}
