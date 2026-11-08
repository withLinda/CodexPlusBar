import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import type { SelectorCoordinator } from './coordinator.js';

export const controlPort = 53971;
export type RuntimeDescriptor = { protocolVersion: 1; pid: number; epoch: string; port: number; bearer: string };
const uuid = (v: unknown): v is string => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
const object = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);
const keys = (v: Record<string, unknown>, names: string[]) => Object.keys(v).length === names.length && names.every(key => key in v);
const authorized = (value: string | undefined, bearer: string) => {
  const expected = Buffer.from(`Bearer ${bearer}`), actual = Buffer.from(value ?? '');
  return actual.length === expected.length && timingSafeEqual(actual, expected);
};

export async function startControlServer(coordinator: SelectorCoordinator, descriptor: RuntimeDescriptor) {
  const reply = (response: ServerResponse, status: number, value: unknown) => {
    response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
    response.end(JSON.stringify({ protocolVersion: 1, epoch: descriptor.epoch, ...(value as object) }));
  };
  const body = async (request: IncomingMessage) => {
    if (request.headers['content-type'] !== 'application/json') throw new Error('content-type');
    const chunks: Buffer[] = []; let count = 0;
    for await (const chunk of request) {
      count += chunk.length;
      if (count > 65_536) throw new Error('too-large');
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;
  };
  const server = createServer({ maxHeaderSize: 8192, requestTimeout: 10_000, headersTimeout: 5000 }, (request, response) => {
    void (async () => {
      if (!authorized(request.headers.authorization, descriptor.bearer)) return reply(response, 401, { code: 'unauthorized', message: 'Control authorization required.' });
      if (request.headers['x-selector-epoch'] !== descriptor.epoch) return reply(response, 409, { code: 'epoch-mismatch', message: 'Selector ownership changed.' });
      if (request.headers.origin || request.headers['sec-fetch-site']) return reply(response, 403, { code: 'browser-origin', message: 'Local control client required.' });
      const path = request.url;
      if (path === '/v1/status' && request.method === 'GET') return reply(response, 200, coordinator.status());
      if (!['/v1/mode', '/v1/recheck', '/v1/maintenance/begin', '/v1/maintenance/end'].includes(path ?? '')) return reply(response, 404, { code: 'not-found', message: 'Unknown control route.' });
      if (request.method !== 'POST') return reply(response, 405, { code: 'method', message: 'POST required.' });
      let input: unknown;
      try { input = await body(request); }
      catch (error) { return reply(response, (error as Error).message === 'too-large' ? 413 : 400, { code: 'invalid-request', message: 'Invalid control request.' }); }
      if (!object(input) || !uuid(input.operationID)) return reply(response, 400, { code: 'invalid-request', message: 'Operation ID required.' });
      try {
        if (path === '/v1/mode' && keys(input, ['operationID', 'mode']) && (input.mode === 'paused' || input.mode === 'auto')) {
          const result = await coordinator.setMode(input.mode, input.operationID);
          reply(response, 200, result);
          if (input.mode === 'auto') void coordinator.recheck(`${input.operationID}:resume`).catch(() => {});
          return;
        }
        if (path === '/v1/recheck' && keys(input, ['operationID'])) {
          return reply(response, 200, await coordinator.recheck(input.operationID));
        }
        if (path === '/v1/maintenance/begin' && keys(input, ['operationID', 'reason']) &&
            ['manual-account-change', 'sign-in-repair'].includes(String(input.reason))) {
          return reply(response, 200, await coordinator.beginMaintenance(input.operationID, input.reason as string));
        }
        if (path === '/v1/maintenance/end' && keys(input, ['operationID', 'holdToken']) && uuid(input.holdToken)) {
          return reply(response, 200, await coordinator.endMaintenance(input.operationID, input.holdToken));
        }
      } catch {
        return reply(response, 409, { code: coordinator.status().blockedReason ?? 'control-conflict', message: 'Control operation could not be acknowledged.' });
      }
      return reply(response, 400, { code: 'invalid-request', message: 'Invalid control request.' });
    })().catch(() => { if (!response.headersSent) reply(response, 500, { code: 'control-unavailable', message: 'Local control unavailable.' }); });
  });
  server.keepAliveTimeout = 1000;
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(descriptor.port, '127.0.0.1', () => { server.removeListener('error', reject); resolve(); });
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('ownership-unavailable');
  descriptor.port = address.port;
  return { port: address.port, close: () => new Promise<void>((resolve, reject) => {
    server.close(error => error ? reject(error) : resolve()); server.closeIdleConnections();
  }) };
}
