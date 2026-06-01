export type ExceptionPayload = Record<string, unknown>;

export interface NativeExceptionEvent {
  title?: string;
  message?: string;
  stackTrace?: string;
  payload?: ExceptionPayload;
  uploadedByNative: boolean;
}

export interface ConfigureNativeExceptionHandlerOptions {
  url: string;
  apiKey: string;
  projectKey: string;
  enabled?: boolean;
  headers?: Record<string, string>;
  basePayload?: ExceptionPayload;
  nativeFallbackEnabled?: boolean;
  executeOriginalHandler?: boolean;
  forceToQuit?: boolean;
  holdTimeoutMs?: number;
}

export interface ReleaseExceptionHoldOptions {
  handled?: boolean;
}

export interface CrashForTestingOptions {
  message?: string;
}

export interface ExceptionTrackingPluginPlugin {
  configure(options: ConfigureNativeExceptionHandlerOptions): Promise<void>;
  releaseExceptionHold(options?: ReleaseExceptionHoldOptions): Promise<void>;
  uploadPendingException(): Promise<{ uploaded: boolean }>;
  crashForTesting(options?: CrashForTestingOptions): Promise<void>;
  addListener(
    eventName: 'nativeException',
    listenerFunc: (event: NativeExceptionEvent) => void,
  ): Promise<{ remove: () => Promise<void> }>;
}
