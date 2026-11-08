import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, writeFile, readFile, rm, copyFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { join, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { createHash } from 'node:crypto';
import { accounts, credential } from './fixtures.js';

const binary = '/Applications/OpenChamber.app/Contents/Resources/opencode-cli/opencode';
const tempParent = '/private/var/folders/43/wvysbd0n0fs9n2724h44s4br0000gn/T/opencode';

export async function startHarness(fixtureOrigin: string) {
  const version = execFileSync(binary, ['--version'], { encoding: 'utf8' }).trim();
  if (version !== 'opencode v2.2.6') throw new Error(`Unsupported runtime: ${version}`);
  const checksum = createHash('sha256').update(await readFile(binary)).digest('hex');
  const root = await mkdtemp(join(tempParent, 'expiry-runtime-'));
  const locations = [join(root, 'one'), join(root, 'two')];
  for (const directory of [...locations, ...['home', 'data', 'config', 'cache', 'state'].map(p => join(root, p))]) {
    await mkdir(directory, { recursive: true, mode: 0o700 });
  }
  const plugin = join(root, 'plugin');
  await mkdir(plugin, { mode: 0o700 });
  await copyFile(resolve('.runtime/probe-plugin.js'), join(plugin, 'index.js'));
  await writeFile(join(plugin, 'package.json'), JSON.stringify({ name: 'expiry-selector-probe', version: '0.1.0', type: 'module', exports: './index.js' }));
  await writeFile(join(root, 'opencode.json'), JSON.stringify({
    plugins: [{ package: plugin, options: { fixtureOrigin } }],
    providers: { openai: { package: '@opencode/ai/providers/openai', settings: { transport: 'websocket', encoding: 'none' },
      models: { 'gpt-5.7': { name: 'Fixture', limit: { context: 100_000, output: 1000 } } } } },
    model: 'openai/gpt-5.7',
  }), { mode: 0o600 });
  // Enforced by the OS, including native OAuth and model-catalog requests.
  const profile = '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))';
  const port = await new Promise<number>(resolvePort => {
    const listener = createServer();
    listener.listen(0, '127.0.0.1', () => {
      const address = listener.address();
      if (!address || typeof address === 'string') throw new Error('Missing port');
      listener.close(() => resolvePort(address.port));
    });
  });
  // A whitelist removes all inherited OpenCode, OpenAI, proxy, and provider credentials.
  const env = { PATH: '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin', HOME: join(root, 'home'),
    TMPDIR: root, XDG_DATA_HOME: join(root, 'data'), XDG_CONFIG_HOME: join(root, 'config'),
    XDG_CACHE_HOME: join(root, 'cache'), XDG_STATE_HOME: join(root, 'state'),
    OPENCODE_SERVER_PASSWORD: 'expiry-fixture-password', OPENCODE_LOG_LEVEL: 'ERROR' };
  const child = spawn('/usr/bin/sandbox-exec', ['-p', profile, binary, 'serve', '--hostname', '127.0.0.1', '--port', String(port)],
    { cwd: root, env, stdio: ['ignore', 'pipe', 'pipe'] });
  let log = '';
  child.stdout.on('data', chunk => { log = (log + String(chunk)).slice(-12_000); });
  child.stderr.on('data', chunk => { log = (log + String(chunk)).slice(-12_000); });
  const exited = new Promise<void>(done => child.once('exit', () => done()));
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
  async function close() {
    if (child.exitCode === null) child.kill('SIGTERM');
    const kill = setTimeout(() => child.kill('SIGKILL'), 5000);
    await exited;
    clearTimeout(kill);
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
      await api('/api/integration', undefined, location);
    }
    const rpc = async (method: string, input: unknown = {}, location = locations[0]!) =>
      (await api(`/api/rpc/expiry.probe/${method}`, { input }, location)).output;
    return { api, rpc, locations, version, checksum, close, diagnostic: () => log };
  } catch (error) {
    await close();
    throw error;
  }
}
