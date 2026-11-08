import { createServer } from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { SelectorClient, type Route } from './client.js';

export function serviceEnvironment(env: NodeJS.ProcessEnv) {
  const port = Number(env.OPENCHAMBER_SERVICE_PORT), token = env.OPENCHAMBER_SERVICE_TOKEN;
  if (!/^\d+$/.test(env.OPENCHAMBER_SERVICE_PORT ?? '') || !Number.isSafeInteger(port) || port < 1 || port > 65535 || !token || token.length > 4096) throw new Error('Service environment missing or invalid.');
  return { port, token };
}
export async function startService({ port, token, client = new SelectorClient() }: { port: number; token: string; client?: SelectorClient }) {
  const server = createServer({ maxHeaderSize: 8192, requestTimeout: 10_000, headersTimeout: 5000 }, (request, response) => {
    const reply = (status: number, body: unknown) => {
      response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' });
      response.end(JSON.stringify(body));
    };
    void (async () => {
      const expected = Buffer.from(`Bearer ${token}`), received = Buffer.from(request.headers.authorization ?? '');
      if (received.length !== expected.length || !timingSafeEqual(received, expected)) return reply(401, { code: 'unauthorized' });
      if (request.headers.origin || request.headers['sec-fetch-site']) return reply(403, { code: 'browser-origin' });
      if (request.url === '/health' && request.method === 'GET') return reply(200, { ready: true });
      const routes: Record<string, Route> = { '/v1/status': 'status', '/v1/mode': 'mode', '/v1/recheck': 'recheck' };
      const path = routes[request.url ?? ''];
      if (!path) return reply(404, { code: 'not-found' });
      if (request.method !== (path === 'status' ? 'GET' : 'POST')) return reply(405, { code: 'method' });
      let body: Record<string, string> | undefined;
      if (path !== 'status') {
        if (request.headers['content-type'] !== 'application/json') return reply(400, { code: 'invalid-request' });
        const chunks: Buffer[] = []; let size = 0;
        for await (const chunk of request) { size += chunk.length; if (size > 65_536) return reply(413, { code: 'too-large' }); chunks.push(chunk); }
        try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { return reply(400, { code: 'invalid-request' }); }
        if (!body || typeof body.operationID !== 'string' || !/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(body.operationID) ||
            Object.keys(body).sort().join(',') !== (path === 'mode' ? 'mode,operationID' : 'operationID') ||
            (path === 'mode' && !['auto', 'paused'].includes(body.mode!))) return reply(400, { code: 'invalid-request' });
      }
      try { reply(200, await client.call(path, body)); }
      catch (error) {
        const allowed = ['selector-unavailable', 'descriptor-invalid', 'control-unavailable', 'control-conflict', 'ownership-changed'];
        const code = error instanceof Error && allowed.includes(error.message) ? error.message : 'control-unavailable';
        if (code === 'control-conflict') {
          try { return reply(409, { code, status: await client.call('status') }); } catch { /* An unverified refusal stays unconfirmed. */ }
        }
        reply(503, { code });
      }
    })().catch(() => { if (!response.headersSent) reply(503, { code: 'control-unavailable' }); });
  });
  await new Promise<void>((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', () => { server.removeListener('error', reject); resolve(); }); });
  return { port: (server.address() as { port: number }).port,
    close: () => new Promise<void>(resolve => { server.close(() => resolve()); server.closeIdleConnections(); }) };
}
