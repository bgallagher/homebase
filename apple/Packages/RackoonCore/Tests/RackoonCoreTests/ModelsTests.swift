import Foundation
import XCTest
@testable import RackoonCore

final class ModelsTests: XCTestCase {
    func testServerRoundTripsThroughJSON() throws {
        let server = Server(id: "1", name: "vps", host: "vps.example.com", sshConfigAlias: nil)
        let data = try JSONEncoder().encode(server)
        XCTAssertEqual(try JSONDecoder().decode(Server.self, from: data), server)
    }
}
