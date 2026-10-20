import XCTest
@testable import VibekeyCore

final class ProtocolTests: XCTestCase {
    func testAU05Identity() {
        XCTAssertEqual(HIDTransport.vendorID, 0xfff1)
        XCTAssertEqual(HIDTransport.productID, 0x00dd)
    }
}
