import Foundation

/// Supporter licence keys, checked offline. The format is in spec/licence-key.md (the Worker in licence-service/ signs
/// them with Ed25519; the app only verifies). Core stays Foundation-only, so the signature check itself is injected.
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
}

public enum LicenceError: Error, Equatable, LocalizedError {
    case malformed
    case badSignature
    case invalidPayload
    case unsupportedVersion
    /// A valid key, but from an environment this build doesn't honour (a sandbox key in a release build).
    case wrongEnvironment(LicenceEnv)
    /// This build has no public key for the key's environment.
    case noPublicKey(LicenceEnv)

    public var errorDescription: String? {
        switch self {
        case .malformed: "That doesn't look like a Rackoon licence key. Paste the whole key from the email, starting with RKN1-."
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

public enum LicenceKey {
    public static let prefix = "RKN1-"
    static let signDomain = "rackoon-licence-v1\n"

    /// Verifies `text` and returns what it says. `verifiers` holds one per environment this build can check.
    /// Policy (which environments to honour) is `LicenceChecker`'s job, not the format's.
    public static func verify(_ text: String, verifiers: [LicenceEnv: LicenceSignatureVerifier]) throws -> LicencePayload {
        let clean = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        guard clean.hasPrefix(prefix) else { throw LicenceError.malformed }
        let parts = clean.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, let bytes = base64URLDecode(String(parts[0])), let signature = base64URLDecode(String(parts[1])),
              !bytes.isEmpty, signature.count == 64 else { throw LicenceError.malformed }

        // The environment is read from the unverified bytes only to pick which public key to check against.
        let claimed = ((try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any])?["env"] as? String
        let candidates = claimed.flatMap(LicenceEnv.init(rawValue:)).map { [$0] } ?? LicenceEnv.allCases
        let message = Data(signDomain.utf8) + bytes
        var checked = false
        var valid = false
        for env in candidates {
            guard let verifier = verifiers[env] else { continue }
            checked = true
            if verifier.isValid(signature: signature, message: message) { valid = true; break }
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
              let issued = object["issued"] as? String, !issued.isEmpty else { throw LicenceError.invalidPayload }
        return LicencePayload(v: 1, tier: tier, env: env, email: email, txn: txn, issued: issued)
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

/// Where the licence is kept: one small JSON file (`licence.json`, mode 600) next to servers.json. Removing it and pasting a
/// key again is how a licence is removed or replaced. Nothing here decides validity; `LicenceChecker` does, every time.
public struct LicenceVault: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    private struct Stored: Codable { let key: String }

    public func load() -> String? {
        guard let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return stored.key
    }

    /// Stores the key as typed (whitespace removed), replacing any earlier one.
    public func save(_ key: String) throws {
        let clean = String(key.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Stored(key: clean))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
