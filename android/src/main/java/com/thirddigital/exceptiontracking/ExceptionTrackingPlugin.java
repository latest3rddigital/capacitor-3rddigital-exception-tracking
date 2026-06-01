package com.thirddigital.exceptiontracking;

import android.app.ActivityManager;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.res.Resources;
import android.os.Build;
import android.provider.Settings;
import android.util.DisplayMetrics;
import android.util.Log;
import com.getcapacitor.JSObject;
import java.io.File;
import java.io.OutputStream;
import java.lang.ref.WeakReference;
import java.net.HttpURLConnection;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.Arrays;
import java.util.Date;
import java.util.Iterator;
import java.util.Locale;
import java.util.TimeZone;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import org.json.JSONException;
import org.json.JSONObject;

@SuppressWarnings("deprecation")
public class ExceptionTrackingPlugin {

    private static final String TAG = "NativeExceptionHandler";
    private static final String PREFS_NAME = "capacitor_3rddigital_exception_tracking";
    private static final String PENDING_PAYLOAD_JSON_KEY = "pendingPayloadJson";
    private static final long DEFAULT_HOLD_TIMEOUT_MS = 5000L;
    private static final long UPLOAD_TIMEOUT_MS = 5000L;

    private static WeakReference<ExceptionTrackingPluginPlugin> pluginReference = new WeakReference<>(null);
    private static Thread.UncaughtExceptionHandler originalHandler;
    private static boolean handlerInstalled = false;
    private static Thread.UncaughtExceptionHandler installedHandler;
    private static boolean enabled = true;
    private static boolean executeOriginalHandler = true;
    private static boolean forceToQuit = false;
    private static boolean nativeFallbackEnabled = true;
    private static long holdTimeoutMs = DEFAULT_HOLD_TIMEOUT_MS;
    private static String ingestUrl;
    private static String apiKey;
    private static String projectKey;
    private static String headersJson = "{}";
    private static String basePayloadJson = "{}";
    private static Context appContext;
    private static CountDownLatch currentCrashLatch;
    private static Integer lastReportedThrowableId;

    public void attach(Context context, ExceptionTrackingPluginPlugin plugin) {
        if (context == null) {
            return;
        }

        appContext = context.getApplicationContext();
        pluginReference = new WeakReference<>(plugin);
        restoreConfiguration(appContext);
        if (enabled) {
            uploadPendingExceptionAsync(appContext);
        }
    }

    public void configure(Context context, ExceptionTrackingPluginPlugin plugin, JSObject options) throws JSONException {
        attach(context, plugin);

        ingestUrl = getIngestUrl(options.getString("url"), options.getString("projectKey"));
        apiKey = options.getString("apiKey", apiKey);
        projectKey = options.getString("projectKey", projectKey);
        enabled = options.has("enabled") ? options.getBoolean("enabled") : enabled;
        nativeFallbackEnabled = options.has("nativeFallbackEnabled") ? options.getBoolean("nativeFallbackEnabled") : nativeFallbackEnabled;
        executeOriginalHandler = options.has("executeOriginalHandler") ? options.getBoolean("executeOriginalHandler") : executeOriginalHandler;
        forceToQuit = options.has("forceToQuit") ? options.getBoolean("forceToQuit") : forceToQuit;
        holdTimeoutMs = options.has("holdTimeoutMs") ? options.getLong("holdTimeoutMs") : holdTimeoutMs;

        JSONObject headers = options.optJSONObject("headers");
        if (headers != null) {
            headersJson = headers.toString();
        }

        JSONObject basePayload = options.optJSONObject("basePayload");
        if (basePayload != null) {
            basePayloadJson = basePayload.toString();
        }

        persistConfiguration(appContext);
        if (!enabled) {
            uninstallNativeExceptionHandler();
            return;
        }

        installNativeExceptionHandler();
        uploadPendingExceptionAsync(appContext);
    }

    public void releaseExceptionHold(boolean handled) {
        if (handled) {
            clearPendingException(appContext);
        }

        CountDownLatch latch = currentCrashLatch;
        if (latch != null) {
            latch.countDown();
        }
    }

    public boolean uploadPendingException(Context context) {
        if (context == null || !enabled || !nativeFallbackEnabled) {
            return false;
        }

        String pendingPayloadJson = context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(PENDING_PAYLOAD_JSON_KEY, null);

        if (pendingPayloadJson == null || pendingPayloadJson.trim().isEmpty()) {
            return false;
        }

        try {
            boolean uploaded = postExceptionSync(new JSONObject(pendingPayloadJson));
            if (uploaded) {
                clearPendingException(context);
            }
            return uploaded;
        } catch (Exception exception) {
            Log.e(TAG, "Failed to upload pending native exception", exception);
            return false;
        }
    }

    public void crashForTesting(String message) {
        if (!enabled) {
            return;
        }

        new Thread(() -> {
            throw new RuntimeException(message);
        }, "CapacitorExceptionTestCrash").start();
    }

    private static void uploadPendingExceptionAsync(Context context) {
        new Thread(() -> new ExceptionTrackingPlugin().uploadPendingException(context), "PendingCapacitorExceptionUploader").start();
    }

    private static void installNativeExceptionHandler() {
        if (handlerInstalled) {
            return;
        }

        originalHandler = Thread.getDefaultUncaughtExceptionHandler();
        handlerInstalled = true;

        installedHandler = (thread, throwable) -> {
            reportException(throwable);
            continueCrash(thread, throwable);
        };
        Thread.setDefaultUncaughtExceptionHandler(installedHandler);
    }

    private static void uninstallNativeExceptionHandler() {
        if (!handlerInstalled) {
            return;
        }

        if (Thread.getDefaultUncaughtExceptionHandler() == installedHandler) {
            Thread.setDefaultUncaughtExceptionHandler(originalHandler);
        }
        handlerInstalled = false;
        installedHandler = null;
    }

    private static void reportException(Throwable throwable) {
        if (!enabled) {
            return;
        }

        int throwableId = System.identityHashCode(throwable);
        if (lastReportedThrowableId != null && lastReportedThrowableId == throwableId) {
            return;
        }

        lastReportedThrowableId = throwableId;
        JSONObject payload = buildPayload(throwable);
        persistPendingException(appContext, payload);

        boolean uploadedByNative = false;
        if (nativeFallbackEnabled) {
            uploadedByNative = postException(payload);
            if (uploadedByNative) {
                clearPendingException(appContext);
            }
        }

        CountDownLatch crashLatch = new CountDownLatch(1);
        currentCrashLatch = crashLatch;

        try {
            ExceptionTrackingPluginPlugin plugin = pluginReference.get();
            if (plugin == null) {
                crashLatch.countDown();
            } else {
                JSObject event = new JSObject();
                event.put("title", payload.optString("title"));
                event.put("message", payload.optString("message"));
                event.put("stackTrace", payload.optString("stackTrace"));
                event.put("payload", payload);
                event.put("uploadedByNative", uploadedByNative);
                plugin.emitNativeException(event);
            }
        } catch (Exception callbackError) {
            Log.e(TAG, "Failed to emit native exception event", callbackError);
            crashLatch.countDown();
        }

        try {
            crashLatch.await(holdTimeoutMs, TimeUnit.MILLISECONDS);
        } catch (InterruptedException interruptedException) {
            Thread.currentThread().interrupt();
        } finally {
            currentCrashLatch = null;
        }
    }

    private static void continueCrash(Thread thread, Throwable throwable) {
        if (executeOriginalHandler && originalHandler != null) {
            originalHandler.uncaughtException(thread, throwable);
            return;
        }

        android.os.Process.killProcess(android.os.Process.myPid());
        if (forceToQuit) {
            System.exit(10);
        }
        System.exit(10);
    }

    private static JSONObject buildPayload(Throwable throwable) {
        JSONObject payload = parseJsonObject(basePayloadJson);
        JSONObject metadata = payload.optJSONObject("metadata");
        if (metadata == null) {
            metadata = new JSONObject();
        }

        String timestamp = getIsoTimestamp();
        String deviceId = getAndroidDeviceId();
        JSONObject appInfo = mergeAppInfo(payload.optJSONObject("appInfo"));
        JSONObject memoryInfo = getMemoryInfo();
        JSONObject storageInfo = getStorageInfo();

        put(metadata, "isNativeFallbackCandidate", true);
        put(metadata, "framework", "capacitor");
        put(metadata, "backendSource", "capacitor");
        put(metadata, "runtimeSource", "capacitor");
        put(metadata, "errorSource", "native");
        put(metadata, "nativePlatform", "android");
        put(metadata, "projectKey", projectKey);
        put(metadata, "appInfo", appInfo);
        put(metadata, "memoryInfo", memoryInfo);
        put(metadata, "storageInfo", storageInfo);

        put(payload, "source", "capacitor");
        put(payload, "stackSource", "native");
        put(payload, "platform", "android");
        put(payload, "projectKey", projectKey);
        put(payload, "title", throwable.getClass().getName());
        put(payload, "message", throwable.getMessage() != null ? throwable.getMessage() : throwable.toString());
        put(payload, "stackTrace", Log.getStackTraceString(throwable));
        put(payload, "timestamp", timestamp);
        put(payload, "reportedAt", timestamp);
        put(payload, "deviceId", deviceId);
        put(payload, "browserInfo", new JSONObject());
        put(payload, "metadata", metadata);
        put(payload, "appInfo", appInfo);
        put(payload, "appVersion", firstString(appInfo.optString("versionName", null), payload.optString("appVersion", null)));
        put(payload, "buildNumber", firstString(appInfo.optString("versionCode", null), payload.optString("buildNumber", null)));

        JSONObject osInfo = payload.optJSONObject("osInfo");
        if (osInfo == null) {
            osInfo = new JSONObject();
        }
        put(osInfo, "name", "Android " + Build.VERSION.RELEASE);
        put(osInfo, "osName", "android");
        put(osInfo, "osVersion", Build.VERSION.RELEASE);
        put(osInfo, "systemName", "Android " + Build.VERSION.RELEASE);
        put(osInfo, "systemVersion", Build.VERSION.RELEASE);
        put(osInfo, "platform", "android");
        put(osInfo, "apiLevel", Build.VERSION.SDK_INT);
        put(payload, "osInfo", osInfo);

        JSONObject deviceInfo = payload.optJSONObject("deviceInfo");
        if (deviceInfo == null) {
            deviceInfo = new JSONObject();
        }
        String deviceName = getAndroidDeviceName();
        put(deviceInfo, "brand", Build.BRAND);
        put(deviceInfo, "manufacturer", Build.MANUFACTURER);
        put(deviceInfo, "name", deviceName);
        put(deviceInfo, "model", deviceName);
        put(deviceInfo, "device", Build.DEVICE);
        put(deviceInfo, "product", Build.PRODUCT);
        put(deviceInfo, "board", Build.BOARD);
        put(deviceInfo, "hardware", Build.HARDWARE);
        put(deviceInfo, "fingerprint", Build.FINGERPRINT);
        put(deviceInfo, "supportedAbis", Arrays.asList(Build.SUPPORTED_ABIS));
        put(deviceInfo, "modelId", Build.MODEL);
        put(deviceInfo, "capacitorModel", Build.MODEL);
        put(deviceInfo, "deviceId", deviceId);
        put(deviceInfo, "uniqueId", deviceId);
        put(deviceInfo, "installationId", deviceId);
        put(deviceInfo, "systemName", "Android " + Build.VERSION.RELEASE);
        put(deviceInfo, "systemVersion", Build.VERSION.RELEASE);
        put(deviceInfo, "isVirtual", isProbablyEmulator());
        put(deviceInfo, "isEmulator", isProbablyEmulator());
        put(deviceInfo, "memoryInfo", memoryInfo);
        put(payload, "deviceInfo", deviceInfo);
        put(payload, "screenInfo", mergeScreenInfo(payload.optJSONObject("screenInfo")));
        put(payload, "localeInfo", mergeLocaleInfo(payload.optJSONObject("localeInfo")));
        put(payload, "memoryInfo", memoryInfo);
        put(payload, "storageInfo", storageInfo);
        put(payload, "otherDetails", mergeOtherDetails(payload.optJSONObject("otherDetails"), appInfo, memoryInfo, storageInfo, deviceInfo));

        return payload;
    }

    private static JSONObject mergeAppInfo(JSONObject appInfo) {
        JSONObject mergedAppInfo = appInfo == null ? new JSONObject() : appInfo;
        Context context = appContext;
        if (context == null) {
            return mergedAppInfo;
        }

        put(mergedAppInfo, "packageName", context.getPackageName());
        try {
            PackageManager packageManager = context.getPackageManager();
            PackageInfo packageInfo = packageManager.getPackageInfo(context.getPackageName(), 0);
            put(mergedAppInfo, "versionName", packageInfo.versionName);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                put(mergedAppInfo, "versionCode", packageInfo.getLongVersionCode());
            } else {
                put(mergedAppInfo, "versionCode", packageInfo.versionCode);
            }
        } catch (PackageManager.NameNotFoundException exception) {
            Log.w(TAG, "Unable to read app package info", exception);
        }

        return mergedAppInfo;
    }

    private static JSONObject mergeScreenInfo(JSONObject screenInfo) {
        JSONObject mergedScreenInfo = screenInfo == null ? new JSONObject() : screenInfo;
        DisplayMetrics displayMetrics = Resources.getSystem().getDisplayMetrics();

        put(mergedScreenInfo, "widthPixels", displayMetrics.widthPixels);
        put(mergedScreenInfo, "heightPixels", displayMetrics.heightPixels);
        put(mergedScreenInfo, "density", displayMetrics.density);
        put(mergedScreenInfo, "densityDpi", displayMetrics.densityDpi);
        put(mergedScreenInfo, "scaledDensity", displayMetrics.scaledDensity);

        return mergedScreenInfo;
    }

    private static JSONObject mergeLocaleInfo(JSONObject localeInfo) {
        JSONObject mergedLocaleInfo = localeInfo == null ? new JSONObject() : localeInfo;
        Locale locale = Locale.getDefault();

        put(mergedLocaleInfo, "language", locale.getLanguage());
        put(mergedLocaleInfo, "country", locale.getCountry());
        put(mergedLocaleInfo, "displayLanguage", locale.getDisplayLanguage());
        put(mergedLocaleInfo, "displayCountry", locale.getDisplayCountry());
        put(mergedLocaleInfo, "timezone", TimeZone.getDefault().getID());

        return mergedLocaleInfo;
    }

    private static JSONObject getMemoryInfo() {
        JSONObject memoryInfo = new JSONObject();
        Context context = appContext;
        if (context == null) {
            return memoryInfo;
        }

        ActivityManager activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        if (activityManager == null) {
            return memoryInfo;
        }

        ActivityManager.MemoryInfo systemMemoryInfo = new ActivityManager.MemoryInfo();
        activityManager.getMemoryInfo(systemMemoryInfo);
        put(memoryInfo, "availableMemory", systemMemoryInfo.availMem);
        put(memoryInfo, "totalMemory", systemMemoryInfo.totalMem);
        put(memoryInfo, "lowMemory", systemMemoryInfo.lowMemory);
        put(memoryInfo, "threshold", systemMemoryInfo.threshold);
        return memoryInfo;
    }

    private static JSONObject getStorageInfo() {
        JSONObject storageInfo = new JSONObject();
        Context context = appContext;
        if (context == null) {
            return storageInfo;
        }

        File filesDir = context.getFilesDir();
        put(storageInfo, "freeDiskStorage", filesDir.getFreeSpace());
        put(storageInfo, "totalDiskCapacity", filesDir.getTotalSpace());
        put(storageInfo, "usableDiskStorage", filesDir.getUsableSpace());
        return storageInfo;
    }

    private static JSONObject mergeOtherDetails(
        JSONObject otherDetails,
        JSONObject appInfo,
        JSONObject memoryInfo,
        JSONObject storageInfo,
        JSONObject deviceInfo
    ) {
        JSONObject mergedOtherDetails = otherDetails == null ? new JSONObject() : otherDetails;
        put(mergedOtherDetails, "appInfo", appInfo);
        put(mergedOtherDetails, "memoryInfo", memoryInfo);
        put(mergedOtherDetails, "storageInfo", storageInfo);
        put(mergedOtherDetails, "capacitorDeviceInfo", deviceInfo);
        put(mergedOtherDetails, "nativeException", true);
        put(mergedOtherDetails, "nativePlatform", "android");
        return mergedOtherDetails;
    }

    private static String getAndroidDeviceId() {
        Context context = appContext;
        if (context == null) {
            return "";
        }

        return Settings.Secure.getString(context.getContentResolver(), Settings.Secure.ANDROID_ID);
    }

    private static String getAndroidDeviceName() {
        Context context = appContext;
        String deviceName = "";
        if (context != null) {
            deviceName = Settings.Global.getString(context.getContentResolver(), "device_name");
        }

        return firstString(deviceName, Build.DEVICE, Build.MODEL);
    }

    private static boolean isProbablyEmulator() {
        return (
            Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.startsWith("unknown") ||
            Build.MODEL.contains("google_sdk") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for x86") ||
            Build.MANUFACTURER.contains("Genymotion") ||
            (Build.BRAND.startsWith("generic") && Build.DEVICE.startsWith("generic")) ||
            "google_sdk".equals(Build.PRODUCT)
        );
    }

    private static boolean postException(JSONObject payload) {
        final boolean[] uploaded = { false };
        Thread uploadThread = new Thread(() -> uploaded[0] = postExceptionSync(payload), "CapacitorExceptionUploader");
        uploadThread.start();
        try {
            uploadThread.join(UPLOAD_TIMEOUT_MS);
        } catch (InterruptedException interruptedException) {
            Thread.currentThread().interrupt();
        }
        return uploaded[0];
    }

    private static boolean postExceptionSync(JSONObject payload) {
        if (ingestUrl == null || ingestUrl.trim().isEmpty()) {
            Log.e(TAG, "Native fallback skipped because ingest URL is not configured");
            return false;
        }

        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(ingestUrl).openConnection();
            connection.setRequestMethod("POST");
            connection.setConnectTimeout(4000);
            connection.setReadTimeout(4000);
            connection.setDoOutput(true);
            connection.setRequestProperty("Content-Type", "application/json");
            if (apiKey != null && !apiKey.trim().isEmpty()) {
                connection.setRequestProperty("Api-Key", apiKey);
            }

            JSONObject headers = parseJsonObject(headersJson);
            Iterator<String> keys = headers.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                connection.setRequestProperty(key, headers.optString(key));
            }

            byte[] body = payload.toString().getBytes("UTF-8");
            try (OutputStream outputStream = connection.getOutputStream()) {
                outputStream.write(body);
            }

            int responseCode = connection.getResponseCode();
            if (responseCode < 200 || responseCode >= 300) {
                Log.e(TAG, "Native fallback failed with status " + responseCode);
                return false;
            }
            return true;
        } catch (Exception exception) {
            Log.e(TAG, "Native fallback failed", exception);
            return false;
        } finally {
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private static void persistConfiguration(Context context) {
        if (context == null) {
            return;
        }

        context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString("ingestUrl", ingestUrl)
            .putString("apiKey", apiKey)
            .putString("projectKey", projectKey)
            .putString("headersJson", headersJson)
            .putString("basePayloadJson", basePayloadJson)
            .putBoolean("enabled", enabled)
            .putBoolean("nativeFallbackEnabled", nativeFallbackEnabled)
            .putBoolean("executeOriginalHandler", executeOriginalHandler)
            .putBoolean("forceToQuit", forceToQuit)
            .putLong("holdTimeoutMs", holdTimeoutMs)
            .apply();
    }

    private static void restoreConfiguration(Context context) {
        if (context == null) {
            return;
        }

        ingestUrl = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString("ingestUrl", ingestUrl);
        apiKey = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString("apiKey", apiKey);
        projectKey = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString("projectKey", projectKey);
        headersJson = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString("headersJson", headersJson);
        basePayloadJson = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString("basePayloadJson", basePayloadJson);
        enabled = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getBoolean("enabled", enabled);
        nativeFallbackEnabled = context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean("nativeFallbackEnabled", nativeFallbackEnabled);
        executeOriginalHandler = context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean("executeOriginalHandler", executeOriginalHandler);
        forceToQuit = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getBoolean("forceToQuit", forceToQuit);
        holdTimeoutMs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getLong("holdTimeoutMs", holdTimeoutMs);
    }

    private static void persistPendingException(Context context, JSONObject payload) {
        if (context == null) {
            return;
        }

        context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_PAYLOAD_JSON_KEY, payload.toString())
            .commit();
    }

    private static void clearPendingException(Context context) {
        if (context == null) {
            return;
        }

        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit().remove(PENDING_PAYLOAD_JSON_KEY).commit();
    }

    private static String getIngestUrl(String url, String incomingProjectKey) {
        if (url == null) {
            return ingestUrl;
        }

        String trimmedUrl = url.replaceAll("/+$", "");
        if (incomingProjectKey == null || incomingProjectKey.trim().isEmpty()) {
            return trimmedUrl;
        }

        String suffix = "/exceptions/ingest/" + incomingProjectKey;
        return trimmedUrl.endsWith(suffix) ? trimmedUrl : trimmedUrl + suffix;
    }

    private static JSONObject parseJsonObject(String json) {
        try {
            return new JSONObject(json == null || json.trim().isEmpty() ? "{}" : json);
        } catch (Exception exception) {
            return new JSONObject();
        }
    }

    private static void put(JSONObject object, String key, Object value) {
        try {
            object.put(key, value == null ? JSONObject.NULL : value);
        } catch (JSONException ignored) {}
    }

    private static String firstString(String... values) {
        for (String value : values) {
            if (value != null && !value.trim().isEmpty() && !"null".equals(value)) {
                return value;
            }
        }
        return "";
    }

    private static String getIsoTimestamp() {
        SimpleDateFormat dateFormat = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US);
        dateFormat.setTimeZone(TimeZone.getTimeZone("UTC"));
        return dateFormat.format(new Date());
    }
}
