import { build } from 'esbuild';
import { mkdir, copyFile, writeFile, readFile, access, rm } from 'node:fs/promises';

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
await build({ entryPoints: ['tests/runtime/package-helper.ts'], outfile: '.runtime/package-helper.js',
  bundle: true, platform: 'node', format: 'esm', target: 'node22' });
await build({ entryPoints: ['tests/runtime/package-refresh.ts'], outfile: '.runtime/package-refresh.js',
  bundle: true, platform: 'node', format: 'esm', target: 'node22' });
if (process.argv.includes('--probes-only')) process.exit(0);

const metadata = JSON.parse(await readFile('package.json', 'utf8'));
// Release builds must never retain files from an older distribution.
await rm('dist', { recursive: true, force: true });
await mkdir('dist/plugin', { recursive: true });
await mkdir('dist/service', { recursive: true });
await writeFile('dist/package.json', JSON.stringify({ name: metadata.name, version: metadata.version, type: 'module',
  openchamber: { apiVersion: 1, engines: { openchamber: '>=2.7.0' }, contributes: {
    panel: { id: 'codexplusbar-expiry-selector', name: 'Account Priority', icon: 'icon.svg', entry: 'panel/index.html' },
    opencodePlugin: 'plugin', service: { entry: 'service/main.js', runtime: 'host' },
  } } }, null, 2));
await writeFile('dist/plugin/package.json', JSON.stringify({ name: 'codexplusbar-expiry-selector-plugin', version: metadata.version,
  type: 'module', exports: './index.js' }, null, 2));
await build({ entryPoints: ['src/plugin/index.ts'], outfile: 'dist/plugin/index.js', bundle: true, platform: 'node', format: 'esm', target: 'node22' });
await build({ entryPoints: ['src/service/main.ts'], outfile: 'dist/service/main.js', bundle: true, platform: 'node', format: 'esm', target: 'node22' });
await copyFile('README.md', 'dist/README.md');
// Keep an incomplete UI build explicit until its design and implementation are ready.
await access('src/panel/index.html');
await mkdir('dist/panel', { recursive: true });
await copyFile('src/panel/index.html', 'dist/panel/index.html');
await copyFile('src/panel/icon.svg', 'dist/icon.svg');
await build({ entryPoints: ['src/panel/main.ts'], outfile: 'dist/panel/main.js', bundle: true, platform: 'browser', format: 'iife', target: 'es2022' });
