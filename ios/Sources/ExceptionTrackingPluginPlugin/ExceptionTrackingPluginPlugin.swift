import Foundation
import Capacitor

/**
 * Please read the Capacitor iOS Plugin Development Guide
 * here: https://capacitorjs.com/docs/plugins/ios
 */
@objc(ExceptionTrackingPluginPlugin)
public class ExceptionTrackingPluginPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "NativeExceptionHandler"
    public let jsName = "NativeExceptionHandler"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "configure", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setContext", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "releaseExceptionHold", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "uploadPendingException", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "crashForTesting", returnType: CAPPluginReturnPromise)
    ]
    private let implementation = ExceptionTrackingPlugin.shared

    public override func load() {
        implementation.attach(plugin: self)
    }

    @objc func configure(_ call: CAPPluginCall) {
        implementation.configure(call)
        call.resolve()
    }

    @objc func setContext(_ call: CAPPluginCall) {
        implementation.setContext(call)
        call.resolve()
    }

    @objc func releaseExceptionHold(_ call: CAPPluginCall) {
        implementation.releaseExceptionHold(handled: call.getBool("handled") ?? true)
        call.resolve()
    }

    @objc func uploadPendingException(_ call: CAPPluginCall) {
        call.resolve([
            "uploaded": implementation.uploadPendingException()
        ])
    }

    @objc func crashForTesting(_ call: CAPPluginCall) {
        implementation.crashForTesting(message: call.getString("message") ?? "Test native exception from Capacitor")
        call.resolve()
    }

    func emitNativeException(_ event: [String: Any]) {
        notifyListeners("nativeException", data: event, retainUntilConsumed: true)
    }
}
