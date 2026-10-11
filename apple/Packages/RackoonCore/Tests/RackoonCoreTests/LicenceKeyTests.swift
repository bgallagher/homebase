import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import RackoonCore

#if canImport(CryptoKit)
/// Test-only Ed25519 check (the app has the same thing in LicenceVerifier.swift).
private struct CryptoKitVerifier: LicenceSignatureVerifier {
    let key: Curve25519.Signing.PublicKey
    init(base64: String) throws { key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: base64)!) }
    func isValid(signature: Data, message: Data) -> Bool { key.isValidSignature(signature, for: message) }
}

final class LicenceKeyTests: XCTestCase {
    private let dir = specDir.appendingPathComponent("fixtures/licence")

    private func keypair() throws -> (publicKey: String, privateKey: String) {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("test-keypair.json"))) as! [String: Any]
        return (object["publicKey"] as! String, object["privateKey"] as! String)
    }

    private func verifiers() throws -> [LicenceEnv: LicenceSignatureVerifier] {
        let v = try CryptoKitVerifier(base64: keypair().publicKey)
        return [.sandbox: v, .live: v]
    }

    /// Every fixture written by tools/licence-keygen (from the TypeScript implementation) must give the same answer here.
    func testEveryFixtureMatchesTheSpec() throws {
        let verifiers = try verifiers()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".key.txt") }.sorted()
        XCTAssertGreaterThanOrEqual(names.count, 12)
        for file in names {
            let name = String(file.dropLast(".key.txt".count))
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("\(name).expected.json"))) as! [String: Any]
            if expected["valid"] as? Bool == true {
                let want = expected["payload"] as! [String: Any]
                let got = try LicenceKey.verify(text, verifiers: verifiers)
                XCTAssertEqual(got.email, want["email"] as? String, name)
                XCTAssertEqual(got.txn, want["txn"] as? String, name)
                XCTAssertEqual(got.env.rawValue, want["env"] as? String, name)
                XCTAssertEqual(got.tier, want["tier"] as? String, name)
                XCTAssertEqual(got.issued, want["issued"] as? String, name)
            } else {
                let error = expected["error"] as! String
                XCTAssertThrowsError(try LicenceKey.verify(text, verifiers: verifiers), name) { thrown in
                    switch (error, thrown as? LicenceError) {
                    case ("malformed", .malformed?), ("bad-signature", .badSignature?), ("invalid-payload", .invalidPayload?),
                         ("unsupported-version", .unsupportedVersion?): break
                    default: XCTFail("\(name): expected \(error), got \(thrown)")
                    }
                }
            }
        }
    }

    func testEnvironmentPolicyAndMissingKeys() throws {
        let verifiers = try verifiers()
        let sandboxKey = try String(contentsOf: dir.appendingPathComponent("valid-sandbox.key.txt"), encoding: .utf8)
        let liveKey = try String(contentsOf: dir.appendingPathComponent("valid-live.key.txt"), encoding: .utf8)
        let release = LicenceChecker(verifiers: verifiers, accepted: [.live])
        let dev = LicenceChecker(verifiers: verifiers, accepted: [.live, .sandbox])
        XCTAssertEqual(try release.check(liveKey).env, .live)
        XCTAssertThrowsError(try release.check(sandboxKey)) { XCTAssertEqual($0 as? LicenceError, .wrongEnvironment(.sandbox)) }
        XCTAssertEqual(try dev.check(sandboxKey).env, .sandbox)
        // a build with no live public key can't honour a live key (and says so)
        let sandboxOnly = LicenceChecker(verifiers: [.sandbox: verifiers[.sandbox]!], accepted: [.sandbox])
        XCTAssertThrowsError(try sandboxOnly.check(liveKey)) { XCTAssertEqual($0 as? LicenceError, .noPublicKey(.live)) }
    }

    func testVaultRemoveAddAndReplace() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rk-licence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let vault = LicenceVault(url: tmp.appendingPathComponent("licence.json"))
        let verifiers = try verifiers()
        let checker = LicenceChecker(verifiers: verifiers, accepted: [.live, .sandbox])
        let live = try String(contentsOf: dir.appendingPathComponent("valid-live.key.txt"), encoding: .utf8)
        let sandbox = try String(contentsOf: dir.appendingPathComponent("valid-sandbox.key.txt"), encoding: .utf8)
        let wrapped = try String(contentsOf: dir.appendingPathComponent("valid-wrapped.key.txt"), encoding: .utf8)

        XCTAssertNil(vault.load())
        try vault.clear()   // removing when nothing is stored is fine

        try vault.save(wrapped)   // stored without the line breaks
        let stored = try XCTUnwrap(vault.load())
        XCTAssertFalse(stored.contains("\n"))
        XCTAssertEqual(try checker.check(stored).env, .live)
        let mode = try FileManager.default.attributesOfItem(atPath: vault.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        try vault.clear()                       // remove
        XCTAssertNil(vault.load())
        try vault.save(live)                    // add again
        XCTAssertEqual(try checker.check(try XCTUnwrap(vault.load())).env, .live)
        try vault.save(sandbox)                 // replace with a different key
        XCTAssertEqual(try checker.check(try XCTUnwrap(vault.load())).env, .sandbox)

        // a damaged file reads as "no licence", not a crash
        try Data("not json".utf8).write(to: vault.url)
        XCTAssertNil(vault.load())
    }

    func testBase64URLEdgeCases() {
        XCTAssertNil(LicenceKey.base64URLDecode("a"))          // length % 4 == 1 is impossible
        XCTAssertNil(LicenceKey.base64URLDecode("ab+/"))        // standard alphabet is not base64url
        XCTAssertEqual(LicenceKey.base64URLDecode("aGk"), Data("hi".utf8))
        XCTAssertEqual(LicenceKey.base64URLDecode(""), Data())
    }
}
#endif
