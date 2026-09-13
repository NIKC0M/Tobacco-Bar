import XCTest
@testable import HybridAthlete

final class ReadinessTests: XCTestCase {

    /// Builds a history with a stable HRV/RHR baseline, then applies `recent`
    /// to the final three days.
    private func history(days: Int = 70,
                         baselineHRV: Double = 60,
                         baselineRHR: Double = 50,
                         sleep: Double = 8,
                         recent: (inout DailyMetrics, Int) -> Void = { _, _ in }) -> [DailyMetrics] {
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: Date())!
        return (0..<days).map { offset in
            let date = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: start)!)
            var day = DailyMetrics(date: date)
            // Small deterministic wobble so the baseline has a non-zero SD.
            let wobble = Double((offset % 5) - 2)
            day.hrvSDNNms = baselineHRV + wobble
            day.restingHR = baselineRHR + wobble * 0.4
            day.sleepHours = sleep
            day.trainingLoad = 50
            day.enduranceLoad = 50
            if offset >= days - 3 { recent(&day, offset) }
            return day
        }
    }

    func testStableAthleteScoresMidToHigh() {
        let series = history()
        let summary = TrainingLoadEngine.summary(from: series)
        let score = ReadinessEngine.evaluate(series: series, summary: summary, profile: AthleteProfile())
        XCTAssertGreaterThan(score.score, 45)
        XCTAssertGreaterThan(score.confidence, 0.7, "70 days of complete data should be trusted.")
    }

    func testSuppressedHRVAndElevatedRestingHRDropTheScore() {
        let baseline = history()
        let stressed = history { day, _ in
            day.hrvSDNNms = 38          // well below a 60 ms baseline
            day.restingHR = 58          // clearly elevated
            day.sleepHours = 5.5
        }
        let baselineScore = ReadinessEngine.evaluate(series: baseline,
                                                     summary: TrainingLoadEngine.summary(from: baseline),
                                                     profile: AthleteProfile())
        let stressedScore = ReadinessEngine.evaluate(series: stressed,
                                                     summary: TrainingLoadEngine.summary(from: stressed),
                                                     profile: AthleteProfile())

        XCTAssertLessThan(stressedScore.score, baselineScore.score - 15)
        XCTAssertTrue([.moderate, .compromised].contains(stressedScore.band))
        XCTAssertNotNil(stressedScore.hrvZ)
        XCTAssertLessThan(stressedScore.hrvZ ?? 0, -1)
    }

    func testShortHistoryReportsLowConfidence() {
        let series = history(days: 8)
        let score = ReadinessEngine.evaluate(series: series,
                                             summary: TrainingLoadEngine.summary(from: series),
                                             profile: AthleteProfile())
        XCTAssertLessThan(score.confidence, 0.5,
                          "Without a baseline the app must say it doesn't know.")
        XCTAssertNil(score.hrvZ)
    }

    func testLowConfidenceDampsTheAdjustment() {
        let thin = history(days: 8) { day, _ in day.hrvSDNNms = 30 }
        let summary = TrainingLoadEngine.summary(from: thin)
        let readiness = ReadinessEngine.evaluate(series: thin, summary: summary, profile: AthleteProfile())

        let session = PlannedSession(date: Date(), modality: .run, intent: .threshold,
                                     title: "Threshold", details: "",
                                     targetDurationMin: 60, targetLoad: 90)
        let context = AdaptationEngine.Context(readiness: readiness, summary: summary,
                                               profile: AthleteProfile(), recentWorkouts: [],
                                               phase: .base)
        let adjustment = AdaptationEngine.adjust(session, context: context)

        if let minutes = adjustment.newDurationMin {
            XCTAssertGreaterThan(minutes, 30, "A thin baseline shouldn't gut the session.")
        }
    }
}
