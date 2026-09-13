import XCTest
@testable import HybridAthlete

final class AdaptationTests: XCTestCase {

    private func context(readiness score: Double,
                         band: ReadinessBand,
                         tsb: Double = 0,
                         acwr: Double = 1.0,
                         confidence: Double = 0.9) -> AdaptationEngine.Context {
        var readiness = ReadinessScore(date: Date())
        readiness.score = score
        readiness.band = band
        readiness.confidence = confidence

        var summary = LoadSummary()
        summary.tsb = tsb
        summary.acwr = acwr
        summary.ctl = 60
        summary.atl = 60 * acwr

        return AdaptationEngine.Context(readiness: readiness, summary: summary,
                                        profile: AthleteProfile(), recentWorkouts: [], phase: .build)
    }

    private var hardSession: PlannedSession {
        PlannedSession(date: Date(), modality: .run, intent: .vo2max,
                       title: "VO2max intervals", details: "",
                       targetDurationMin: 60, targetLoad: 110)
    }

    func testGoodReadinessLeavesThePlanAlone() {
        let adjustment = AdaptationEngine.adjust(hardSession, context: context(readiness: 68, band: .ready))
        XCTAssertEqual(adjustment.action, .keep)
    }

    func testCompromisedReadinessDowngradesIntensityNotJustDuration() {
        let adjustment = AdaptationEngine.adjust(hardSession, context: context(readiness: 30, band: .compromised))
        XCTAssertEqual(adjustment.action, .swap)
        XCTAssertEqual(adjustment.newIntent, .tempo,
                       "A shortened VO2max session still costs what VO2max costs.")
    }

    func testDeepFatiguePlusCompromisedReadinessMeansRest() {
        let adjustment = AdaptationEngine.adjust(hardSession,
                                                 context: context(readiness: 25, band: .compromised, tsb: -32))
        XCTAssertEqual(adjustment.action, .rest)
        XCTAssertEqual(adjustment.newTargetLoad, 0)
    }

    func testLoadSpikeCapsTheSession() {
        let adjustment = AdaptationEngine.adjust(hardSession,
                                                 context: context(readiness: 80, band: .primed, acwr: 1.6))
        XCTAssertEqual(adjustment.action, .reduce)
        XCTAssertLessThan(adjustment.newTargetLoad ?? .infinity, hardSession.targetLoad)
    }

    func testSanitiseRejectsAnUnsafeIncreaseFromClaude() {
        let session = PlannedSession(date: Date(), modality: .run, intent: .easyAerobic,
                                     title: "Easy run", details: "",
                                     targetDurationMin: 45, targetLoad: 45)
        let proposed = SessionAdjustment(action: .increase,
                                         newTitle: "VO2max session",
                                         newDetails: "6x3min hard",
                                         newIntent: .vo2max,
                                         newDurationMin: 90,
                                         newTargetLoad: 140,
                                         reason: "You look great",
                                         source: .claude)

        let safe = AdaptationEngine.sanitise(proposed, for: session,
                                             context: context(readiness: 62, band: .ready))

        XCTAssertEqual(safe.newIntent, .easyAerobic, "Intensity upgrades need a primed athlete.")
        XCTAssertEqual(safe.newTargetLoad ?? 0, session.targetLoad * 1.25, accuracy: 0.01)
        XCTAssertLessThanOrEqual(safe.newDurationMin ?? 0, Int(Double(session.targetDurationMin) * 1.3))
    }

    func testSanitiseBlocksAnIncreaseDuringALoadSpike() {
        let session = PlannedSession(date: Date(), modality: .bike, intent: .easyAerobic,
                                     title: "Zone 2", details: "",
                                     targetDurationMin: 60, targetLoad: 50)
        let proposed = SessionAdjustment(action: .increase, newTargetLoad: 60,
                                         reason: "Add a bit", source: .claude)
        let safe = AdaptationEngine.sanitise(proposed, for: session,
                                             context: context(readiness: 80, band: .primed, acwr: 1.7))
        XCTAssertEqual(safe.action, .keep)
        XCTAssertEqual(safe.newTargetLoad, session.targetLoad)
    }

    func testInterferenceIsFlaggedWhenLiftingFollowsHardEndurance() {
        let now = Date()
        let hardRun = WorkoutRecord(id: "r", start: now.addingTimeInterval(-4 * 3600),
                                    end: now.addingTimeInterval(-3 * 3600),
                                    modality: .run, sourceName: "Suunto",
                                    durationSec: 3600, avgHR: 168, load: 95)
        var ctx = context(readiness: 70, band: .ready)
        ctx.recentWorkouts = [hardRun]

        let lift = PlannedSession(date: now, modality: .strength, intent: .strengthMax,
                                  title: "Heavy squats", details: "",
                                  targetDurationMin: 60, targetLoad: 80)
        let adjustment = AdaptationEngine.adjust(lift, context: ctx)

        XCTAssertNotEqual(adjustment.action, .keep)
        XCTAssertTrue(adjustment.reason.contains("blunts"))
    }
}
