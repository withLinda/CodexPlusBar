import { readFile, readdir, stat } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';
import { parseManifest } from '@openchamber/sdk/schemas';
import { build } from 'esbuild';

const root = resolve('dist');
const metadata = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
const sourceMetadata = JSON.parse(await readFile('package.json', 'utf8'));
const parsed = parseManifest(metadata);
if (!parsed.ok) throw new Error(`Invalid extension manifest: ${JSON.stringify(parsed)}`);
const manifest = metadata.openchamber;
if (metadata.version !== sourceMetadata.version || manifest.apiVersion !== 1 || manifest.contributes.service.provides) throw new Error('Unexpected package contract');
const safePath = value => {
  if (typeof value !== 'string' || value.startsWith('/') || value.includes('..') || value.includes(':') || value.includes('\\')) throw new Error('Unsafe declared path');
  return join(root, value);
};
const panel = safePath(manifest.contributes.panel.entry), service = safePath(manifest.contributes.service.entry);
const pluginDirectory = safePath(manifest.contributes.opencodePlugin);
const pluginMetadata = JSON.parse(await readFile(join(pluginDirectory, 'package.json'), 'utf8'));
if (pluginMetadata.exports !== './index.js' || pluginMetadata.type !== 'module') throw new Error('Missing built plugin export');
for (const path of [panel, service, join(root, 'panel/main.js'), join(pluginDirectory, 'index.js'), safePath(manifest.contributes.panel.icon)]) {
  if (!(await stat(path)).isFile()) throw new Error(`Missing packaged asset: ${path}`);
}
const files = [];
async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Packaged symlink');
    if (entry.isDirectory()) await walk(path); else files.push(path);
  }
}
await walk(root);
for (const path of files) {
  if (/\.(ts|tsx|map)$/.test(path) || /(?:\.runtime|node_modules|fixtures|tests)\//.test(path)) throw new Error(`Non-distribution file: ${path}`);
  if (!path.endsWith('.js')) continue;
  const text = await readFile(path, 'utf8');
  if (/fixtureOrigin|expiry\.probe|account-fixture|cred_expiry_fixture|fixture-refresh|production-probe/.test(text)) throw new Error(`Test-only code: ${path}`);
  const syntax = spawnSync(process.execPath, ['--check', path], { encoding: 'utf8' });
  if (syntax.status !== 0) throw new Error(`Invalid built JavaScript: ${path}`);
  if (path.includes('/panel/')) {
    if (/^\s*(?:import|export)\s/m.test(text) || /require\(/.test(text)) throw new Error('Panel is not a standalone classic IIFE');
  } else {
    const result = await build({ entryPoints: [path], bundle: false, write: false, platform: 'node', format: 'esm', metafile: true });
    for (const output of Object.values(result.metafile.outputs)) for (const entry of output.imports) {
      if (!entry.path.startsWith('node:')) throw new Error(`Unbundled dependency: ${entry.path}`);
    }
  }
}
const html = await readFile(panel, 'utf8');
if (!/src=["']\.\/main\.js["']/.test(html) || /type=["']module|https?:\/\//.test(html)) throw new Error('Panel must use a package-local classic script');
const plugin = await import(pathToFileURL(join(pluginDirectory, 'index.js')).href);
if (plugin.default?.id !== 'codexplusbar-expiry-selector' || typeof plugin.default.setup !== 'function') throw new Error('Invalid plugin entry');
console.log(`Verified ${files.length} built files; manifest, classic panel, ESM plugin/service and private-fixture exclusion passed.`);
