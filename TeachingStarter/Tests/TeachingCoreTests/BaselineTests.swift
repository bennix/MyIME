import Testing
@testable import TeachingCore

@Test func emptyCompositionIsIdle() {
    #expect(CompositionState().raw.isEmpty)
}

@Test func scoreBreakdownUsesRewardsMinusPenalties() {
    var score = ScoreBreakdown()
    score.frequency = 3
    score.user = 2
    score.fuzzy = 1
    #expect(score.total == 4)
}

@Test func releaseChecklistHasCleanMachineEvidence() {
    #expect(ReleaseCheck.allCases.contains(.cleanMacInstall))
    #expect(ReleaseCheck.allCases.contains(.processRecovery))
}
