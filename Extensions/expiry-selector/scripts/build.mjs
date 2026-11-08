import { build } from 'esbuild';

// Isolated runtime probes; packaging is supplied separately.
await build({
  entryPoints: ['tests/runtime/probe-plugin.ts'],
  outfile: '.runtime/probe-plugin.js',
  bundle: true,
  platform: 'node',
  format: 'esm',
  target: 'node22',
});
await build({ entryPoints: ['tests/runtime/production-probe.ts'], outfile: '.runtime/production-probe.js',
  bundle: true, platform: 'node', format: 'esm', target: 'node22' });
