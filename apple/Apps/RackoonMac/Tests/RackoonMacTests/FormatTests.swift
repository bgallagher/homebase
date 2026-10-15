import XCTest
@testable import RackoonMac

final class FormatTests: XCTestCase {
    func testStorageIsDecimalLikeDrivesAreSold() {
        XCTAssertEqual(Format.storage(12_000_138_625_024), "12 TB")
        XCTAssertEqual(Format.storage(500_107_862_016), "500.11 GB")
        XCTAssertEqual(Format.bytes(1_073_741_824), "1 GB", "memory stays binary")
    }

    func testCelsiusRounds() {
        XCTAssertEqual(Format.celsius(60.6), "61 °C")
        XCTAssertEqual(Format.celsius(31), "31 °C")
    }
}
