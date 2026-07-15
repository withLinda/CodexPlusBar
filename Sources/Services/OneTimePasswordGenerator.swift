import CryptoKit
import Foundation

enum OneTimePasswordError: Error, Equatable, Sendable {
    case invalidSecret
}

struct TOTPGenerator: Sendable {
    private struct ParsedSecret: Sendable {
        let value: String
        let digits: Int?
        let period: Int?
    }

    private let secretBytes: [UInt8]
    private let digits: Int
    private let period: Int

    init(
        secret: String,
        digits: Int? = nil,
        period: Int? = nil
    ) throws {
        let parsedSecret = try Self.parsedSecret(from: secret)
        let resolvedDigits = digits ?? parsedSecret.digits ?? 6
        let resolvedPeriod = period ?? parsedSecret.period ?? 30

        guard (6...8).contains(resolvedDigits), resolvedPeriod > 0 else {
            throw OneTimePasswordError.invalidSecret
        }

        secretBytes = try Self.decodeBase32(parsedSecret.value)
        self.digits = resolvedDigits
        self.period = resolvedPeriod
    }

    func code(at date: Date = .now) -> String {
        let counter = UInt64(max(0, Int(date.timeIntervalSince1970)) / period)
        var bigEndianCounter = counter.bigEndian
        let counterData = withUnsafeBytes(of: &bigEndianCounter) { Data($0) }
        let key = SymmetricKey(data: Data(secretBytes))
        let hash = Array(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key))
        let offset = Int(hash[hash.count - 1] & 0x0F)
        let binaryCode = ((Int(hash[offset]) & 0x7F) << 24)
            | ((Int(hash[offset + 1]) & 0xFF) << 16)
            | ((Int(hash[offset + 2]) & 0xFF) << 8)
            | (Int(hash[offset + 3]) & 0xFF)
        let divisor = Int(pow(10.0, Double(digits)))
        let value = binaryCode % divisor

        let rawCode = String(value)
        return String(repeating: "0", count: max(digits - rawCode.count, 0)) + rawCode
    }

    func secondsRemaining(at date: Date = .now) -> Int {
        let elapsed = max(0, Int(date.timeIntervalSince1970)) % period
        let remaining = period - elapsed
        return remaining == 0 ? period : remaining
    }

    private static func parsedSecret(from rawValue: String) throws -> ParsedSecret {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw OneTimePasswordError.invalidSecret
        }

        let candidate: String
        let digits: Int?
        let period: Int?
        if let components = URLComponents(string: trimmed),
           components.scheme?.lowercased() == "otpauth",
           let queryItems = components.queryItems,
           let secret = queryItems.first(where: { $0.name.lowercased() == "secret" })?.value {
            candidate = secret
            digits = try optionalPositiveInt(named: "digits", in: queryItems)
            period = try optionalPositiveInt(named: "period", in: queryItems)
        } else if let components = URLComponents(string: trimmed),
                  Self.isTwoFALiveHost(components.host),
                  let secret = Self.twoFALiveTokenSecret(from: components.path) {
            candidate = secret
            digits = nil
            period = nil
        } else {
            candidate = trimmed
            digits = nil
            period = nil
        }

        let normalized = candidate
            .uppercased()
            .filter { character in
                character.isWhitespace == false
                    && character != "-"
                    && character != "="
            }

        guard normalized.isEmpty == false,
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw OneTimePasswordError.invalidSecret
        }

        return ParsedSecret(value: normalized, digits: digits, period: period)
    }

    private static func isTwoFALiveHost(_ host: String?) -> Bool {
        guard let normalizedHost = host?.lowercased() else {
            return false
        }

        return normalizedHost == "2fa.live" || normalizedHost.hasSuffix(".2fa.live")
    }

    private static func twoFALiveTokenSecret(from path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "tok" else {
            return nil
        }

        return String(parts[1])
    }

    private static func optionalPositiveInt(named name: String, in queryItems: [URLQueryItem]) throws -> Int? {
        guard let rawValue = queryItems.first(where: { $0.name.lowercased() == name })?.value else {
            return nil
        }

        guard let value = Int(rawValue), value > 0 else {
            throw OneTimePasswordError.invalidSecret
        }

        return value
    }

    private static func decodeBase32(_ value: String) throws -> [UInt8] {
        var buffer = 0
        var bitsLeft = 0
        var bytes: [UInt8] = []

        for scalar in value.unicodeScalars {
            let decodedValue: Int
            switch scalar.value {
            case 65...90:
                decodedValue = Int(scalar.value - 65)
            case 50...55:
                decodedValue = Int(scalar.value - 24)
            default:
                throw OneTimePasswordError.invalidSecret
            }

            buffer = (buffer << 5) | decodedValue
            bitsLeft += 5

            if bitsLeft >= 8 {
                bitsLeft -= 8
                bytes.append(UInt8((buffer >> bitsLeft) & 0xFF))
                buffer &= (1 << bitsLeft) - 1
            }
        }

        guard bytes.isEmpty == false else {
            throw OneTimePasswordError.invalidSecret
        }

        return bytes
    }
}
