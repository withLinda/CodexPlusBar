import { randomBytes, randomUUID } from 'node:crypto';
import { mkdir, chmod, open, rename, readFile, unlink } from 'node:fs/promises';
import { watch, type FSWatcher } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { SelectorCoordinator, type CoordinatorDependencies, type NativeAccess } from './coordinator.js';
import { startControlServer, controlPort, type RuntimeDescriptor } from './control-server.js';
import { StateStore } from './state-store.js';
import { SnapshotReader } from '../shared/snapshot-reader.js';

export const implementationVersion = 'expiry-selector-v1.0';
const globalKey = Symbol.for('codexplusbar.expiry-selector.v1');
type Shared = { version: string; ready: Promise<Owner>; closing: Promise<void> | undefined };
type Owner = { coordinator: SelectorCoordinator; locations: Map<string, { refs: number; detach(): Promise<void>; resources: Promise<() => Promise<void>>; closing?: Promise<void> }>; close(): Promise<void> };
const globals = globalThis as typeof globalThis & { [key: symbol]: Shared | undefined };
export type OwnershipOptions = {
  directory?: string; port?: number; key?: symbol; version?: string; snapshotPath?: string;
  dependencies?: Omit<CoordinatorDependencies, 'owns'>;
  setupLocation?: (coordinator: SelectorCoordinator) => Promise<() => Promise<void>>;
};

async function createOwner(options: OwnershipOptions): Promise<Owner> {
  const directory = options.directory ?? join(homedir(), '.codexplusbar-selector');
  const snapshotPath = options.snapshotPath ?? join(homedir(), 'Library/Application Support/CodexPlusBar/Exports/openchamber-selector-v1.json');
  const store = new StateStore(directory), reader = new SnapshotReader(snapshotPath);
  let owns = false;
  const coordinator = new SelectorCoordinator({ ...(options.dependencies ?? { now: Date.now,
    readSnapshot: now => reader.readSnapshot(now), loadState: () => store.loadState(), saveState: state => store.saveState(state) }), owns: () => owns });
  await coordinator.initialize();
  const descriptor: RuntimeDescriptor = { protocolVersion: 1, pid: process.pid, epoch: randomUUID(), port: options.port ?? controlPort, bearer: randomBytes(32).toString('hex') };
  let server: Awaited<ReturnType<typeof startControlServer>> | undefined;
  let tick: ReturnType<typeof setInterval> | undefined, debounce: ReturnType<typeof setTimeout> | undefined, watcher: FSWatcher | undefined;
  const file = join(directory, 'runtime.json');
  const locations: Owner['locations'] = new Map();
  try {
    server = await startControlServer(coordinator, descriptor);
    await mkdir(directory, { recursive: true, mode: 0o700 }); await chmod(directory, 0o700);
    const temporary = join(directory, `.runtime-${descriptor.epoch}.tmp`);
    try {
      const handle = await open(temporary, 'wx', 0o600);
      try { await handle.writeFile(JSON.stringify(descriptor)); await handle.sync(); } finally { await handle.close(); }
      await rename(temporary, file);
    } finally { await unlink(temporary).catch(() => {}); }
    owns = true;
    const schedule = () => {
      if (debounce) clearTimeout(debounce);
      debounce = setTimeout(() => { void coordinator.requestSelection('snapshot'); }, 250); debounce.unref();
    };
    try { watcher = watch(dirname(snapshotPath), schedule); watcher.on('error', () => { watcher?.close(); watcher = undefined; }); watcher.unref(); } catch { /* Timer rereads when export directory appears. */ }
    tick = setInterval(() => { void coordinator.requestSelection('tick'); }, 15_000); tick.unref();
  } catch {
    await server?.close(); server = undefined;
    coordinator.invalidate('ownership-unavailable');
  }
  return { coordinator, locations, async close() {
    if (tick) clearInterval(tick); if (debounce) clearTimeout(debounce); watcher?.close();
    await coordinator.close();
    // Keep the socket until dispatched activation has settled and descriptor removal is done.
    if (owns) {
      try { const current = JSON.parse(await readFile(file, 'utf8')); if (current.epoch === descriptor.epoch) await unlink(file); } catch { /* A successor's descriptor is never removed. */ }
    }
    owns = false; await server?.close();
  } };
}

export async function acquireOwnership(adapter: NativeAccess, options: OwnershipOptions = {}) {
  const key = options.key ?? globalKey, version = options.version ?? implementationVersion;
  let shared = globals[key];
  if (shared && shared.version !== version) throw new Error('incompatible-implementation');
  if (shared?.closing) { await shared.closing; shared = globals[key]; }
  if (!shared) { shared = { version, ready: createOwner(options), closing: undefined }; globals[key] = shared; }
  const entry = shared;
  let owner: Owner;
  try { owner = await entry.ready; } catch (error) { if (globals[key] === entry) delete globals[key]; throw error; }
  if (entry.closing) { await entry.closing; return acquireOwnership(adapter, options); }
  // Repeated delivery of the same location gets one coordinator adapter and one hook owner.
  const existing = owner.locations.get(adapter.locationKey);
  if (existing?.closing) { await existing.closing; return acquireOwnership(adapter, options); }
  const location: NonNullable<typeof existing> = existing ?? { refs: 0, detach: owner.coordinator.attach(adapter),
    resources: options.setupLocation?.(owner.coordinator) ?? Promise.resolve(async () => {}) };
  location.refs++;
  owner.locations.set(adapter.locationKey, location);
  let detached = false;
  const lease = { coordinator: owner.coordinator, firstForLocation: !existing, async detach() {
    if (detached) return; detached = true;
    if (--location.refs > 0) return;
    const drain = location.detach();
    location.closing = (async () => {
      try { const dispose = await location.resources; await dispose(); } finally { await drain; owner.locations.delete(adapter.locationKey); }
    })();
    if ([...owner.locations.values()].every(value => value.refs === 0)) {
      entry.closing = (async () => {
        await Promise.allSettled([...owner.locations.values()].map(value => value.closing));
        await owner.close(); if (globals[key] === entry) delete globals[key];
      })();
      await entry.closing;
    } else await location.closing;
  } };
  try { await location.resources; return lease; }
  catch (error) { await lease.detach(); throw error; }
}
