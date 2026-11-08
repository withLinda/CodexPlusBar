import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, copyFile, cp } from 'node:fs/promises';
import { createServer } from 'node:net';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createHash } from 'node:crypto';
import { accounts, credential } from './fixtures.js';
import { tokenIdentity } from '../../src/shared/identity.js';

const binary = '/Applications/OpenChamber.app/Contents/Resources/opencode-cli/opencode';
const tempParent = '/private/var/folders/43/wvysbd0n0fs9n2724h44s4br0000gn/T/opencode';

async function unusedPort() {
  return new Promise<number>(resolvePort => {
    const listener = createServer();
    listener.listen(0, '127.0.0.1', () => {
      const address = listener.address();
      if (!address || typeof address === 'string') throw new Error('Missing port');
      listener.close(() => resolvePort(address.port));
    });
  });
}

export async function startHarness(fixtureOrigin: string, sharedCoordinatorPort?: number, hostDelivery = false, production = false, packaged = false) {
  const version = execFileSync(binary, ['--version'], { encoding: 'utf8' }).trim();
  if (version !== 'opencode v2.2.6') throw new Error(`Unsupported runtime: ${version}`);
  const checksum = createHash('sha256').update(await readFile(binary)).digest('hex');
  const root = await mkdtemp(join(tempParent, 'expiry-runtime-'));
  const locations = [join(root, 'one'), join(root, 'two')];
  for (const directory of [...locations, ...['home', 'data', 'config', 'cache', 'state'].map(p => join(root, p))]) {
    await mkdir(directory, { recursive: true, mode: 0o700 });
  }
  const plugin = packaged ? join(root, 'helper') : join(root, 'extension', 'plugin');
  if (packaged) await cp(resolve('dist'), join(root, 'extension'), { recursive: true });
  if (packaged) {
    const refresh = join(root, 'refresh-helper');
    await mkdir(refresh, { mode: 0o700 });
    await copyFile(resolve('.runtime/package-refresh.js'), join(refresh, 'probe.js'));
    await writeFile(join(refresh, 'package.json'), JSON.stringify({ name: 'expiry-fixture-refresh', type: 'module', exports: './index.js' }));
    await writeFile(join(refresh, 'index.js'), `import probe from './probe.js'; export default { ...probe, setup(ctx) { return probe.setup({ ...ctx, options: ${JSON.stringify({ fixtureOrigin })} }); } };\n`);
  }
  await mkdir(plugin, { recursive: true, mode: 0o700 });
  await copyFile(resolve(packaged ? '.runtime/package-helper.js' : production ? '.runtime/production-probe.js' : '.runtime/probe-plugin.js'), join(plugin, 'probe.js'));
  const snapshotPath = packaged ? join(root, 'home/Library/Application Support/CodexPlusBar/Exports/openchamber-selector-v1.json') : join(root, 'home/fixture-snapshot.json');
  if (production || packaged) {
    await mkdir(join(snapshotPath, '..'), { recursive: true, mode: 0o700 });
    const now = Date.now();
    await writeFile(snapshotPath, JSON.stringify({ schemaVersion: 1, sequence: 1, sourceInstanceID: crypto.randomUUID(),
      generatedAtMs: now, catalogTrusted: true, accounts: (['A', 'B'] as const).map((name, index) => {
        const identity = tokenIdentity(`Bearer ${credential(name).access}`)!;
        return { ...identity, profileID: crypto.randomUUID(), credentialID: accounts[name].id, label: name, bindingObservedAtMs: now,
          usage: { observedAtMs: now, identityKey: identity.identityKey, allowed: true, limitReached: false,
            fiveHour: { remainingPercent: 50, resetAtMs: now + 3600000 }, sevenDay: { state: 'not-applicable' } },
          entitlement: { observedAtMs: now, accountID: identity.accountID, expiresAtMs: now + (packaged ? 17 + index * 13 : index + 1) * 86400000,
            active: true, usable: true, deactivated: false, match: 'canonical' }, unavailableReasons: [] };
      }) }), { mode: 0o600 });
  }
  await writeFile(join(plugin, 'package.json'), JSON.stringify({ name: 'expiry-selector-probe', version: '0.1.0', type: 'module', exports: './index.js' }));
  const coordinatorPort = packaged ? 53971 : sharedCoordinatorPort ?? await unusedPort();
  await writeFile(join(plugin, 'index.js'), `import probe from './probe.js'; export default { ...probe, setup(ctx) { return probe.setup({ ...ctx, options: ${JSON.stringify({ fixtureOrigin, coordinatorPort })} }); } };\n`);
  if (!packaged) await writeFile(join(root, 'extension', 'package.json'), JSON.stringify({ name: 'expiry-selector-probe', version: '0.1.0',
    openchamber: { apiVersion: 1, engines: { openchamber: '>=2.7.0' }, contributes: {
      panel: { id: 'expiry-selector-probe', name: 'Compatibility fixture', icon: 'settings' }, opencodePlugin: 'plugin',
    } } }));
  const configuration = {
    plugins: hostDelivery && !packaged ? [] : [{ package: plugin, options: { fixtureOrigin, coordinatorPort } }],
    providers: { openai: { package: '@opencode/ai/providers/openai', settings: { transport: 'websocket', encoding: 'none' },
      models: { 'gpt-5.7': { name: 'Fixture', limit: { context: 100_000, output: 1000 } } } } },
    model: 'openai/gpt-5.7',
  };
  await writeFile(join(root, 'opencode.json'), JSON.stringify(configuration), { mode: 0o600 });
  // Enforced by the OS, including native OAuth and model-catalog requests.
  const profile = '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))';
  const port = await unusedPort();
  // A whitelist removes all inherited OpenCode, OpenAI, proxy, and provider credentials.
  const env: NodeJS.ProcessEnv = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', HOME: join(root, 'home'),
    TMPDIR: root, XDG_DATA_HOME: join(root, 'data'), XDG_CONFIG_HOME: join(root, 'config'),
    XDG_CACHE_HOME: join(root, 'cache'), XDG_STATE_HOME: join(root, 'state'),
    OPENCODE_SERVER_PASSWORD: 'expiry-fixture-password', OPENCODE_LOG_LEVEL: 'ERROR' };
  const hostAction = (action: string) => JSON.parse(execFileSync('/usr/bin/sandbox-exec', ['-p', profile, process.execPath,
    resolve('tests/runtime/host-control.mjs'), root, action], { env, encoding: 'utf8' }));
  if (hostDelivery) {
    execFileSync(process.execPath, ['scripts/extract-probe-host.mjs']);
    hostAction('install');
    env.OPENCODE_CONFIG = join(root, 'host-instance', 'opencode.managed.json');
  }
  let log = '';
  const launch = () => {
    const child = spawn('/usr/bin/sandbox-exec', ['-p', profile, binary, 'serve', '--hostname', '127.0.0.1', '--port', String(port)],
      { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', chunk => { log = (log + String(chunk)).slice(-12_000); });
    child.stderr.on('data', chunk => { log = (log + String(chunk)).slice(-12_000); });
    return child;
  };
  let child = launch();
  async function api(path: string, body?: unknown, location = locations[0]!, method = body === undefined ? 'GET' : 'POST'): Promise<any> {
    if (!path.startsWith('/api/') && path !== '/openapi.json') throw new Error('Fixture API path required');
    const response = await fetch(`http://127.0.0.1:${port}${path}`, {
      method, headers: { authorization: `Basic ${Buffer.from('opencode:expiry-fixture-password').toString('base64')}`,
        'content-type': 'application/json', 'x-opencode-directory': location },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }), signal: AbortSignal.timeout(30_000), redirect: 'error',
    });
    if (!response.ok) throw new Error(`${method} ${path}: ${response.status} ${await response.text()}`);
    const text = await response.text();
    return text ? JSON.parse(text) : undefined;
  }
  async function stop() {
    const exited = child.exitCode === null ? new Promise<void>(done => child.once('exit', () => done())) : Promise.resolve();
    if (child.exitCode === null) child.kill('SIGTERM');
    const kill = setTimeout(() => child.kill('SIGKILL'), 5000);
    await exited;
    clearTimeout(kill);
  }
  async function close() {
    await stop();
    await rm(root, { recursive: true, force: true });
  }
  try {
    let ready = false;
    for (let tries = 0; tries < 100; tries++) {
      if (child.exitCode !== null) throw new Error(`Isolated server exited: ${log}`);
      try {
        const info = await api('/api/info');
        if (info.pid !== child.pid) throw new Error('Isolated PID mismatch');
        ready = true;
        break;
      } catch (error) {
        if (error instanceof Error && error.message === 'Isolated PID mismatch') throw error;
        await delay(100);
      }
    }
    if (!ready) throw new Error(`Isolated server not ready: ${log}`);
    await writeFile(resolve('.runtime/openapi.json'), JSON.stringify(await api('/openapi.json')), { mode: 0o600 });
    for (const name of ['A', 'B'] as const) await api('/api/credential', {
      id: accounts[name].id, integrationID: 'openai', label: `Fixture ${name}`, value: credential(name), activate: false,
    });
    await api(`/api/credential/${accounts.A.id}/activate`, {});
    for (const location of locations) {
      let plugins;
      for (let attempt = 0; attempt < 100; attempt++) {
        plugins = await api('/api/plugin', undefined, location);
        if (plugins.data.some((p: any) => p.id === 'codexplusbar-expiry-selector-probe')) break;
        await delay(50);
      }
      if (!plugins.data.some((p: any) => p.id === 'codexplusbar-expiry-selector-probe' && p.state.status === 'active')) throw new Error(`Probe did not load: ${JSON.stringify(plugins.data.filter((p: any) => p.source.type !== 'builtin'))} ${log}`);
      if (packaged && !plugins.data.some((p: any) => p.id === 'codexplusbar-expiry-selector' && p.state.status === 'active')) {
        throw new Error(`Built plugin absent: ${JSON.stringify(plugins.data.filter((p: any) => p.source.type !== 'builtin'))}; managed: ${await readFile(join(root, 'host-instance/opencode.managed.json'), 'utf8')}`);
      }
      await api('/api/integration', undefined, location);
    }
    const rpc = async (method: string, input: unknown = {}, location = locations[0]!) =>
      (await api(`/api/rpc/expiry.probe/${method}`, { input }, location)).output;
    const configure = async (enabled: boolean, competitor = false) => {
      const competitorPath = join(root, 'competitor');
      await mkdir(competitorPath, { recursive: true });
      await writeFile(join(competitorPath, 'package.json'), JSON.stringify({ name: 'expiry-fixture-competitor', type: 'module', exports: './index.js' }));
      await writeFile(join(competitorPath, 'index.js'), "export default { id: 'openchamber-limit-failover', async setup() {} };\n");
      await writeFile(join(root, 'opencode.json'), JSON.stringify({ ...configuration,
        plugins: [...(enabled ? configuration.plugins : []), ...(competitor ? [{ package: competitorPath }] : [])] }), { mode: 0o600 });
      for (const location of locations) await api('/api/location/reload', {}, location);
    };
    const ownerStatus = async (release = false) => {
      const response = await fetch(`http://127.0.0.1:${coordinatorPort}${release ? '/release' : ''}`, {
        method: release ? 'POST' : 'GET', headers: { authorization: 'Bearer expiry-fixture-control' }, signal: AbortSignal.timeout(1000) });
      return response.json();
    };
    const restart = async () => {
      await stop(); child = launch();
      for (let attempt = 0; attempt < 100; attempt++) {
        try { if ((await api('/api/info')).pid === child.pid) {
          for (const location of locations) { await api('/api/plugin', undefined, location); await api('/api/integration', undefined, location); }
          return;
        } } catch { /* Await isolated process readiness. */ }
        await delay(100);
      }
      throw new Error('Isolated restart failed');
    };
    return { root, snapshotPath, api, rpc, locations, version, checksum, close, restart, configure, coordinatorPort, ownerStatus, hostAction, diagnostic: () => log };
  } catch (error) {
    await close();
    throw error;
  }
}
