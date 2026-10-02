import XCTest
@testable import Distill

@MainActor
final class SmokeTests: XCTestCase {
    func testIntakeName() {
        let name = AppModel.intakeName(prefix: "Screenshot", ext: "png", date: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(name.hasPrefix("Screenshot "))
    }
}
