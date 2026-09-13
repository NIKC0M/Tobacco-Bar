import Foundation

/// Optional direct link to Suunto's cloud API.
///
/// This exists for athletes who have Suunto partner credentials. It is **off by
/// default and not the recommended path** — Suunto gates API access behind a
/// partner-program agreement, so most individuals cannot get a client ID, and
/// the Apple Health route in `SuuntoLink` carries the same workout data without
/// any approval. Keep it as a second source for people who have access.
///
/// OAuth and base URLs below are taken from Suunto's developer portal
/// (apizone.suunto.com). The *field names* inside a workout object are decoded
/// tolerantly, because that part of the schema is behind the partner login and
/// should be verified against the portal before trusting it.
struct SuuntoCloudClient {

    struct Credentials: Codable, Hashable {
        var clientID: String
        var clientSecret: String
        var subscriptionKey: String
        var redirectURI: String
    }

    struct Tokens: Codable, Hashable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date

        var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
    }

    static let authorizeBase = URL(string: "https://cloudapi-oauth.suunto.com/oauth/authorize")!
    static let tokenURL = URL(string: "https://cloudapi-oauth.suunto.com/oauth/token")!
    static let workoutsURL = URL(string: "https://cloudapi.suunto.com/v2/workouts")!

    var credentials: Credentials
    var session: URLSession = .shared

    // MARK: - OAuth

    func authorizationURL(state: String) -> URL {
        var components = URLComponents(url: Self.authorizeBase, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "redirect_uri", value: credentials.redirectURI),
            .init(name: "state", value: state)
        ]
        return components.url!
    }

    func exchange(code: String) async throws -> Tokens {
        try await token(form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": credentials.redirectURI
        ])
    }

    func refresh(_ tokens: Tokens) async throws -> Tokens {
        guard let refreshToken = tokens.refreshToken else { throw SuuntoError.missingRefreshToken }
        return try await token(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
    }

    private func token(form: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let basic = Data("\(credentials.clientID):\(credentials.clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        request.httpBody = form
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return Tokens(accessToken: decoded.access_token,
                      refreshToken: decoded.refresh_token,
                      expiresAt: Date().addingTimeInterval(decoded.expires_in ?? 3600))
    }

    // MARK: - Workouts

    func workouts(tokens: Tokens, since: Date) async throws -> [WorkoutRecord] {
        var components = URLComponents(url: Self.workoutsURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "since", value: String(Int(since.timeIntervalSince1970 * 1000)))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(tokens.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(credentials.subscriptionKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try Self.decodeWorkouts(from: data)
    }

    /// Tolerant decoding: pulls the first key that matches for each field rather
    /// than pinning one exact schema. Field naming should be confirmed against
    /// the partner documentation; this keeps a rename from silently zeroing a
    /// workout's heart rate and corrupting the load model.
    static func decodeWorkouts(from data: Data) throws -> [WorkoutRecord] {
        let root = try JSONSerialization.jsonObject(with: data)
        let payload = (root as? [String: Any])?["payload"] as? [[String: Any]]
            ?? (root as? [[String: Any]])
            ?? []

        return payload.compactMap { item -> WorkoutRecord? in
            guard let startMillis = number(item, ["startTime", "startTimeMillis", "start"]) else { return nil }
            let start = Date(timeIntervalSince1970: startMillis / 1000)
            let durationSec = number(item, ["totalTime", "duration", "durationSeconds"]) ?? 0
            guard durationSec > 0 else { return nil }

            let key = string(item, ["workoutKey", "id", "workoutId"]) ?? UUID().uuidString
            return WorkoutRecord(
                id: "suunto-\(key)",
                start: start,
                end: start.addingTimeInterval(durationSec),
                modality: modality(forActivityID: number(item, ["activityId", "activityID"]).map { Int($0) }),
                sourceName: "Suunto Cloud",
                durationSec: durationSec,
                distanceMeters: number(item, ["totalDistance", "distance"]),
                avgHR: beatsPerMinute(number(item, ["hravg", "avgHr", "averageHeartRate"])),
                maxHR: beatsPerMinute(number(item, ["hrmax", "maxHr", "maximumHeartRate"])),
                energyKcal: number(item, ["energyConsumption", "energy"]).map { $0 * 0.239006 },
                elevationGainM: number(item, ["totalAscent", "ascent"])
            )
        }
    }

    /// Suunto reports heart rate in beats per second in some fields and bpm in
    /// others. Anything under 5 is treated as bps and converted.
    private static func beatsPerMinute(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value < 5 ? value * 60 : value
    }

    private static func number(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let value = dict[key] as? Double { return value }
            if let value = dict[key] as? Int { return Double(value) }
            if let value = dict[key] as? String, let parsed = Double(value) { return parsed }
        }
        return nil
    }

    private static func string(_ dict: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String { return value }
            if let value = dict[key] as? Int { return String(value) }
        }
        return nil
    }

    /// Suunto activity IDs, mapped to the app's modalities. Unknown IDs fall
    /// through to `.other` and are still counted, just with a generic load rate.
    static func modality(forActivityID id: Int?) -> Modality {
        guard let id else { return .other }
        switch id {
        case 1, 2, 3: return .run          // running variants
        case 4, 5, 6: return .bike         // cycling variants
        case 7, 8: return .swim
        case 9, 10: return .ruck           // hiking / trekking
        case 15: return .row
        case 18, 19: return .strength
        default: return .other
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(500), encoding: .utf8) ?? ""
            throw SuuntoError.http(status: http.statusCode, body: body)
        }
    }
}

enum SuuntoError: LocalizedError {
    case missingRefreshToken
    case http(status: Int, body: String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .missingRefreshToken: return "Suunto session expired and no refresh token is stored. Reconnect."
        case .http(let status, let body): return "Suunto API returned \(status). \(body)"
        case .notConfigured: return "Suunto cloud credentials aren't set. This needs Suunto partner-program access — most athletes should use the Apple Health route instead."
        }
    }
}
