import { registerPlugin } from '@capacitor/core';

import type { ExceptionTrackingPluginPlugin } from './definitions';

const ExceptionTrackingPlugin = registerPlugin<ExceptionTrackingPluginPlugin>('ExceptionTrackingPlugin', {
  web: () => import('./web').then((m) => new m.ExceptionTrackingPluginWeb()),
});

export * from './definitions';
export { ExceptionTrackingPlugin };
