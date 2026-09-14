import XCTest
@testable import HybridAthlete

/// These pin down the two numbers everything else hangs off: the load scale's
/// anchor point, and the fitness/fatigue curves derived from it.
final class TrainingLoadTests: XCTestCase {

    private var profile: AthleteProfile {
        var p = AthleteProfile()
        p.maxHR = 190
        p.restingHR = 50
        p.lactateThresholdHR = 170
        p.usesMaleTrimpCoefficient = true
        return p
    }

    func testThresholdHourIsExactlyOneHundredLoad() {
        let load = TrainingLoadEngine.trimpLoad(avgHR: profile.lactateThresholdHR,
                                                minutes: 60,
                                                profile: profile)
        XCTAssertEqual(load, 100, accuracy: 0.01,
                       "The whole scale is defined by this: an hour at threshold is 100.")
    }

    func testEasierAndLongerSessionsRankSensibly() {
        let easyHour = TrainingLoadEngine.trimpLoad(avgHR: 130, minutes: 60, profile: profile)
        let thresholdHour = TrainingLoadEngine.trimpLoad(avgHR: 170, minutes: 60, profile: profile)
        let easyThreeHours = TrainingLoadEngine.trimpLoad(avgHR: 130, minutes: 180, profile: profile)

        XCTAssertLessThan(easyHour, thresholdHour)
        XCTAssertGreaterThan(easyThreeHours, thresholdHour,
                             "Three easy hours should outweigh one threshold hour.")
    }

    func testTrimpIsLinearInDuration() {
        let thirty = TrainingLoadEngine.trimpLoad(avgHR: 150, minutes: 30, profile: profile)
        let sixty = TrainingLoadEngine.trimpLoad(avgHR: 150, minutes: 60, profile: profile)
        XCTAssertEqual(sixty, thirty * 2, accuracy: 0.001)
    }

    func testStrengthSessionUsesRPENotHeartRate() {
        var workout = WorkoutRecord(id: "t", start: Date(), end: Date().addingTimeInterval(3600),
                                    modality: .strength, sourceName: "Test",
                                    durationSec: 3600, avgHR: 105, rpe: 8)
        let result = TrainingLoadEngine.load(for: workout, profile: profile)
        workout.load = result.value

        XCTAssertEqual(result.method, .sessionRPE)
        // An hour at RPE 8 should land near 114 — well above what a 105 bpm
        // average would score, which is the entire point.
        XCTAssertGreaterThan(workout.load, 100)
    }

    func testEndurancePrefersHeartRateOverRPE() {
        let workout = WorkoutRecord(id: "t", start: Date(), end: Date().addingTimeInterval(3600),
                                    modality: .run, sourceName: "Test",
                                    durationSec: 3600, avgHR: 170, rpe: 3)
        XCTAssertEqual(TrainingLoadEngine.load(for: workout, profile: profile).method, .trimp)
    }

    func testChronicLoadRisesSlowerThanAcuteLoad() {
        let steady = Array(repeating: 60.0, count: 60)
        let atl = TrainingLoadEngine.ewma(steady, timeConstant: 7)
        let ctl = TrainingLoadEngine.ewma(steady, timeConstant: 42)

        XCTAssertGreaterThan(atl[13], ctl[13], "Fatigue must respond faster than fitness.")
        XCTAssertEqual(atl.last ?? 0, 60, accuracy: 1.0, "Both converge on the steady input.")
    }

    func testAcwrFlagsASpike() {
        var days: [DailyMetrics] = []
        let start = Calendar.current.date(byAdding: .day, value: -60, to: Date())!
        for offset in 0..<60 {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: start)!
            var day = DailyMetrics(date: Calendar.current.startOfDay(for: date))
            // Six easy weeks, then a week at four times the load.
            day.trainingLoad = offset < 53 ? 40 : 160
            day.enduranceLoad = day.trainingLoad
            days.append(day)
        }
        let summary = TrainingLoadEngine.summary(from: days)
        XCTAssertGreaterThan(summary.acwr, 1.5)
        XCTAssertEqual(summary.acwrFlag, .high)
    }
}
