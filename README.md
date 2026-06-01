# capacitor-3rddigital-exception-tracking

Native exception tracking bridge for Capacitor apps. It installs Android and iOS uncaught exception handlers, builds a native crash payload, posts it to the 3rdDigital exception ingestion API, and persists failed crash payloads for retry on the next launch.

## Install

To use npm

```bash
npm install capacitor-3rddigital-exception-tracking
npm install @capacitor/app
npm install @capacitor/device
```

To use yarn

```bash
yarn add capacitor-3rddigital-exception-tracking
yarn add @capacitor/app
yarn add @capacitor/device
```

Sync native files

```bash
npx cap sync
```

## Setup

The plugin is registered as `NativeExceptionHandler` to match the existing 3rdDigital Capacitor app usage.

```ts
import { NativeExceptionHandler } from 'capacitor-3rddigital-exception-tracking';

await NativeExceptionHandler.addListener('nativeException', async (event) => {
  if (event.uploadedByNative) {
    await NativeExceptionHandler.releaseExceptionHold({ handled: true });
    return;
  }

  // Native fallback upload failed or was disabled.
  // Keep handled=false so the payload remains persisted for retry.
  await NativeExceptionHandler.releaseExceptionHold({ handled: false });
});

await NativeExceptionHandler.configure({
  url: 'https://your-api.example.com/api',
  apiKey: 'your-api-key',
  projectKey: 'your-project-key',
  enabled: true,
  nativeFallbackEnabled: true,
  executeOriginalHandler: true,
  forceToQuit: false,
  holdTimeoutMs: 5000,
  basePayload: {
    appVersion: '1.0.0',
    metadata: {
      framework: 'capacitor',
    },
  },
});
```

The native plugin posts fallback crash reports to:

```txt
{url}/exceptions/ingest/{projectKey}
```

If `url` already ends with `/exceptions/ingest/{projectKey}`, that exact URL is used.

## Options

| Option                   | Required | Description                                                                                   |
| ------------------------ | -------- | --------------------------------------------------------------------------------------------- |
| `url`                    | Yes      | Base API URL or full ingest URL.                                                              |
| `apiKey`                 | Yes      | Sent as the `Api-Key` header.                                                                 |
| `projectKey`             | Yes      | Project identifier used in the ingest URL and payload.                                        |
| `enabled`                | No       | Enables this plugin's native exception tracking. Set `false` to skip handler installation, event emission, pending retries, and native API calls. Defaults to `true`. |
| `headers`                | No       | Extra request headers.                                                                        |
| `basePayload`            | No       | Static payload fields merged into every native crash report.                                  |
| `nativeFallbackEnabled`  | No       | Enables native-side upload before the app exits. Defaults to `true`.                          |
| `executeOriginalHandler` | No       | Runs the previous native crash handler after reporting. Defaults to `true`.                   |
| `forceToQuit`            | No       | Forces process termination after handling when no original handler runs. Defaults to `false`. |
| `holdTimeoutMs`          | No       | Time to wait for the JS listener to call `releaseExceptionHold`. Defaults to `5000`.          |

Use `enabled: false` for debug builds when you do not want this package to capture or upload native exceptions. The flag can also be set to `false` in release builds. It only disables this plugin's native handler and API calls; it does not disable or configure other crash libraries such as Firebase Crashlytics or Sentry.

### Methods

| Method                                     | Description                                                                                             |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| `configure(options)`                       | Persists API settings, installs the native crash handler, and retries any pending native crash payload. |
| `releaseExceptionHold({ handled })`        | Releases the short native crash hold after the JS listener handles a `nativeException` event.           |
| `uploadPendingException()`                 | Attempts to upload a persisted crash payload from the previous launch.                                  |
| `addListener('nativeException', listener)` | Receives native crash payloads before the app continues the original crash flow.                        |
| `crashForTesting({ message })`             | Triggers an uncaught native exception for local testing. Do not call this in production flows.          |

## Event Payload

`nativeException` emits:

```ts
type NativeExceptionEvent = {
  title?: string;
  message?: string;
  stackTrace?: string;
  uploadedByNative: boolean;
  payload?: Record<string, unknown>;
};
```

When `uploadedByNative` is `true`, the native fallback already posted the payload successfully. When it is `false`, call `releaseExceptionHold({ handled: false })` if you want the plugin to keep the pending payload for retry.

## Device Details

The package automatically enriches native crash payloads with app, OS, device, battery, locale, memory, storage, and screen details. The JS `configure()` wrapper uses `@capacitor/app` and `@capacitor/device`, while the Android and iOS implementations also add native-only fields such as package/bundle version, Android ID or iOS vendor identifier, memory, ABI, and screen metrics.

Reports always send backend-counted fields in the expected shape: `source` is `capacitor`, native-origin details are sent in `stackSource`, `metadata.errorSource`, and `otherDetails`, `deviceId` is top-level, and Capacitor native reports send `browserInfo` as an empty object. Native crash payloads also include route context by preserving app-provided `screenName`, `pageUrl`, `url`, `path`, and `pathname` values; otherwise the package derives them from the current WebView URL and defaults `screenName` to `UnknownScreen` when no path is available. Values passed in `basePayload` are preserved for extra context, but these backend-counted fields are normalized by the package so dashboards and device counts stay correct.

## Example App

The `example-app` folder contains a Vite Capacitor app that can configure the plugin, retry pending payloads, and trigger a native test crash.

```bash
cd example-app
npm install
npm run build
npx cap sync
npx cap run android
```

For iOS, use `npx cap run ios` or open `example-app/ios/App/App.xcodeproj`.
