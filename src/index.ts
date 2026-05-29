import { registerPlugin } from '@capacitor/core';
import { Device } from '@capacitor/device';

import type { ConfigureNativeExceptionHandlerOptions, ExceptionTrackingPluginPlugin } from './definitions';

const NativeExceptionHandlerNative = registerPlugin<ExceptionTrackingPluginPlugin>('NativeExceptionHandler', {
  web: () => import('./web').then((m) => new m.ExceptionTrackingPluginWeb()),
});

const getSettledValue = async <T>(getter: () => Promise<T>): Promise<T | undefined> => {
  try {
    return await getter();
  } catch {
    return undefined;
  }
};

const toPayloadRecord = (value: unknown): Record<string, unknown> | undefined => {
  if (!value || typeof value !== 'object') {
    return undefined;
  }

  return { ...(value as object) } as Record<string, unknown>;
};

const getDevicePayload = async () => {
  const [info, id, batteryInfo, languageCode, languageTag] = await Promise.all([
    getSettledValue(() => Device.getInfo()),
    getSettledValue(() => Device.getId()),
    getSettledValue(() => Device.getBatteryInfo()),
    getSettledValue(() => Device.getLanguageCode()),
    getSettledValue(() => Device.getLanguageTag()),
  ]);
  const infoRecord = toPayloadRecord(info);
  const idRecord = toPayloadRecord(id);

  return {
    osInfo: {
      osName: infoRecord?.operatingSystem,
      osVersion: infoRecord?.osVersion,
      platform: infoRecord?.platform,
      webViewVersion: infoRecord?.webViewVersion,
    },
    deviceInfo: {
      deviceId: idRecord?.identifier,
      name: infoRecord?.name,
      model: infoRecord?.model,
      manufacturer: infoRecord?.manufacturer,
      isVirtual: infoRecord?.isVirtual,
      memUsed: infoRecord?.memUsed,
      diskFree: infoRecord?.diskFree,
      realDiskFree: infoRecord?.realDiskFree,
      diskTotal: infoRecord?.diskTotal,
      realDiskTotal: infoRecord?.realDiskTotal,
    },
    batteryInfo,
    localeInfo: {
      languageCode: languageCode?.value,
      languageTag: languageTag?.value,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    },
  };
};

const mergeRecord = (
  left: Record<string, unknown> | undefined,
  right: Record<string, unknown> | undefined,
): Record<string, unknown> => ({
  ...(left ?? {}),
  ...(right ?? {}),
});

const withDevicePayload = async (
  options: ConfigureNativeExceptionHandlerOptions,
): Promise<ConfigureNativeExceptionHandlerOptions> => {
  const devicePayload = await getDevicePayload();
  const basePayload = options.basePayload ?? {};

  return {
    ...options,
    basePayload: {
      ...basePayload,
      osInfo: mergeRecord(toPayloadRecord(devicePayload.osInfo), toPayloadRecord(basePayload.osInfo)),
      deviceInfo: mergeRecord(toPayloadRecord(devicePayload.deviceInfo), toPayloadRecord(basePayload.deviceInfo)),
      batteryInfo: mergeRecord(toPayloadRecord(devicePayload.batteryInfo), toPayloadRecord(basePayload.batteryInfo)),
      localeInfo: mergeRecord(toPayloadRecord(devicePayload.localeInfo), toPayloadRecord(basePayload.localeInfo)),
      metadata: mergeRecord(
        {
          framework: 'capacitor',
          deviceContextSource: '@capacitor/device',
        },
        toPayloadRecord(basePayload.metadata),
      ),
    },
  };
};

const NativeExceptionHandler: ExceptionTrackingPluginPlugin = {
  configure: async (options) => NativeExceptionHandlerNative.configure(await withDevicePayload(options)),
  releaseExceptionHold: (options) => NativeExceptionHandlerNative.releaseExceptionHold(options),
  uploadPendingException: () => NativeExceptionHandlerNative.uploadPendingException(),
  crashForTesting: (options) => NativeExceptionHandlerNative.crashForTesting(options),
  addListener: (eventName, listenerFunc) => NativeExceptionHandlerNative.addListener(eventName, listenerFunc),
};

export * from './definitions';
export { NativeExceptionHandler };
export const ExceptionTrackingPlugin = NativeExceptionHandler;
