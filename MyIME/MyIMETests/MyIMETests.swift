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

}
