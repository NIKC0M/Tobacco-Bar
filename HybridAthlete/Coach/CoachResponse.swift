import Foundation

/// What Claude is contractually required to return. The JSON schema below is
/// sent with the request via `output_config.format`, so these types decode
/// without defensive parsing.
struct CoachResponse: Codable, Hashable {
    var summary: String
    var readiness_interpretation: String
    var today: CoachPrescription
    var week_adjustments: [CoachWeekAdjustment]
    var watch_outs: [String]
    var confidence: String

    var confidenceLevel: String { confidence }
}

struct CoachPrescription: Codable, Hashable {
    var action: String          // keep | reduce | increase | swap | rest
    var title: String
    var modality: String
    var intent: String
    var duration_min: Int
    var target_load: Double
    var prescription: String
    var reason: String

    var resolvedAction: AdjustmentAction { AdjustmentAction(rawValue: action) ?? .keep }
    var resolvedModality: Modality { Modality(rawValue: modality) ?? .other }
    var resolvedIntent: SessionIntent { SessionIntent(rawValue: intent) ?? .easyAerobic }
}

struct CoachWeekAdjustment: Codable, Hashable, Identifiable {
    var date: String            // yyyy-MM-dd
    var action: String
    var title: String
    var prescription: String
    var reason: String

    var id: String { date + action + title }
    var resolvedAction: AdjustmentAction { AdjustmentAction(rawValue: action) ?? .keep }

    var resolvedDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: date)
    }
}

enum CoachSchema {
    /// JSON Schema handed to `output_config.format`. Enums are pinned to the
    /// app's own raw values so the reply maps straight onto `SessionIntent` and
    /// `AdjustmentAction` with no string guessing.
    static var responseSchema: [String: Any] {
        let prescription: [String: Any] = [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": ["keep", "reduce", "increase", "swap", "rest"]],
                "title": ["type": "string"],
                "modality": ["type": "string", "enum": Modality.allCases.map(\.rawValue)],
                "intent": ["type": "string", "enum": SessionIntent.allCases.map(\.rawValue)],
                "duration_min": ["type": "integer", "minimum": 0, "maximum": 300],
                "target_load": ["type": "number", "minimum": 0, "maximum": 400],
                "prescription": [
                    "type": "string",
                    "description": "Exactly what to do: warm-up, work, recovery, cues. Specific numbers, no hedging."
                ],
                "reason": [
                    "type": "string",
                    "description": "One or two sentences citing the specific metrics that drove this decision."
                ]
            ],
            "required": ["action", "title", "modality", "intent", "duration_min", "target_load", "prescription", "reason"],
            "additionalProperties": false
        ]

        let weekAdjustment: [String: Any] = [
            "type": "object",
            "properties": [
                "date": ["type": "string", "description": "yyyy-MM-dd, must match a planned session date"],
                "action": ["type": "string", "enum": ["keep", "reduce", "increase", "swap", "rest", "move"]],
                "title": ["type": "string"],
                "prescription": ["type": "string"],
                "reason": ["type": "string"]
            ],
            "required": ["date", "action", "title", "prescription", "reason"],
            "additionalProperties": false
        ]

        return [
            "type": "object",
            "properties": [
                "summary": [
                    "type": "string",
                    "description": "Two or three sentences the athlete reads first thing in the morning."
                ],
                "readiness_interpretation": [
                    "type": "string",
                    "description": "What the recovery signals mean today, in plain language. Say when the data is too thin to conclude anything."
                ],
                "today": prescription,
                "week_adjustments": [
                    "type": "array",
                    "items": weekAdjustment,
                    "maxItems": 7,
                    "description": "Changes to the remaining planned sessions this week. Empty array if the rest of the week stands."
                ],
                "watch_outs": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 4,
                    "description": "Specific things to monitor, e.g. a metric trend or an injury risk. Empty if nothing stands out."
                ],
                "confidence": [
                    "type": "string",
                    "enum": ["high", "medium", "low"],
                    "description": "low whenever the baseline is short, data is missing, or signals conflict."
                ]
            ],
            "required": ["summary", "readiness_interpretation", "today", "week_adjustments", "watch_outs", "confidence"],
            "additionalProperties": false
        ]
    }
}
