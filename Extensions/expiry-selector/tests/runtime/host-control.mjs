import fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const [root, action] = process.argv.slice(2);
if (!root?.includes('/T/opencode/expiry-runtime-') || process.env.HOME !== path.join(root, 'home')) throw new Error('Isolated host required');
const source = path.resolve('.runtime/host/node_modules/@openchamber/web/server/lib');
const load = name => import(pathToFileURL(path.join(source, name)).href);
const { installGuestFromPath, uninstallGuest } = await load('guests/install.js');
const { setGuestEnabled } = await load('guests/service.js');
const { setCapabilityGrants } = await load('guests/persist.js');
const { listInstalledGuests } = await load('guests/catalog.js');
const { createGuestAgentContext } = await load('guests/agent-context.js');
const { createManagedConfigRuntime } = await load('opencode/managed-config-file.js');
const persistPath = path.join(root, 'host-instance', 'extensions.json');
const id = 'expiry-selector-probe';
if (action === 'install') {
  const installed = await installGuestFromPath(path.join(root, 'extension'), persistPath, { openchamberVersion: '2.7.0' });
  if (!installed.ok) throw new Error(`Fixture install rejected: ${installed.code}`);
  await setCapabilityGrants(id, persistPath, ['opencodePlugin']);
} else if (action === 'disable' || action === 'enable') {
  await setGuestEnabled(id, persistPath, action === 'enable');
} else if (action === 'uninstall') {
  const removed = await uninstallGuest(id, persistPath);
  if (!removed.ok) throw new Error(`Fixture uninstall rejected: ${removed.code}`);
} else { throw new Error('Unknown fixture action'); }
const context = createGuestAgentContext({ listGuests: () => listInstalledGuests({ persistPath }) });
const managed = createManagedConfigRuntime({ fsPromises: fs, path, instanceDir: path.join(root, 'host-instance'),
  env: {}, readSettings: async () => ({}), listExtensionPluginDirectories: context.pluginDirectories, openchamberVersion: '2.7.0' });
await managed.buildManagedChildEnv();
console.log(JSON.stringify({ action, plugins: (await context.pluginDirectories()).length }));
