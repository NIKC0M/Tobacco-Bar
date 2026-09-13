import XCTest
@testable import HybridAthlete

final class SuuntoLinkTests: XCTestCase {

    private func workout(source: String, daysAgo: Int) -> WorkoutRecord {
        let end = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return WorkoutRecord(id: UUID().uuidString, start: end.addingTimeInterval(-3600), end: end,
                             modality: .run, sourceName: source, durationSec: 3600)
    }

    func testRecentSuuntoDataIsHealthy() {
        let status = SuuntoLink.status(for: [workout(source: "Suunto", daysAgo: 1)])
        XCTAssertTrue(status.isHealthy)
    }

    func testAGapIsReportedAsStale() {
        let status = SuuntoLink.status(for: [workout(source: "Suunto", daysAgo: 12)])
        guard case .stale(_, let days) = status else { return XCTFail("Expected stale, got \(status)") }
        XCTAssertEqual(days, 12)
    }

    func testOtherSourcesAreNamedWhenSuuntoIsAbsent() {
        let status = SuuntoLink.status(for: [workout(source: "Apple Watch", daysAgo: 1)])
        guard case .noSuuntoData(let others) = status else { return XCTFail("Expected noSuuntoData") }
        XCTAssertEqual(others, ["Apple Watch"])
    }

    func testEmptyHealthKitIsDistinguishedFromAMissingSuunto() {
        XCTAssertEqual(SuuntoLink.status(for: []), .noDataAtAll)
    }

    func testSourceMatchingIsCaseInsensitive() {
        XCTAssertTrue(SuuntoLink.status(for: [workout(source: "SUUNTO App", daysAgo: 0)]).isHealthy)
    }

    func testCloudWorkoutDecodingIsToleratedAcrossFieldNames() throws {
        let json = """
        {"payload":[{"workoutKey":"abc","activityId":1,"startTime":1757700000000,
        "totalTime":3600,"totalDistance":12000,"hravg":2.6,"energyConsumption":2500}]}
        """
        let records = try SuuntoCloudClient.decodeWorkouts(from: Data(json.utf8))
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].modality, .run)
        XCTAssertEqual(records[0].durationSec, 3600)
        // 2.6 beats per second is 156 bpm — the units have to be normalised or
        // every Suunto session would score near-zero load.
        XCTAssertEqual(records[0].avgHR ?? 0, 156, accuracy: 0.5)
    }
}
