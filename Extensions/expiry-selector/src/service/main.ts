import { startService, serviceEnvironment } from './server.js';

try {
  const service = await startService(serviceEnvironment(process.env));
  for (const signal of ['SIGTERM', 'SIGINT'] as const) process.once(signal, () => { void service.close().then(() => process.exit(0)); });
} catch { console.error('Account Priority service could not start: verify its host environment and loopback port.'); process.exitCode = 1; }
