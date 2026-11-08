import { afterEach, expect, test } from 'vitest';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createServer, type RequestListener } from 'node:http';
import { SelectorClient, readDescriptor } from '../src/service/client.js';
import { startService, serviceEnvironment } from '../src/service/server.js';
import { SelectorCoordinator } from '../src/plugin/coordinator.js';
import { initialState } from '../src/plugin/state-store.js';

const cleanups: (() => Promise<unknown>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });
const status = () => new SelectorCoordinator({ now: Date.now, owns: () => true, readSnapshot: async () => ({ ok: false, code: 'snapshot-missing' }),
  loadState: async () => initialState(), saveState: async () => {} }).status();
async function descriptorFixture(port = 53971) {
  const directory = await mkdtemp(join(process.env.TMPDIR!, 'expiry-service-'));
  cleanups.push(() => rm(directory, { recursive: true, force: true }));
  const descriptor = { protocolVersion: 1 as const, pid: process.pid, epoch: crypto.randomUUID(), port, bearer: 'a'.repeat(64) };
  const write = async (value = descriptor) => { await writeFile(join(directory, 'runtime.json'), JSON.stringify(value), { mode: 0o600 }); };
  await write(); return { directory, descriptor, write };
}
async function upstream(handler: RequestListener) {
  const server = createServer(handler);
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  cleanups.push(() => new Promise<void>(resolve => { server.close(() => resolve()); server.closeAllConnections(); }));
  return (server.address() as { port: number }).port;
}

test('host environment is mandatory and port must be a numeric loopback port', () => {
  for (const env of [{}, { OPENCHAMBER_SERVICE_PORT: '0', OPENCHAMBER_SERVICE_TOKEN: 'host' },
    { OPENCHAMBER_SERVICE_PORT: 'http://example.com', OPENCHAMBER_SERVICE_TOKEN: 'host' }]) expect(() => serviceEnvironment(env)).toThrow();
  expect(serviceEnvironment({ OPENCHAMBER_SERVICE_PORT: '12345', OPENCHAMBER_SERVICE_TOKEN: 'host-token' })).toEqual({ port: 12345, token: 'host-token' });
});

test('private descriptor rejects insecure mode, unexpected port and extra origin', async () => {
  const f = await descriptorFixture(); expect(await readDescriptor(f.directory)).toEqual(f.descriptor);
  await chmod(join(f.directory, 'runtime.json'), 0o644); await expect(readDescriptor(f.directory)).rejects.toThrow('descriptor-invalid');
  await chmod(join(f.directory, 'runtime.json'), 0o600);
  await f.write({ ...f.descriptor, port: 443 }); await expect(readDescriptor(f.directory)).rejects.toThrow('descriptor-invalid');
  await writeFile(join(f.directory, 'runtime.json'), JSON.stringify({ ...f.descriptor, origin: 'https://example.com' }));
  await expect(readDescriptor(f.directory)).rejects.toThrow('descriptor-invalid');
});

test('health and all forwards require host bearer; fixed routes and status projection hide secrets', async () => {
  let calls = 0;
  const port = await upstream((_request, response) => {
    calls++; response.end(JSON.stringify({ protocolVersion: 1, epoch: f.descriptor.epoch, ...status(), bearer: 'private-sentinel' }));
  });
  const f = await descriptorFixture(port);
  const client = new SelectorClient({ directory: f.directory, port });
  const service = await startService({ port: 0, token: 'host-token', client }); cleanups.push(service.close);
  const base = `http://127.0.0.1:${service.port}`;
  for (const path of ['/health', '/v1/status', '/v1/mode']) expect((await fetch(base + path)).status).toBe(401);
  expect(calls).toBe(0);
  const headers = { authorization: 'Bearer host-token', 'content-type': 'application/json' };
  expect((await fetch(base + '/health', { headers })).status).toBe(200);
  const reply = await fetch(base + '/v1/status', { headers });
  expect(reply.status).toBe(200);
  const text = await reply.text(); expect(text).not.toContain('private-sentinel'); expect(text).not.toContain(f.descriptor.bearer);
  expect((await fetch(base + '/v1/maintenance/begin', { headers, method: 'POST', body: '{}' })).status).toBe(404);
  expect((await fetch(base + '/v1/mode', { headers, method: 'POST', body: JSON.stringify({ operationID: crypto.randomUUID(), mode: 'auto', url: 'https://example.com' }) })).status).toBe(400);
  expect((await fetch(base + '/v1/mode', { headers: { ...headers, origin: 'https://example.com' }, method: 'POST', body: '{}' })).status).toBe(403);
  expect((await fetch(base + '/v1/mode', { headers, method: 'POST', body: 'a'.repeat(65_537) })).status).toBe(413);
  expect(calls).toBe(1);
});

test('missing descriptor is diagnostic, never a second backend discovery', async () => {
  const f = await descriptorFixture(); await rm(join(f.directory, 'runtime.json'));
  await expect(new SelectorClient({ directory: f.directory }).call('status')).rejects.toThrow('selector-unavailable');
});

test('oversized or redirected upstream is refused without following another origin', async () => {
  let redirect = false;
  const port = await upstream((_request, response) => {
    if (redirect) { response.writeHead(302, { location: 'https://example.com' }); response.end(); }
    else response.end('x'.repeat(1_048_577));
  });
  const f = await descriptorFixture(port), client = new SelectorClient({ directory: f.directory, port });
  await expect(client.call('status')).rejects.toThrow(); redirect = true;
  await expect(client.call('status')).rejects.toThrow('control-unavailable');
});

test('lost mode response retries identical operation and epoch, stale owner refuses POST replay', async () => {
  const received: string[] = []; let restart = false;
  const port = await upstream(async (request, response) => {
    let body = ''; for await (const chunk of request) body += chunk; received.push(body);
    if (received.length === 1) { request.socket.destroy(); return; }
    if (restart) {
      const next = { ...f.descriptor, epoch: crypto.randomUUID() }; await f.write(next);
      response.writeHead(409); response.end(JSON.stringify({ protocolVersion: 1, epoch: next.epoch })); return;
    }
    response.end(JSON.stringify({ protocolVersion: 1, epoch: f.descriptor.epoch, ...status() }));
  });
  const f = await descriptorFixture(port), client = new SelectorClient({ directory: f.directory, port });
  const body = { operationID: crypto.randomUUID(), mode: 'paused' };
  expect((await client.call('mode', body)).mode).toBe('paused'); expect(received).toEqual([JSON.stringify(body), JSON.stringify(body)]);
  restart = true; await expect(client.call('mode', body)).rejects.toThrow('ownership-changed'); expect(received).toHaveLength(3);
});
