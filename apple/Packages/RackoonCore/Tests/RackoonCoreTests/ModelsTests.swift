import Foundation
import XCTest
@testable import RackoonCore

final class ModelsTests: XCTestCase {
    func testServerRoundTripsThroughJSON() throws {
        let server = Server(id: "1", name: "vps", host: "vps.example.com", sshConfigAlias: nil)
        let data = try JSONEncoder().encode(server)
        XCTAssertEqual(try JSONDecoder().decode(Server.self, from: data), server)
    }

    func testServerKeepsItsKeyFileAndDecodesWithoutOne() throws {
        let server = Server(id: "1", name: "lab", host: "192.168.6.157", user: "lab", identityFile: "~/.ssh/lab_key")
        let data = try JSONEncoder().encode(server)
        XCTAssertEqual(try JSONDecoder().decode(Server.self, from: data), server)
        // servers.json written before the field existed.
        let old = Data(#"{"id":"1","name":"lab","host":"192.168.6.157","user":"lab"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Server.self, from: old), Server(id: "1", name: "lab", host: "192.168.6.157", user: "lab"))
    }

    func testConnectsLikeIgnoresTheNameOnly() {
        let a = Server(id: "1", name: "lab", host: "h", user: "u", port: 22, identityFile: "~/.ssh/k")
        var b = a
        b.name = "renamed"
        XCTAssertTrue(a.connectsLike(b))
        for change in [{ (s: inout Server) in s.host = "other" }, { $0.user = nil }, { $0.port = 2222 },
                       { $0.identityFile = nil }, { $0.sshConfigAlias = "h" }] {
            var c = a
            change(&c)
            XCTAssertFalse(a.connectsLike(c))
        }
    }
}
