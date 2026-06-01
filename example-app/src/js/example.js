import { Capacitor } from '@capacitor/core';
import { NativeExceptionHandler } from 'capacitor-3rddigital-exception-tracking';

const fields = {
  url: document.querySelector('#url'),
  apiKey: document.querySelector('#apiKey'),
  projectKey: document.querySelector('#projectKey'),
  appVersion: document.querySelector('#appVersion'),
  enabled: document.querySelector('#enabled'),
  nativeFallbackEnabled: document.querySelector('#nativeFallbackEnabled'),
  executeOriginalHandler: document.querySelector('#executeOriginalHandler'),
  forceToQuit: document.querySelector('#forceToQuit'),
};

const elements = {
  status: document.querySelector('#status'),
  log: document.querySelector('#eventLog'),
  platform: document.querySelector('#platform'),
  configure: document.querySelector('#configure'),
  uploadPending: document.querySelector('#uploadPending'),
  crashForTesting: document.querySelector('#crashForTesting'),
  clearLog: document.querySelector('#clearLog'),
};

const storageKey = 'exception-tracking-example-config';
let listenerHandle;

const defaultConfig = {
  url: import.meta.env.VITE_EXCEPTION_URL || '',
  apiKey: import.meta.env.VITE_EXCEPTION_API_KEY || '',
  projectKey: import.meta.env.VITE_EXCEPTION_PROJECT_KEY || '',
  appVersion: import.meta.env.VITE_APP_VERSION || '1.0.0',
  enabled: true,
  nativeFallbackEnabled: true,
  executeOriginalHandler: true,
  forceToQuit: false,
};

const loadConfig = () => {
  try {
    return {
      ...defaultConfig,
      ...JSON.parse(localStorage.getItem(storageKey) || '{}'),
    };
  } catch {
    return defaultConfig;
  }
};

const saveConfig = (config) => {
  localStorage.setItem(storageKey, JSON.stringify(config));
};

const setStatus = (message) => {
  elements.status.textContent = message;
};

const appendLog = (label, data) => {
  const item = document.createElement('li');
  const time = new Date().toLocaleTimeString();
  const title = document.createElement('strong');
  const details = document.createElement('pre');
  title.textContent = `${time} - ${label}`;
  details.textContent = JSON.stringify(data, null, 2);
  item.append(title, details);
  elements.log.prepend(item);
};

const fillForm = () => {
  const config = loadConfig();
  fields.url.value = config.url;
  fields.apiKey.value = config.apiKey;
  fields.projectKey.value = config.projectKey;
  fields.appVersion.value = config.appVersion;
  fields.enabled.checked = config.enabled;
  fields.nativeFallbackEnabled.checked = config.nativeFallbackEnabled;
  fields.executeOriginalHandler.checked = config.executeOriginalHandler;
  fields.forceToQuit.checked = config.forceToQuit;
};

const readForm = () => ({
  url: fields.url.value.trim(),
  apiKey: fields.apiKey.value.trim(),
  projectKey: fields.projectKey.value.trim(),
  appVersion: fields.appVersion.value.trim() || '1.0.0',
  enabled: fields.enabled.checked,
  nativeFallbackEnabled: fields.nativeFallbackEnabled.checked,
  executeOriginalHandler: fields.executeOriginalHandler.checked,
  forceToQuit: fields.forceToQuit.checked,
});

const buildNativeOptions = () => {
  const config = readForm();
  saveConfig(config);

  return {
    url: config.url,
    apiKey: config.apiKey,
    projectKey: config.projectKey,
    enabled: config.enabled,
    nativeFallbackEnabled: config.nativeFallbackEnabled,
    executeOriginalHandler: config.executeOriginalHandler,
    forceToQuit: config.forceToQuit,
    holdTimeoutMs: 5000,
    basePayload: {
      projectKey: config.projectKey,
      appVersion: config.appVersion,
      metadata: {
        framework: 'capacitor',
        sampleApp: true,
      },
      extraData: {
        configuredFrom: 'capacitor-example-app',
      },
    },
  };
};

const ensureListener = async () => {
  if (listenerHandle) {
    return;
  }

  listenerHandle = await NativeExceptionHandler.addListener('nativeException', async (event) => {
    appendLog('nativeException', event);

    await NativeExceptionHandler.releaseExceptionHold({
      handled: Boolean(event.uploadedByNative),
    });
  });
};

const configureHandler = async () => {
  if (!Capacitor.isNativePlatform()) {
    setStatus('Open this example on Android or iOS to configure native exception tracking.');
    return;
  }

  const options = buildNativeOptions();
  if (!options.url || !options.apiKey || !options.projectKey) {
    setStatus('Fill URL, API key, and project key before configuring.');
    return;
  }

  await ensureListener();
  await NativeExceptionHandler.configure(options);
  appendLog('configured', {
    url: options.url,
    projectKey: options.projectKey,
    enabled: options.enabled,
    nativeFallbackEnabled: options.nativeFallbackEnabled,
  });
  setStatus('Native exception tracking configured.');
};

const uploadPending = async () => {
  const result = await NativeExceptionHandler.uploadPendingException();
  appendLog('uploadPendingException', result);
  setStatus(result.uploaded ? 'Pending exception uploaded.' : 'No pending exception uploaded.');
};

const crashForTesting = async () => {
  if (!Capacitor.isNativePlatform()) {
    setStatus('Native crash testing only runs on Android or iOS.');
    return;
  }

  await configureHandler();
  NativeExceptionHandler.crashForTesting({
    message: `Manual native test crash from ${Capacitor.getPlatform()}`,
  });
};

fillForm();
elements.platform.textContent = `${Capacitor.getPlatform()}${Capacitor.isNativePlatform() ? ' native' : ' web'}`;
elements.configure.addEventListener('click', configureHandler);
elements.uploadPending.addEventListener('click', uploadPending);
elements.crashForTesting.addEventListener('click', crashForTesting);
elements.clearLog.addEventListener('click', () => {
  elements.log.innerHTML = '';
  setStatus('Log cleared.');
});
