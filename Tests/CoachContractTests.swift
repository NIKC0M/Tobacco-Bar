import XCTest
@testable import HybridAthlete

/// The Claude integration has one hard contract: the schema we send and the
/// types we decode have to agree. These catch a drift between them without
/// making a network call.
final class CoachContractTests: XCTestCase {

    func testSchemaSerialisesAsValidJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: CoachSchema.responseSchema)
        XCTAssertGreaterThan(data.count, 100)
    }

    func testSchemaEnumsCoverEveryAppValue() throws {
        let schema = CoachSchema.responseSchema
        let properties = schema["properties"] as? [String: Any]
        let today = properties?["today"] as? [String: Any]
        let todayProps = today?["properties"] as? [String: Any]

        let intents = (todayProps?["intent"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(Set(intents ?? []), Set(SessionIntent.allCases.map(\.rawValue)))

        let modalities = (todayProps?["modality"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(Set(modalities ?? []), Set(Modality.allCases.map(\.rawValue)))
    }

    func testASchemaShapedResponseDecodes() throws {
        let json = """
        {
          "summary": "Back off today.",
          "readiness_interpretation": "HRV is 1.8 SD below your 60-day baseline for a third day.",
          "today": {
            "action": "reduce",
            "title": "Easy aerobic run",
            "modality": "run",
            "intent": "easyAerobic",
            "duration_min": 35,
            "target_load": 32,
            "prescription": "35 min in Z2, 128-142 bpm. No surges.",
            "reason": "HRV 1.8 SD low, resting HR up 6 bpm, form at -24."
          },
          "week_adjustments": [
            {
              "date": "2026-09-15",
              "action": "move",
              "title": "Threshold intervals",
              "prescription": "Push to Wednesday, 4x8 min at 165-172 bpm.",
              "reason": "Gives two clear days before the next hard effort."
            }
          ],
          "watch_outs": ["Resting HR elevated three days running — rule out illness."],
          "confidence": "medium"
        }
        """
        let response = try JSONDecoder().decode(CoachResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.today.resolvedAction, .reduce)
        XCTAssertEqual(response.today.resolvedIntent, .easyAerobic)
        XCTAssertEqual(response.today.resolvedModality, .run)
        XCTAssertEqual(response.week_adjustments.first?.resolvedAction, .move)
        XCTAssertNotNil(response.week_adjustments.first?.resolvedDate)
    }

    func testSnapshotIsValidJSONAndCarriesTheKeyBlocks() throws {
        let profile = AthleteProfile()
        let plan = PlanGenerator.plan(for: profile)
        let series = TrainingLoadEngine.dailySeries(workouts: [], recovery: [:], days: 30)
        let summary = TrainingLoadEngine.summary(from: series)
        let readiness = ReadinessEngine.evaluate(series: series, summary: summary, profile: profile)

        let snapshot = CoachPrompt.snapshot(profile: profile, series: series, workouts: [],
                                            summary: summary, readiness: readiness,
                                            plan: plan, athleteNote: "Left knee a bit sore")

        for key in ["\"athlete\"", "\"training_load\"", "\"readiness\"", "\"planned_sessions\"", "athlete_note_today"] {
            XCTAssertTrue(snapshot.contains(key), "Snapshot is missing \(key)")
        }

        // The embedded object must itself be parseable — a malformed snapshot
        // would fail server-side with a confusing error.
        let start = snapshot.firstIndex(of: "{")!
        let end = snapshot.lastIndex(of: "}")!
        let jsonText = String(snapshot[start...end])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(jsonText.utf8)))
    }

    func testSystemPromptIsStableAcrossCalls() {
        // Prompt caching depends on this being byte-identical every time.
        XCTAssertEqual(CoachPrompt.systemPrompt, CoachPrompt.systemPrompt)
        XCTAssertFalse(CoachPrompt.systemPrompt.contains(String(Calendar.current.component(.year, from: Date()))),
                       "No date may leak into the cached prefix.")
    }
}
