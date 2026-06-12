import { WebPlugin } from '@capacitor/core';

import type {
  ConfigureNativeExceptionHandlerOptions,
  ExceptionTrackingPluginPlugin,
  UpdateNativeExceptionContextOptions,
} from './definitions';

export class ExceptionTrackingPluginWeb extends WebPlugin implements ExceptionTrackingPluginPlugin {
  async configure(_options: ConfigureNativeExceptionHandlerOptions): Promise<void> {
    return undefined;
  }

  async setContext(_options: UpdateNativeExceptionContextOptions): Promise<void> {
    return undefined;
  }

  async releaseExceptionHold(): Promise<void> {
    return undefined;
  }

  async uploadPendingException(): Promise<{ uploaded: boolean }> {
    return { uploaded: false };
  }

  async crashForTesting(): Promise<void> {
    throw new Error('Native crash testing is only available on Android and iOS.');
  }
}
