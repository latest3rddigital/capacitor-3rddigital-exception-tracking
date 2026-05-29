export interface ExceptionTrackingPluginPlugin {
  echo(options: { value: string }): Promise<{ value: string }>;
}
