import CoreFoundation
import Foundation

nonisolated enum AuthResponseValidator {
    // ISO 8601 Internet date-time formatting uses a four-digit Gregorian year.
    private static let maximumISO8601MillisecondsSince1970 = 253_402_300_799_999.0

    struct TimestampFailure: Equatable {
        let code: String
        let serverTimeMs: Double
    }

    static func validate(
        _ data: Data,
        stage: AuthStage,
        attemptId: UUID,
        expectedCarId: String?,
        expectedPairCarId: String?,
        sentAt: Duration,
        receivedAt: Duration
    ) throws -> AuthSession {
        do {
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = nonEmptyString(response["accessToken"]),
                  let tokenType = nonEmptyString(response["tokenType"]), tokenType.caseInsensitiveCompare("Bearer") == .orderedSame,
                  let userId = nonEmptyString(response["userId"]),
                  let carId = nonEmptyString(response["carId"]),
                  let serverTimeMs = finiteNumber(response["serverTime"]), serverTimeMs > 0,
                  let expiresIn = finiteNumber(response["expiresIn"]), expiresIn > 0,
                  let claims = jwtClaims(accessToken),
                  let jwtUserId = nonEmptyString(claims["userId"]), jwtUserId == userId,
                  let jwtCarId = nonEmptyString(claims["carId"]), jwtCarId == carId,
                  let jwtExpiry = finiteNumber(claims["exp"]), jwtExpiry > 0,
                  hasExpectedAudience(claims["aud"]) else {
                throw invalidResponse(stage: stage, attemptId: attemptId)
            }
            if let expectedCarId, carId != expectedCarId {
                throw invalidResponse(stage: stage, attemptId: attemptId)
            }
            if let expectedPairCarId, carId != expectedPairCarId {
                throw invalidResponse(stage: stage, attemptId: attemptId)
            }

            let expiryFromJWT = jwtExpiry * 1_000
            let expiryFromResponse = serverTimeMs + expiresIn * 1_000
            guard expiryFromJWT.isFinite, expiryFromResponse.isFinite,
                  expiryFromJWT <= maximumISO8601MillisecondsSince1970,
                  expiryFromResponse <= maximumISO8601MillisecondsSince1970 else {
                throw invalidResponse(stage: stage, attemptId: attemptId)
            }
            let expiryMs = min(expiryFromJWT, expiryFromResponse)
            let deliveryMs = max(0, durationMilliseconds(receivedAt - sentAt))
            let remainingMs = expiryMs - serverTimeMs - deliveryMs
            guard expiryMs.isFinite, expiryMs > 0,
                  expiryMs <= maximumISO8601MillisecondsSince1970,
                  remainingMs.isFinite, remainingMs > 0,
                  let expiryDate = date(millisecondsSince1970: expiryMs),
                  let deadlineDelta = duration(milliseconds: remainingMs),
                  let expiresAt = iso8601(expiryDate) else {
                throw invalidResponse(stage: stage, attemptId: attemptId)
            }
            return AuthSession(
                accessToken: accessToken,
                userId: userId,
                carId: carId,
                expiresAt: expiresAt,
                deadline: receivedAt + deadlineDelta,
                serverTimeMs: serverTimeMs,
                attemptId: attemptId
            )
        } catch let failure as AuthFailure {
            throw failure
        } catch {
            throw invalidResponse(stage: stage, attemptId: attemptId)
        }
    }

    static func timestampFailure(from data: Data) -> TimestampFailure? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = nonEmptyString(response["code"]), code == "TIMESTAMP_OUT_OF_RANGE",
              let serverTimeMs = finiteNumber(response["serverTime"]), serverTimeMs > 0 else {
            return nil
        }
        return TimestampFailure(code: code, serverTimeMs: serverTimeMs)
    }

    static func serverCode(from data: Data) -> String? {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return nonEmptyString(response["code"])
    }

    static func carId(fromJWT token: String) -> String? {
        guard let claims = jwtClaims(token) else { return nil }
        return nonEmptyString(claims["carId"])
    }

    private static func invalidResponse(stage: AuthStage, attemptId: UUID) -> AuthFailure {
        AuthFailure(
            kind: .invalidResponse,
            stage: stage,
            attemptId: attemptId,
            message: "The authorization response was invalid.",
            httpStatus: 200,
            diagnosticCode: "BAD_RESPONSE"
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    private static func hasExpectedAudience(_ value: Any?) -> Bool {
        if let audience = value as? String { return audience == "zdeep-webview" }
        if let audiences = value as? [String] { return audiences.contains("zdeep-webview") }
        return false
    }

    private static func jwtClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let payloadData = decodeBase64URL(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }
        return claims
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.unicodeScalars.allSatisfy({ scalar in
            (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "-" || scalar == "_"
        }) else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

    private static func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func duration(milliseconds: Double) -> Duration? {
        guard let wholeMilliseconds = int64Floor(milliseconds), wholeMilliseconds > 0 else { return nil }
        return .seconds(wholeMilliseconds / 1_000) + .milliseconds(wholeMilliseconds % 1_000)
    }

    private static func date(millisecondsSince1970 milliseconds: Double) -> Date? {
        let seconds = milliseconds / 1_000
        guard seconds.isFinite, milliseconds <= maximumISO8601MillisecondsSince1970 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func iso8601(_ date: Date) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let value = formatter.string(from: date)
        guard value.count == 20, formatter.date(from: value) != nil else { return nil }
        return value
    }

    private static func int64Floor(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        let roundedDown = value.rounded(.down)
        // Double(Int64.max) rounds up to 2^63, so the upper bound is exclusive.
        guard roundedDown >= Double(Int64.min), roundedDown < Double(Int64.max) else { return nil }
        return Int64(roundedDown)
    }
}
