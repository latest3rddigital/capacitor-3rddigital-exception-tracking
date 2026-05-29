import { WebPlugin } from '@capacitor/core';

import type { ExceptionTrackingPluginPlugin } from './definitions';

export class ExceptionTrackingPluginWeb extends WebPlugin implements ExceptionTrackingPluginPlugin {
  async echo(options: { value: string }): Promise<{ value: string }> {
    console.log('ECHO', options);
    return options;
  }
}
