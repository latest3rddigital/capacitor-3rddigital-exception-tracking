import { registerPlugin } from '@capacitor/core';
import { App } from '@capacitor/app';
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
  const [info, id, batteryInfo, languageCode, languageTag, appInfo] = await Promise.all([
    getSettledValue(() => Device.getInfo()),
    getSettledValue(() => Device.getId()),
    getSettledValue(() => Device.getBatteryInfo()),
    getSettledValue(() => Device.getLanguageCode()),
    getSettledValue(() => Device.getLanguageTag()),
    getSettledValue(() => App.getInfo()),
  ]);
  const infoRecord = toPayloadRecord(info);
  const idRecord = toPayloadRecord(id);
  const appInfoRecord = toPayloadRecord(appInfo);
  const batteryInfoRecord = toPayloadRecord(batteryInfo);
  const nativeDeviceId = typeof idRecord?.identifier === 'string' ? idRecord.identifier : undefined;
  const nativeOsName = typeof infoRecord?.operatingSystem === 'string' ? infoRecord.operatingSystem : undefined;
  const nativeOsVersion = typeof infoRecord?.osVersion === 'string' ? infoRecord.osVersion : undefined;
  const nativeSystemName = nativeOsVersion ? `${nativeOsName ?? 'Unknown OS'} ${nativeOsVersion}` : nativeOsName;
  const nativeDeviceModel = typeof infoRecord?.model === 'string' ? infoRecord.model : undefined;
  const nativeDeviceName = typeof infoRecord?.name === 'string' ? infoRecord.name : undefined;
  const memoryInfo = {
    usedMemory: infoRecord?.memUsed,
    memUsed: infoRecord?.memUsed,
  };
  const storageInfo = {
    totalDiskCapacity: infoRecord?.diskTotal,
    freeDiskStorage: infoRecord?.diskFree,
    realDiskTotal: infoRecord?.realDiskTotal,
    realDiskFree: infoRecord?.realDiskFree,
  };

  return {
    source: 'capacitor',
    deviceId: nativeDeviceId,
    appVersion: appInfoRecord?.version,
    buildNumber: appInfoRecord?.build,
    browserInfo: {},
    osInfo: {
      name: nativeSystemName,
      osName: nativeOsName,
      osVersion: nativeOsVersion,
      systemName: nativeSystemName,
      systemVersion: nativeOsVersion,
      platform: infoRecord?.platform,
      apiLevel: infoRecord?.androidSDKVersion,
      webViewVersion: infoRecord?.webViewVersion,
    },
    deviceInfo: {
      ...infoRecord,
      model: nativeDeviceName || nativeDeviceModel,
      modelId: nativeDeviceModel,
      capacitorModel: nativeDeviceModel,
      rawDeviceInfo: infoRecord,
      deviceId: nativeDeviceId,
      uniqueId: nativeDeviceId,
      installationId: nativeDeviceId,
      name: nativeDeviceName,
      manufacturer: infoRecord?.manufacturer,
      systemName: nativeSystemName,
      systemVersion: nativeOsVersion,
      isEmulator: infoRecord?.isVirtual,
      languageCode: languageCode?.value,
      languageTag: languageTag?.value,
    },
    memoryInfo,
    storageInfo,
    batteryInfo: {
      ...batteryInfoRecord,
      batteryLevel: batteryInfoRecord?.batteryLevel,
      isCharging: batteryInfoRecord?.isCharging,
    },
    localeInfo: {
      languageCode: languageCode?.value,
      languageTag: languageTag?.value,
      timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    },
    otherDetails: {
      batteryInfo,
      memoryInfo,
      storageInfo,
      appInfo,
      capacitorDeviceInfo: info,
      capacitorBatteryInfo: batteryInfo,
      capacitorLanguageInfo: languageCode,
      capacitorLanguageTagInfo: languageTag,
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
      source: 'capacitor',
      deviceId: devicePayload.deviceId ?? basePayload.deviceId,
      appVersion: devicePayload.appVersion ?? basePayload.appVersion,
      buildNumber: devicePayload.buildNumber ?? basePayload.buildNumber,
      browserInfo: {},
      osInfo: mergeRecord(toPayloadRecord(devicePayload.osInfo), toPayloadRecord(basePayload.osInfo)),
      deviceInfo: mergeRecord(toPayloadRecord(devicePayload.deviceInfo), toPayloadRecord(basePayload.deviceInfo)),
      memoryInfo: mergeRecord(toPayloadRecord(devicePayload.memoryInfo), toPayloadRecord(basePayload.memoryInfo)),
      storageInfo: mergeRecord(toPayloadRecord(devicePayload.storageInfo), toPayloadRecord(basePayload.storageInfo)),
      batteryInfo: mergeRecord(toPayloadRecord(devicePayload.batteryInfo), toPayloadRecord(basePayload.batteryInfo)),
      localeInfo: mergeRecord(toPayloadRecord(devicePayload.localeInfo), toPayloadRecord(basePayload.localeInfo)),
      metadata: mergeRecord(
        {
          framework: 'capacitor',
          deviceContextSource: '@capacitor/device',
          appContextSource: '@capacitor/app',
          backendSource: 'capacitor',
          runtimeSource: 'capacitor',
          errorSource: 'native',
        },
        toPayloadRecord(basePayload.metadata),
      ),
      otherDetails: mergeRecord(toPayloadRecord(devicePayload.otherDetails), toPayloadRecord(basePayload.otherDetails)),
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
