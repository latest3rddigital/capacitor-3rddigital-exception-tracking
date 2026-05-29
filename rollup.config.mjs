export default {
  input: 'dist/esm/index.js',
  output: [
    {
      file: 'dist/plugin.js',
      format: 'iife',
      name: 'capacitorExceptionTrackingPlugin',
      globals: {
        '@capacitor/app': 'capacitorApp',
        '@capacitor/core': 'capacitorExports',
        '@capacitor/device': 'capacitorDevice',
      },
      sourcemap: true,
      inlineDynamicImports: true,
    },
    {
      file: 'dist/plugin.cjs.js',
      format: 'cjs',
      sourcemap: true,
      inlineDynamicImports: true,
    },
  ],
  external: ['@capacitor/app', '@capacitor/core', '@capacitor/device'],
};
