import Foundation
import Darwin
import Capacitor
#if canImport(UIKit)
import UIKit
#endif

private let prefsPrefix = "capacitor_3rddigital_exception_tracking"
private let pendingPayloadKey = "\(prefsPrefix).pendingPayloadJson"
private let signalExceptionName = "NativeSignalException"
private let signalKey = "signal"
private let signalStackKey = "signalStack"
private let maxExceptionCount: Int32 = 10
private var uncaughtExceptionCount: Int32 = 0
private var previousExceptionHandler: NSUncaughtExceptionHandler?
private var installedSignalHandlers = false
private var previousSignalHandlers: [Int32: (@convention(c) (Int32) -> Void)?] = [:]
private var passthroughHandlerInstalled = false

private let exceptionHandler: @convention(c) (NSException) -> Void = { exception in
    reportException(exception)
}

private let passthroughExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    if let previousExceptionHandler = previousExceptionHandler {
        previousExceptionHandler(exception)
    }
}

private let signalHandler: @convention(c) (Int32) -> Void = { signal in
    let exception = NSException(
        name: NSExceptionName(signalExceptionName),
        reason: "Signal \(signal) was raised.",
        userInfo: [
            signalKey: NSNumber(value: signal),
            signalStackKey: Thread.callStackSymbols
        ]
    )
    reportException(exception)
}

private func reportException(_ exception: NSException) {
    if !ExceptionTrackingPlugin.shared.isEnabled {
        return
    }

    uncaughtExceptionCount += 1
    if uncaughtExceptionCount > maxExceptionCount {
        return
    }

    if Thread.isMainThread {
        ExceptionTrackingPlugin.shared.handle(exception: exception)
        return
    }

    DispatchQueue.main.sync {
        ExceptionTrackingPlugin.shared.handle(exception: exception)
    }
}

@objc public class ExceptionTrackingPlugin: NSObject {
    static let shared = ExceptionTrackingPlugin()

    private weak var plugin: ExceptionTrackingPluginPlugin?
    private var enabled = true
    private var executeOriginalHandler = true
    private var forceToQuit = false
    private var nativeFallbackEnabled = true
    private var holdTimeout: TimeInterval = 5
    private var ingestUrl: String?
    private var apiKey: String?
    private var projectKey: String?
    private var headers: [String: Any] = [:]
    private var basePayload: [String: Any] = [:]
    private var releaseHold = true
    private var lastReportedException: NSException?
    private var handlersInstalled = false

    var isEnabled: Bool {
        enabled
    }

    func attach(plugin: ExceptionTrackingPluginPlugin) {
        self.plugin = plugin
        restoreConfiguration()
        if enabled {
            uploadPendingExceptionAsync()
        }
    }

    func configure(_ call: CAPPluginCall) {
        let incomingProjectKey = call.getString("projectKey") ?? projectKey
        ingestUrl = makeIngestUrl(url: call.getString("url") ?? ingestUrl, projectKey: incomingProjectKey)
        apiKey = call.getString("apiKey") ?? apiKey
        projectKey = incomingProjectKey
        headers = call.getObject("headers") ?? headers
        basePayload = call.getObject("basePayload") ?? basePayload
        enabled = call.getBool("enabled") ?? enabled
        nativeFallbackEnabled = call.getBool("nativeFallbackEnabled") ?? nativeFallbackEnabled
        executeOriginalHandler = call.getBool("executeOriginalHandler") ?? executeOriginalHandler
        forceToQuit = call.getBool("forceToQuit") ?? forceToQuit
        if let timeoutMs = call.getDouble("holdTimeoutMs") {
            holdTimeout = max(timeoutMs / 1000, 0.1)
        }

        persistConfiguration()
        if !enabled {
            uninstallNativeExceptionHandler()
            return
        }

        installNativeExceptionHandler()
        uploadPendingExceptionAsync()
    }

    func releaseExceptionHold(handled: Bool) {
        releaseHold = true
        if handled {
            clearPendingException()
        }
    }

    func uploadPendingException() -> Bool {
        guard enabled, nativeFallbackEnabled else {
            return false
        }
        guard let json = UserDefaults.standard.string(forKey: pendingPayloadKey),
              let data = json.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let uploaded = postExceptionSync(payload)
        if uploaded {
            clearPendingException()
        }
        return uploaded
    }

    private func uploadPendingExceptionAsync() {
        DispatchQueue.global(qos: .utility).async {
            _ = self.uploadPendingException()
        }
    }

    func crashForTesting(message: String) {
        guard enabled else {
            return
        }

        DispatchQueue.main.async {
            NSException(
                name: NSExceptionName("CapacitorTestNativeException"),
                reason: message,
                userInfo: nil
            ).raise()
        }
    }

    func handle(exception: NSException) {
        guard enabled else {
            continueCrash(exception)
            return
        }

        if lastReportedException === exception {
            return
        }
        lastReportedException = exception

        let payload = buildPayload(exception: exception)
        persistPendingException(payload)

        var uploadedByNative = false
        if nativeFallbackEnabled {
            uploadedByNative = postException(payload)
            if uploadedByNative {
                clearPendingException()
            }
        }

        releaseHold = false
        plugin?.emitNativeException([
            "title": payload["title"] as? String ?? "",
            "message": payload["message"] as? String ?? "",
            "stackTrace": payload["stackTrace"] as? String ?? "",
            "payload": payload,
            "uploadedByNative": uploadedByNative
        ])

        let timeoutDate = Date(timeIntervalSinceNow: holdTimeout)
        while !releaseHold && timeoutDate.timeIntervalSinceNow > 0 {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        continueCrash(exception)
    }

    private func installNativeExceptionHandler() {
        if handlersInstalled {
            return
        }

        if !passthroughHandlerInstalled {
            previousExceptionHandler = NSGetUncaughtExceptionHandler()
        }
        NSSetUncaughtExceptionHandler(exceptionHandler)
        passthroughHandlerInstalled = false

        if !installedSignalHandlers {
            installedSignalHandlers = true
            installSignalHandler(SIGABRT)
            installSignalHandler(SIGILL)
            installSignalHandler(SIGSEGV)
            installSignalHandler(SIGFPE)
            installSignalHandler(SIGBUS)
            installSignalHandler(SIGPIPE)
            installSignalHandler(SIGTRAP)
        }

        handlersInstalled = true
    }

    private func installSignalHandler(_ signalNumber: Int32) {
        previousSignalHandlers[signalNumber] = signal(signalNumber, signalHandler)
    }

    private func uninstallNativeExceptionHandler() {
        guard handlersInstalled else {
            return
        }

        NSSetUncaughtExceptionHandler(passthroughExceptionHandler)
        passthroughHandlerInstalled = true

        if installedSignalHandlers {
            for signalNumber in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE, SIGTRAP] {
                if let previousHandler = previousSignalHandlers[signalNumber] ?? nil {
                    signal(signalNumber, previousHandler)
                } else {
                    signal(signalNumber, SIG_DFL)
                }
            }
            previousSignalHandlers.removeAll()
            installedSignalHandlers = false
        }

        handlersInstalled = false
    }

    private func continueCrash(_ exception: NSException) {
        if executeOriginalHandler, let previousExceptionHandler = previousExceptionHandler {
            previousExceptionHandler(exception)
            return
        }

        NSSetUncaughtExceptionHandler(nil)
        signal(SIGABRT, SIG_DFL)
        signal(SIGILL, SIG_DFL)
        signal(SIGSEGV, SIG_DFL)
        signal(SIGFPE, SIG_DFL)
        signal(SIGBUS, SIG_DFL)
        signal(SIGPIPE, SIG_DFL)
        signal(SIGTRAP, SIG_DFL)

        if let signal = exception.userInfo?[signalKey] as? NSNumber {
            kill(getpid(), signal.int32Value)
            return
        }

        if forceToQuit {
            abort()
        }

        exception.raise()
    }

    private func buildPayload(exception: NSException) -> [String: Any] {
        var payload = basePayload
        var metadata = payload["metadata"] as? [String: Any] ?? [:]
        let timestamp = isoTimestamp()
        let deviceId = currentDeviceIdentifier()
        let appInfo = mergeAppInfo(payload["appInfo"] as? [String: Any] ?? [:])
        let screenInfo = mergeScreenInfo(payload["screenInfo"] as? [String: Any] ?? [:])
        let localeInfo = mergeLocaleInfo(payload["localeInfo"] as? [String: Any] ?? [:])
        let batteryInfo = mergeBatteryInfo(payload["batteryInfo"] as? [String: Any] ?? [:])

        metadata["isNativeFallbackCandidate"] = true
        metadata["framework"] = "capacitor"
        metadata["backendSource"] = "capacitor"
        metadata["runtimeSource"] = "capacitor"
        metadata["errorSource"] = "native"
        metadata["nativePlatform"] = currentOSName()
        metadata["exceptionName"] = exception.name.rawValue
        metadata["projectKey"] = projectKey
        metadata["appInfo"] = appInfo
        metadata["batteryInfo"] = batteryInfo

        payload["source"] = "capacitor"
        payload["stackSource"] = "native"
        payload["platform"] = "ios"
        payload["projectKey"] = projectKey ?? ""
        payload["title"] = exception.name.rawValue
        payload["message"] = exception.reason ?? exception.name.rawValue
        payload["stackTrace"] = stackTraceString(exception)
        payload["timestamp"] = timestamp
        payload["reportedAt"] = timestamp
        payload["deviceId"] = deviceId
        payload["browserInfo"] = [:]
        payload["metadata"] = metadata
        payload["appInfo"] = appInfo
        payload["appVersion"] = firstString(appInfo["versionName"], payload["appVersion"])
        payload["buildNumber"] = firstString(appInfo["buildNumber"], payload["buildNumber"])

        var osInfo = payload["osInfo"] as? [String: Any] ?? [:]
        osInfo["name"] = "\(currentSystemName()) \(currentOSVersion())"
        osInfo["osName"] = currentOSName()
        osInfo["osVersion"] = currentOSVersion()
        osInfo["systemName"] = currentSystemName()
        osInfo["systemVersion"] = currentOSVersion()
        osInfo["platform"] = currentOSName()
        payload["osInfo"] = osInfo

        var deviceInfo = payload["deviceInfo"] as? [String: Any] ?? [:]
        deviceInfo["brand"] = "Apple"
        deviceInfo["manufacturer"] = "Apple"
        deviceInfo["name"] = currentDeviceName()
        deviceInfo["model"] = currentDeviceName()
        deviceInfo["systemName"] = currentSystemName()
        deviceInfo["systemVersion"] = currentOSVersion()
        deviceInfo["modelId"] = currentDeviceModel()
        deviceInfo["capacitorModel"] = currentDeviceModel()
        deviceInfo["deviceId"] = deviceId
        deviceInfo["uniqueId"] = deviceId
        deviceInfo["installationId"] = deviceId
        deviceInfo["identifierForVendor"] = deviceId
        deviceInfo["localizedModel"] = currentLocalizedModel()
        deviceInfo["userInterfaceIdiom"] = currentUserInterfaceIdiom()
        payload["deviceInfo"] = deviceInfo
        payload["screenInfo"] = screenInfo
        payload["localeInfo"] = localeInfo
        payload["batteryInfo"] = batteryInfo
        payload["otherDetails"] = mergeOtherDetails(
            payload["otherDetails"] as? [String: Any] ?? [:],
            appInfo: appInfo,
            batteryInfo: batteryInfo,
            screenInfo: screenInfo,
            localeInfo: localeInfo,
            deviceInfo: deviceInfo
        )

        return payload
    }

    private func mergeAppInfo(_ appInfo: [String: Any]) -> [String: Any] {
        var mergedAppInfo = appInfo
        let bundle = Bundle.main
        mergedAppInfo["bundleId"] = bundle.bundleIdentifier
        mergedAppInfo["appName"] = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName")
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName")
        mergedAppInfo["versionName"] = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        mergedAppInfo["buildNumber"] = bundle.object(forInfoDictionaryKey: "CFBundleVersion")
        return mergedAppInfo
    }

    private func mergeScreenInfo(_ screenInfo: [String: Any]) -> [String: Any] {
        var mergedScreenInfo = screenInfo
        #if canImport(UIKit)
        let screen = UIScreen.main
        mergedScreenInfo["width"] = screen.bounds.width
        mergedScreenInfo["height"] = screen.bounds.height
        mergedScreenInfo["nativeWidth"] = screen.nativeBounds.width
        mergedScreenInfo["nativeHeight"] = screen.nativeBounds.height
        mergedScreenInfo["scale"] = screen.scale
        mergedScreenInfo["nativeScale"] = screen.nativeScale
        #endif
        return mergedScreenInfo
    }

    private func mergeLocaleInfo(_ localeInfo: [String: Any]) -> [String: Any] {
        var mergedLocaleInfo = localeInfo
        let locale = Locale.current
        mergedLocaleInfo["identifier"] = locale.identifier
        mergedLocaleInfo["languageCode"] = locale.languageCode
        mergedLocaleInfo["regionCode"] = locale.regionCode
        mergedLocaleInfo["calendarIdentifier"] = "\(locale.calendar.identifier)"
        mergedLocaleInfo["timezone"] = TimeZone.current.identifier
        return mergedLocaleInfo
    }

    private func mergeBatteryInfo(_ batteryInfo: [String: Any]) -> [String: Any] {
        var mergedBatteryInfo = batteryInfo
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        if UIDevice.current.batteryLevel >= 0 {
            mergedBatteryInfo["batteryLevel"] = UIDevice.current.batteryLevel
        }
        mergedBatteryInfo["batteryState"] = batteryStateName(UIDevice.current.batteryState)
        #endif
        return mergedBatteryInfo
    }

    private func mergeOtherDetails(
        _ otherDetails: [String: Any],
        appInfo: [String: Any],
        batteryInfo: [String: Any],
        screenInfo: [String: Any],
        localeInfo: [String: Any],
        deviceInfo: [String: Any]
    ) -> [String: Any] {
        var mergedOtherDetails = otherDetails
        mergedOtherDetails["appInfo"] = appInfo
        mergedOtherDetails["batteryInfo"] = batteryInfo
        mergedOtherDetails["screenInfo"] = screenInfo
        mergedOtherDetails["localeInfo"] = localeInfo
        mergedOtherDetails["capacitorDeviceInfo"] = deviceInfo
        mergedOtherDetails["nativeException"] = true
        mergedOtherDetails["nativePlatform"] = currentOSName()
        return mergedOtherDetails
    }

    private func stackTraceString(_ exception: NSException) -> String {
        if let stack = exception.userInfo?[signalStackKey] as? [String] {
            return stack.joined(separator: "\n")
        }
        return exception.callStackSymbols.joined(separator: "\n")
    }

    private func postException(_ payload: [String: Any]) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var uploaded = false
        DispatchQueue.global(qos: .userInitiated).async {
            uploaded = self.postExceptionSync(payload)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return uploaded
    }

    private func postExceptionSync(_ payload: [String: Any]) -> Bool {
        guard let ingestUrl = ingestUrl,
              let url = URL(string: ingestUrl),
              JSONSerialization.isValidJSONObject(payload) else {
            NSLog("NativeExceptionHandler: native fallback skipped because URL or payload is invalid")
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 4
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        }
        headers.forEach { key, value in
            request.setValue("\(value)", forHTTPHeaderField: key)
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        URLSession.shared.dataTask(with: request) { _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            success = error == nil && statusCode >= 200 && statusCode < 300
            if !success {
                NSLog("NativeExceptionHandler: native fallback failed with status \(statusCode)")
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return success
    }

    private func persistConfiguration() {
        let defaults = UserDefaults.standard
        defaults.set(ingestUrl, forKey: "\(prefsPrefix).ingestUrl")
        defaults.set(apiKey, forKey: "\(prefsPrefix).apiKey")
        defaults.set(projectKey, forKey: "\(prefsPrefix).projectKey")
        defaults.set(headers, forKey: "\(prefsPrefix).headers")
        defaults.set(basePayload, forKey: "\(prefsPrefix).basePayload")
        defaults.set(enabled, forKey: "\(prefsPrefix).enabled")
        defaults.set(nativeFallbackEnabled, forKey: "\(prefsPrefix).nativeFallbackEnabled")
        defaults.set(executeOriginalHandler, forKey: "\(prefsPrefix).executeOriginalHandler")
        defaults.set(forceToQuit, forKey: "\(prefsPrefix).forceToQuit")
        defaults.set(holdTimeout, forKey: "\(prefsPrefix).holdTimeout")
        defaults.synchronize()
    }

    private func restoreConfiguration() {
        let defaults = UserDefaults.standard
        ingestUrl = defaults.string(forKey: "\(prefsPrefix).ingestUrl") ?? ingestUrl
        apiKey = defaults.string(forKey: "\(prefsPrefix).apiKey") ?? apiKey
        projectKey = defaults.string(forKey: "\(prefsPrefix).projectKey") ?? projectKey
        headers = defaults.dictionary(forKey: "\(prefsPrefix).headers") ?? headers
        basePayload = defaults.dictionary(forKey: "\(prefsPrefix).basePayload") ?? basePayload
        if defaults.object(forKey: "\(prefsPrefix).enabled") != nil {
            enabled = defaults.bool(forKey: "\(prefsPrefix).enabled")
        }
        if defaults.object(forKey: "\(prefsPrefix).nativeFallbackEnabled") != nil {
            nativeFallbackEnabled = defaults.bool(forKey: "\(prefsPrefix).nativeFallbackEnabled")
        }
        if defaults.object(forKey: "\(prefsPrefix).executeOriginalHandler") != nil {
            executeOriginalHandler = defaults.bool(forKey: "\(prefsPrefix).executeOriginalHandler")
        }
        if defaults.object(forKey: "\(prefsPrefix).forceToQuit") != nil {
            forceToQuit = defaults.bool(forKey: "\(prefsPrefix).forceToQuit")
        }
        if defaults.object(forKey: "\(prefsPrefix).holdTimeout") != nil {
            holdTimeout = defaults.double(forKey: "\(prefsPrefix).holdTimeout")
        }
    }

    private func persistPendingException(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        UserDefaults.standard.set(json, forKey: pendingPayloadKey)
        UserDefaults.standard.synchronize()
    }

    private func clearPendingException() {
        UserDefaults.standard.removeObject(forKey: pendingPayloadKey)
        UserDefaults.standard.synchronize()
    }

    private func makeIngestUrl(url: String?, projectKey: String?) -> String? {
        guard var baseUrl = url else {
            return ingestUrl
        }

        while baseUrl.hasSuffix("/") {
            baseUrl.removeLast()
        }

        guard let projectKey = projectKey, !projectKey.isEmpty else {
            return baseUrl
        }

        let suffix = "/exceptions/ingest/\(projectKey)"
        return baseUrl.hasSuffix(suffix) ? baseUrl : baseUrl + suffix
    }

    private func isoTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func currentOSName() -> String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }

    private func currentSystemName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemName
        #else
        return "macOS"
        #endif
    }

    private func currentOSVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private func currentDeviceModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    private func currentDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }

    private func currentDeviceIdentifier() -> String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? ""
        #else
        return ""
        #endif
    }

    private func currentLocalizedModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.localizedModel
        #else
        return "Mac"
        #endif
    }

    private func currentUserInterfaceIdiom() -> String {
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone:
            return "phone"
        case .pad:
            return "pad"
        case .tv:
            return "tv"
        case .carPlay:
            return "carPlay"
        case .mac:
            return "mac"
        case .vision:
            return "vision"
        default:
            return "unspecified"
        }
        #else
        return "mac"
        #endif
    }

    private func firstString(_ values: Any?...) -> String {
        for value in values {
            if let value = value {
                let text = "\(value)"
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return ""
    }

    #if canImport(UIKit)
    private func batteryStateName(_ batteryState: UIDevice.BatteryState) -> String {
        switch batteryState {
        case .charging:
            return "charging"
        case .full:
            return "full"
        case .unplugged:
            return "unplugged"
        default:
            return "unknown"
        }
    }
    #endif
}
