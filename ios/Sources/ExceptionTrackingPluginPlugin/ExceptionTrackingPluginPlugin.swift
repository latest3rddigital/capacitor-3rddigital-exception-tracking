import Foundation
import Capacitor

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(ExceptionTrackingPluginPlugin)
public class ExceptionTrackingPluginPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ExceptionTrackingPluginPlugin"
    public let jsName = "ExceptionTrackingPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "echo", returnType: CAPPluginReturnPromise)
    ]
    private let implementation = ExceptionTrackingPlugin()

    @objc func echo(_ call: CAPPluginCall) {
        let value = call.getString("value") ?? ""
        call.resolve([
            "value": implementation.echo(value)
        ])
    }
}
