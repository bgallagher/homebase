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

    /// Where the licence service answers `GET /status/<licence id>` (one deployment per Paddle environment). nil until the
    /// service is deployed: then nothing is ever asked and keys are checked offline only. Set these after `wrangler deploy`.
    static let sandboxServiceURL: URL? = URL(string: "https://rackoon-licence.gallagher-brian.workers.dev")
    static let liveServiceURL: URL? = nil

    static func serviceURL(for env: LicenceEnv) -> URL? { env == .live ? liveServiceURL : sandboxServiceURL }

    /// The hosted checkout's "Redirect URL" (Paddle > Settings > Hosted checkouts) is `<scheme>://purchase-complete`: after paying,
    /// the browser hands the buyer back to the app, which says to check the email. Dev and stable builds use different schemes.
    static var returnScheme: String { AppBuild.isDev ? "rackoon-dev" : "rackoon" }
    static let returnHost = "purchase-complete"

    static var url: URL? {
        var parts = URLComponents(string: checkout)
        // theme: the dark checkout matches the app. variant=express: one-click wallets first (Apple Pay needs domain verification
        // to be one-click). Both are optional hosted-checkout query parameters (developer.paddle.com/paddle-js/about/hosted-checkout).
        parts?.queryItems = [
            URLQueryItem(name: "price_id", value: priceID),
            URLQueryItem(name: "theme", value: "dark"),
            URLQueryItem(name: "variant", value: "express"),
        ]
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

/// Asks the licence service whether a key was refunded. Sends only the random licence id (no email, no machine details, no
/// cookies); anything but a clear answer is "no answer", which never counts against the key.
struct ServiceStatusChecker: LicenceStatusChecking {
    let base: URL

    func status(ofLicence id: String) async -> LicenceStatus? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.httpCookieStorage = nil
        guard let url = URL(string: "status/\(id)", relativeTo: base)?.absoluteURL, url.scheme == "https",
              let (data, response) = try? await URLSession(configuration: configuration).data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let word = object["status"] as? String else { return nil }
        return LicenceStatus(rawValue: word)
    }
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
    /// The buyer just came back from the checkout: the licence window says "payment successful, check your email".
    private(set) var purchaseReturned = false
    /// Why the stored key no longer counts (for example it came from a build that accepted sandbox keys).
    private(set) var storedProblem: String?
    @ObservationIgnored private let vault: LicenceVault
    @ObservationIgnored private let checker: LicenceChecker
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Replaced in tests of the policy; production asks the service for the key's environment.
    @ObservationIgnored var statusChecker: (LicenceEnv) -> LicenceStatusChecking? = { env in
        Supporter.serviceURL(for: env).map { ServiceStatusChecker(base: $0) }
    }

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
    /// A key is saved (even one that no longer counts), so it can be removed.
    var hasKey: Bool { vault.load() != nil }

    func reload() {
        storedProblem = nil
        guard let key = vault.load() else { state = .none; return }
        do {
            let payload = try checker.check(key)
            if vault.loadStatus()?.revoked == true {
                state = .none
                storedProblem = "This key was refunded, so it no longer counts as a supporter licence."
            } else {
                state = .supporter(email: payload.email, env: payload.env)
            }
            refreshStatus(of: payload)
        } catch {
            state = .none
            storedProblem = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// Called when the checkout redirects back to the app. Carries no data and trusts nothing from the link: it only makes the
    /// licence window show a thank-you message, so any other program opening the link can do no harm.
    func purchaseCompleted() { purchaseReturned = true }
    func dismissPurchaseNote() { purchaseReturned = false }

    /// Asks the licence service about the key if it has not been asked for a week. Never blocks, never throws: only an
    /// explicit "revoked" changes anything (see `LicenceRevocation`).
    private func refreshStatus(of payload: LicencePayload) {
        guard !Demo.isOn, LicenceRevocation.needsCheck(vault.loadStatus(), now: Date()),
              let service = statusChecker(payload.env) else { return }
        statusTask?.cancel()
        statusTask = Task { [vault] in
            let answer = await service.status(ofLicence: payload.id)
            guard !Task.isCancelled, vault.load() != nil else { return }
            let record = LicenceRevocation.apply(answer, previous: vault.loadStatus(), now: Date())
            guard record != vault.loadStatus() else { return }
            try? vault.saveStatus(record)
            reload()
        }
    }

    /// Checks `text` and, if it is good, stores it (replacing any earlier key). Throws a readable error otherwise and
    /// changes nothing.
    func activate(_ text: String) throws {
        _ = try checker.check(text)
        try vault.save(text)
        purchaseReturned = false
        reload()
    }

    func remove() {
        statusTask?.cancel()
        try? vault.clear()
        reload()
    }
}
