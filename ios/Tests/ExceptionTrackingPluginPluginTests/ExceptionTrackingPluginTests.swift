import XCTest
@testable import ExceptionTrackingPluginPlugin

class ExceptionTrackingPluginTests: XCTestCase {
    func testSharedImplementationExists() {
        XCTAssertNotNil(ExceptionTrackingPlugin.shared)
    }
}
