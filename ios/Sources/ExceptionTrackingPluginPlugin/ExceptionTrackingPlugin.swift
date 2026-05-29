import Foundation

@objc public class ExceptionTrackingPlugin: NSObject {
    @objc public func echo(_ value: String) -> String {
        print(value)
        return value
    }
}
