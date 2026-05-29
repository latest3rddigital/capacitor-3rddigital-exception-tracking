# 3rdDigital Native Exception Tracking Example

This example app configures `capacitor-3rddigital-exception-tracking`, listens for `nativeException` events, retries pending crash payloads, and includes a button that intentionally triggers a native crash for testing.

## Run

```bash
npm install
npm run build
npx cap sync
npx cap run android
```

Use the form in the app to enter `url`, `apiKey`, and `projectKey`. The values are saved in local storage for the next run.

Optional Vite environment variables:

```bash
VITE_EXCEPTION_URL=https://dev.3rddigital.com/appupdate-api/api
VITE_EXCEPTION_API_KEY=your-api-key
VITE_EXCEPTION_PROJECT_KEY=your-project-key
VITE_APP_VERSION=1.0.0
```
