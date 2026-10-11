import CryptoKit
import Foundation
import Observation
import RackoonCore

/// "Feed the Rackoon": a one-time supporter purchase on Paddle, and the licence key the buyer gets by email. The app has no
/// feature limits; a key only shows a "Supporter" badge. Keys are checked offline (spec/licence-key.md): the app holds
/// public keys only and never talks to Paddle. No API key, SDK or secret lives in the app.
enum Supporter {
    /// SANDBOX hosted checkout (test cards only, no real money). Replace with the live hosted checkout link and price id
    /// before a release; see "Paddle integration" and "Supporter licence" in CLAUDE.md.
    static let checkout = "https://sandbox-pay.paddle.io/hsc_01m4k4jzjr97334wtcpxryqysb_v2857cct1pvnqsc5zamtx1zprr7sdajg"
    /// The €100 one-time "Feed the Rackoon" price (sandbox), passed so the checkout opens on it.
    static let priceID = "pri_01m4k470p76n1yj2nk29rkpvpq"

    /// Raw Ed25519 public keys (base64) that licence keys are checked against. Public by design. The private halves are
    /// Worker secrets. The live key stays nil until the live licence service exists; until then release builds honour nothing.
    static let sandboxPublicKey = "PzIdiJri+SFK6ns1naGMn68/GxbUHlD8buERLdZXdDI="
    static let livePublicKey: String? = nil

    static var url: URL? {
        var parts = URLComponents(string: checkout)
        parts?.queryItems = [URLQueryItem(name: "price_id", value: priceID)]
        return parts?.url
    }

    /// Release builds honour live keys only; dev builds also honour sandbox keys.
    @MainActor static func makeChecker() -> LicenceChecker {
        var verifiers: [LicenceEnv: LicenceSignatureVerifier] = [:]
        if let key = try? CryptoKitVerifier(base64: sandboxPublicKey) { verifiers[.sandbox] = key }
        if let live = livePublicKey, let key = try? CryptoKitVerifier(base64: live) { verifiers[.live] = key }
        return LicenceChecker(verifiers: verifiers, accepted: AppBuild.isDev ? [.live, .sandbox] : [.live])
    }
}

/// Ed25519 check with CryptoKit (Core stays Foundation-only).
struct CryptoKitVerifier: LicenceSignatureVerifier {
    private let key: Curve25519.Signing.PublicKey

    init(base64: String) throws {
        guard let raw = Data(base64Encoded: base64) else { throw LicenceError.invalidPayload }
        key = try Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }

    func isValid(signature: Data, message: Data) -> Bool { key.isValidSignature(signature, for: message) }
}

/// The user's licence: loaded from `licence.json` and re-checked on every launch (a key that stops verifying simply stops
/// counting). Removing it and pasting a key again is the whole lifecycle.
@MainActor @Observable
final class LicenceStore {
    static let shared = LicenceStore()

    enum State: Equatable {
        case none
        case supporter(email: String, env: LicenceEnv)
    }

    private(set) var state: State = .none
    /// Why the stored key no longer counts (for example it came from a build that accepted sandbox keys).
    private(set) var storedProblem: String?
    @ObservationIgnored private let vault: LicenceVault
    @ObservationIgnored private let checker: LicenceChecker

    private init() {
        if Demo.isOn {
            // Demo mode never touches the real licence file.
            vault = LicenceVault(url: FileManager.default.temporaryDirectory.appendingPathComponent("rackoon-demo-licence.json"))
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            vault = LicenceVault(url: base.appendingPathComponent("Rackoon/licence.json"))
        }
        checker = Supporter.makeChecker()
        reload()
    }

    var isSupporter: Bool { if case .supporter = state { true } else { false } }

    func reload() {
        storedProblem = nil
        guard let key = vault.load() else { state = .none; return }
        do {
            let payload = try checker.check(key)
            state = .supporter(email: payload.email, env: payload.env)
        } catch {
            state = .none
            storedProblem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Checks `text` and, if it is good, stores it (replacing any earlier key). Throws a readable error otherwise and
    /// changes nothing.
    func activate(_ text: String) throws {
        _ = try checker.check(text)
        try vault.save(text)
        reload()
    }

    func remove() {
        try? vault.clear()
        reload()
    }
}
