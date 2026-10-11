import Foundation

/// Supporter licence keys, checked offline. The format is in spec/licence-key.md (the Worker in licence-service/ signs
/// them as JWS with Ed25519; the app only verifies). Core stays Foundation-only, so the signature check itself is injected.
public enum LicenceEnv: String, Sendable, Equatable, Codable, CaseIterable {
    case sandbox, live
}

public struct LicencePayload: Sendable, Equatable, Codable {
    public let v: Int
    public let tier: String
    public let env: LicenceEnv
    public let email: String
    public let txn: String
    public let issued: String
    /// Random licence id: the only thing the app ever sends to the licence service (see `LicenceRevocation`).
    public let id: String
}

public enum LicenceError: Error, Equatable, LocalizedError {
    case malformed
    /// The JWS header isn't exactly `{alg: EdDSA, typ: rackoon-licence+jwt}`.
    case invalidHeader
    case badSignature
    case invalidPayload
    case unsupportedVersion
    /// A valid key, but from an environment this build doesn't honour (a sandbox key in a release build).
    case wrongEnvironment(LicenceEnv)
    /// This build has no public key for the key's environment.
    case noPublicKey(LicenceEnv)

    public var errorDescription: String? {
        switch self {
        case .malformed: "That doesn't look like a Rackoon licence key. Paste the whole key from the email."
        case .invalidHeader: "That isn't a Rackoon licence key."
        case .badSignature: "This key isn't valid: the signature doesn't match. Check that it was copied completely and exactly."
        case .invalidPayload: "This key is damaged or incomplete."
        case .unsupportedVersion: "This key is from a newer version of Rackoon. Update the app and try again."
        case .wrongEnvironment(let env): "This is a \(env.rawValue) key, which this build doesn't accept."
        case .noPublicKey(let env): "This build can't check \(env.rawValue) keys."
        }
    }
}

/// Checks an Ed25519 signature. The Mac app implements it with CryptoKit.
public protocol LicenceSignatureVerifier: Sendable {
    func isValid(signature: Data, message: Data) -> Bool
}

/// A licence key is a standard compact JWS (RFC 7515) with EdDSA/Ed25519 (RFC 8037): `header.payload.signature`, each part
/// base64url without padding. The signature covers the ASCII text `header.payload` exactly as received.
public enum LicenceKey {
    /// The only protected header a key may carry. Anything else (`alg` none or HS256, `crit`, `b64`...) is refused before any
    /// signature work, which closes the classic JWS algorithm-confusion attacks.
    static let typ = "rackoon-licence+jwt"
    static let alg = "EdDSA"

    /// Verifies `text` and returns what it says. `verifiers` holds one per environment this build can check.
    /// Policy (which environments to honour) is `LicenceChecker`'s job, not the format's.
    public static func verify(_ text: String, verifiers: [LicenceEnv: LicenceSignatureVerifier]) throws -> LicencePayload {
        let clean = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        let parts = clean.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerBytes = base64URLDecode(String(parts[0])), let bytes = base64URLDecode(String(parts[1])),
              let signature = base64URLDecode(String(parts[2])), !bytes.isEmpty else { throw LicenceError.malformed }

        guard let header = (try? JSONSerialization.jsonObject(with: headerBytes)) as? [String: Any] else { throw LicenceError.malformed }
        guard header.count == 2, header["alg"] as? String == alg, header["typ"] as? String == typ else { throw LicenceError.invalidHeader }
        guard signature.count == 64 else { throw LicenceError.badSignature }

        // The environment is read from the unverified payload only to pick which public key to check against.
        let claimed = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["env"] as? String
        let candidates = claimed.flatMap(LicenceEnv.init(rawValue:)).map { [$0] } ?? LicenceEnv.allCases
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        var checked = false
        var valid = false
        for env in candidates {
            guard let verifier = verifiers[env] else { continue }
            checked = true
            if verifier.isValid(signature: signature, message: signingInput) { valid = true; break }
        }
        guard valid else {
            if !checked, let env = candidates.first, candidates.count == 1 { throw LicenceError.noPublicKey(env) }
            throw LicenceError.badSignature
        }

        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let version = object["v"] as? Int else {
            throw LicenceError.invalidPayload
        }
        guard version == 1 else { throw LicenceError.unsupportedVersion }
        guard let tier = object["tier"] as? String, tier == "supporter",
              let envName = object["env"] as? String, let env = LicenceEnv(rawValue: envName),
              let email = object["email"] as? String, !email.isEmpty,
              let txn = object["txn"] as? String, !txn.isEmpty,
              let issued = object["issued"] as? String, !issued.isEmpty,
              let id = object["id"] as? String, !id.isEmpty else { throw LicenceError.invalidPayload }
        return LicencePayload(v: 1, tier: tier, env: env, email: email, txn: txn, issued: issued, id: id)
    }

    /// Base64url without padding.
    static func base64URLDecode(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }), text.count % 4 != 1 else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }
}

/// Which environments a build honours and the public key for each.
public struct LicenceChecker: Sendable {
    public let verifiers: [LicenceEnv: LicenceSignatureVerifier]
    public let accepted: Set<LicenceEnv>

    public init(verifiers: [LicenceEnv: LicenceSignatureVerifier], accepted: Set<LicenceEnv>) {
        self.verifiers = verifiers
        self.accepted = accepted
    }

    public func check(_ text: String) throws -> LicencePayload {
        let payload = try LicenceKey.verify(text, verifiers: verifiers)
        guard accepted.contains(payload.env) else { throw LicenceError.wrongEnvironment(payload.env) }
        return payload
    }
}

/// What the licence service says about a key.
public enum LicenceStatus: String, Sendable, Equatable, Codable {
    case active, revoked
}

/// Asks the licence service about a key. nil means "no answer" (offline, timeout, server error), which never counts against
/// the key.
public protocol LicenceStatusChecking: Sendable {
    func status(ofLicence id: String) async -> LicenceStatus?
}

/// The last answer the service gave, kept beside the key.
public struct LicenceStatusRecord: Sendable, Equatable, Codable {
    public let checkedAt: Date
    public let revoked: Bool

    public init(checkedAt: Date, revoked: Bool) {
        self.checkedAt = checkedAt
        self.revoked = revoked
    }
}

/// When to ask and what to do with the answer (spec/licence-key.md, "Revocation"). Pure, so it is tested without a network.
/// The rule that matters: a missing answer never removes a licence (the service being down, or the Mac being offline, must
/// not lock anyone out), and only an explicit "revoked" does.
public enum LicenceRevocation {
    /// Ask at most this often (a refund is rare, and each check is a request to the maintainer's service).
    public static let interval: TimeInterval = 7 * 24 * 3600

    public static func needsCheck(_ record: LicenceStatusRecord?, now: Date) -> Bool {
        guard let record else { return true }
        // A clock set back must not stop checks forever.
        return now.timeIntervalSince(record.checkedAt) >= interval || record.checkedAt > now
    }

    public static func apply(_ answer: LicenceStatus?, previous: LicenceStatusRecord?, now: Date) -> LicenceStatusRecord? {
        guard let answer else { return previous }
        return LicenceStatusRecord(checkedAt: now, revoked: answer == .revoked)
    }
}

/// Where the licence is kept: one small JSON file (`licence.json`, mode 600) next to servers.json. Removing it and pasting a
/// key again is how a licence is removed or replaced. Nothing here decides validity; `LicenceChecker` does, every time.
public struct LicenceVault: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    private struct Stored: Codable {
        var key: String
        var status: LicenceStatusRecord?
    }

    private func read() -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Stored.self, from: data)
    }

    private func write(_ stored: Stored) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(stored).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load() -> String? { read()?.key }

    /// The service's last answer for the stored key, if it has been asked.
    public func loadStatus() -> LicenceStatusRecord? { read()?.status }

    /// Stores the key as typed (whitespace removed), replacing any earlier key and forgetting its status.
    public func save(_ key: String) throws {
        let clean = String(key.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        try write(Stored(key: clean, status: nil))
    }

    public func saveStatus(_ record: LicenceStatusRecord?) throws {
        guard var stored = read() else { return }
        stored.status = record
        try write(stored)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
