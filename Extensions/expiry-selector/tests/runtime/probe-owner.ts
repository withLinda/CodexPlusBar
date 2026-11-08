import { createServer } from 'node:http';

// Task 1 feasibility fixture, not the final selection coordinator. Its queue
// executes real location-scoped native calls; the listener is an OS-owned lease.
export async function createProbeOwner(port: number) {
  const epoch = crypto.randomUUID();
  const locations = new Set<string>();
  const events: string[] = [];
  let tail = Promise.resolve();
  let paused = false;
  let holds = 0;
  let activationGate = Promise.withResolvers<void>();
  let holdActivation = false;
  let activationWaiting = false;
  let ownsPort = false;
  const server = createServer((request, response) => {
    if (request.headers.authorization !== 'Bearer expiry-fixture-control') { response.writeHead(401).end(); return; }
    if (request.method === 'POST' && request.url === '/release') { holdActivation = false; activationGate.resolve(); }
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify(status()));
  });
  await new Promise<void>((resolve, reject) => {
    server.once('error', (error: NodeJS.ErrnoException) => error.code === 'EADDRINUSE' ? resolve() : reject(error));
    server.listen(port, '127.0.0.1', () => { ownsPort = true; resolve(); });
  });
  function status() { return { epoch, locations: locations.size, ownsPort, paused, holds, activationWaiting, events }; }
  function enqueue<T>(work: () => Promise<T>): Promise<T> {
    const result = tail.then(work);
    tail = result.then(() => undefined, () => undefined);
    return result;
  }
  return {
    epoch, locations, status,
    async activate(location: string, id: string, mutate: () => Promise<void>, allowed: () => Promise<boolean>) {
      return enqueue(async () => {
        if (!ownsPort || paused || !locations.has(location) || !await allowed()) return false;
        events.push(`start:${id}`);
        await mutate();
        if (holdActivation) { activationWaiting = true; await activationGate.promise; }
        // The gate delays delivery after native mutation has really completed.
        // Pause/unload must still await this unresolved operation's completion.
        events.push(`end:${id}`);
        return true;
      });
    },
    holdActivation() { holdActivation = true; activationWaiting = false; activationGate = Promise.withResolvers<void>(); },
    releaseActivation() { holdActivation = false; activationGate.resolve(); },
    beginMaintenance() { return enqueue(async () => { paused = true; holds++; events.push('pause'); }); },
    endMaintenance() { return enqueue(async () => { if (holds) holds--; }); },
    resume() { return enqueue(async () => { if (!holds) paused = false; return !paused; }); },
    async close() {
      await tail;
      if (ownsPort) await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      ownsPort = false;
    },
  };
}
