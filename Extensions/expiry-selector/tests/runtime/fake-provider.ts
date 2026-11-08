import { createServer } from 'node:http';
import { fixtureAccount } from './fixtures.js';
import { WebSocketServer } from 'ws';

function terminalEvents(id: string) {
  const item = { type: 'message', id: `msg_${id}`, status: 'completed', role: 'assistant',
    content: [{ type: 'output_text', text: 'Fixture complete.', annotations: [] }] };
  const result = { id: `resp_${id}`, object: 'response', status: 'completed', output: [item],
    usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } };
  return [
    { type: 'response.created', response: { ...result, status: 'in_progress', output: [] } },
    { type: 'response.output_item.added', output_index: 0, item: { ...item, content: [] } },
    { type: 'response.content_part.added', item_id: item.id, output_index: 0, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } },
    { type: 'response.output_text.delta', item_id: item.id, output_index: 0, content_index: 0, delta: 'Fixture complete.' },
    { type: 'response.output_item.done', output_index: 0, item },
    { type: 'response.completed', response: result },
  ];
}

export async function fakeProvider() {
  const requests: { accountID: string; header: string | undefined; sessionID: string | undefined }[] = [];
  const websockets: { accountID: string; header: string | undefined; frames: { previous: boolean; inputs: number }[] }[] = [];
  const behaviors: (() => Promise<'quota' | 'ok'>)[] = [];
  const server = createServer(async (request, response) => {
    if (request.url === '/refuse') { response.writeHead(426).end(); return; }
    try {
      const accountID = fixtureAccount(request.headers.authorization);
      requests.push({ accountID, header: request.headers['chatgpt-account-id'] as string | undefined,
        sessionID: request.headers['x-opencode-session-id'] as string | undefined });
      // Drain only fixture payloads; never retain prompts or bodies.
      for await (const _ of request) { /* consume */ }
      if (await behaviors.shift()?.() === 'quota') {
        response.writeHead(429, { 'content-type': 'application/json' }).end(JSON.stringify({ error: { type: 'insufficient_quota', code: 'insufficient_quota', message: 'Fixture exhausted' } }));
        return;
      }
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      for (const event of terminalEvents(String(requests.length))) response.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
      response.end();
    } catch {
      response.writeHead(400).end('Invalid fixture request');
    }
  });
  const ws = new WebSocketServer({ noServer: true });
  server.on('upgrade', (request, socket, head) => {
    if (request.url === '/refuse') { socket.end('HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\n\r\n'); return; }
    try {
      const accountID = fixtureAccount(request.headers.authorization);
      const entry = { accountID, header: request.headers['chatgpt-account-id'] as string | undefined,
        frames: [] as { previous: boolean; inputs: number }[] };
      websockets.push(entry);
      ws.handleUpgrade(request, socket, head, connection => {
        connection.on('message', frame => {
          const value = JSON.parse(frame.toString());
          entry.frames.push({ previous: !!value.previous_response_id, inputs: value.input?.length ?? 0 });
          for (const event of terminalEvents(`ws_${websockets.length}_${entry.frames.length}`)) connection.send(JSON.stringify(event));
        });
      });
    } catch { socket.destroy(); }
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('No fixture listener');
  return { origin: `http://127.0.0.1:${address.port}`, requests, websockets, behaviors,
    close: () => new Promise<void>((resolve, reject) => { for (const client of ws.clients) client.terminate(); ws.close(); server.closeAllConnections(); server.close(e => e ? reject(e) : resolve()); }) };
}
