import { build } from 'esbuild';

// Task 1 builds only the compatibility probe. It is never an installable extension.
await build({
  entryPoints: ['tests/runtime/probe-plugin.ts'],
  outfile: '.runtime/probe-plugin.js',
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node22',
});
