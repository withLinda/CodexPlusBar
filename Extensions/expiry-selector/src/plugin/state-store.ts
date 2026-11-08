import { mkdir, chmod, open, rename, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { randomUUID } from 'node:crypto';
import type { Cooldown, Mode } from '../shared/contracts.js';

export type HistoryEntry = { atMs: number; code: string; credentialID: string | null };
export type SelectorState = {
  schemaVersion: 1; policyVersion: 1; desiredMode: Mode; cooldowns: Record<string, Cooldown>;
  recentHistory: HistoryEntry[]; maintenanceRecovery: boolean; diagnostic?: 'persistence-unavailable';
};
export const initialState = (): SelectorState => ({ schemaVersion: 1, policyVersion: 1, desiredMode: 'paused', cooldowns: {}, recentHistory: [], maintenanceRecovery: false });
const object = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === 'object' && !Array.isArray(v);
const exact = (v: Record<string, unknown>, keys: string[]) => Object.keys(v).length === keys.length && keys.every(key => key in v);
const time = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;
function valid(v: unknown): v is SelectorState {
  if (!object(v) || !exact(v, ['schemaVersion', 'policyVersion', 'desiredMode', 'cooldowns', 'recentHistory', 'maintenanceRecovery']) ||
      v.schemaVersion !== 1 || v.policyVersion !== 1 || !['paused', 'auto'].includes(String(v.desiredMode)) || typeof v.maintenanceRecovery !== 'boolean' ||
      !object(v.cooldowns) || Object.keys(v.cooldowns).length > 4096 || !Array.isArray(v.recentHistory) || v.recentHistory.length > 100) return false;
  for (const [key, cooldown] of Object.entries(v.cooldowns)) {
    if (!/^[a-f0-9]{64}$/.test(key) || !object(cooldown) || !exact(cooldown, ['identityKey', 'failedAtMs', 'resetAtMs', 'reason', 'source']) ||
        cooldown.identityKey !== key || !time(cooldown.failedAtMs) || !time(cooldown.resetAtMs) || cooldown.resetAtMs <= cooldown.failedAtMs ||
        cooldown.resetAtMs - cooldown.failedAtMs > 31 * 86_400_000 || !['quota', 'long-rate-limit'].includes(String(cooldown.reason)) ||
        !['provider', 'usage', 'fallback'].includes(String(cooldown.source))) return false;
  }
  return v.recentHistory.every(entry => object(entry) && exact(entry, ['atMs', 'code', 'credentialID']) && time(entry.atMs) &&
    typeof entry.code === 'string' && /^[a-z][a-z-]{0,63}$/.test(entry.code) &&
    (entry.credentialID === null || (typeof entry.credentialID === 'string' && entry.credentialID.length > 0 && entry.credentialID.length <= 512)));
}

export class StateStore {
  constructor(private readonly directory = join(homedir(), '.codexplusbar-selector'), private readonly beforeRename = async () => {}) {}

  async loadState(): Promise<SelectorState> {
    let file;
    try {
      file = await open(join(this.directory, 'state.json'), 'r');
      const stat = await file.stat();
      if (!stat.isFile() || stat.size > 1_048_576) throw new Error('Invalid selector state');
      const buffer = Buffer.alloc(1_048_577);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesRead } = await file.read(buffer, offset, buffer.length - offset, null);
        if (!bytesRead) break;
        offset += bytesRead;
      }
      if (offset > 1_048_576) throw new Error('Invalid selector state');
      const state: unknown = JSON.parse(buffer.subarray(0, offset).toString('utf8'));
      if (!valid(state)) throw new Error('Invalid selector state');
      return state.maintenanceRecovery ? { ...state, desiredMode: 'paused' } : state;
    } catch (error) {
      return (error as NodeJS.ErrnoException).code === 'ENOENT' ? initialState() : { ...initialState(), diagnostic: 'persistence-unavailable' };
    } finally { await file?.close(); }
  }

  async saveState(state: SelectorState): Promise<void> {
    const bounded = { ...state, recentHistory: state.recentHistory.slice(-100) };
    if (!valid(bounded)) throw new Error('Invalid selector state');
    const data = JSON.stringify(bounded);
    if (Buffer.byteLength(data) > 1_048_576) throw new Error('Selector state too large');
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await chmod(this.directory, 0o700);
    const temporary = join(this.directory, `.state-${randomUUID()}.tmp`);
    let file;
    try {
      file = await open(temporary, 'wx', 0o600);
      await file.writeFile(data); await file.sync(); await file.close(); file = undefined;
      await this.beforeRename();
      await rename(temporary, join(this.directory, 'state.json'));
    } finally { await file?.close(); await unlink(temporary).catch(() => {}); }
  }
}
const defaultStore = new StateStore();
export const loadState = () => defaultStore.loadState();
export const saveState = (state: SelectorState) => defaultStore.saveState(state);
