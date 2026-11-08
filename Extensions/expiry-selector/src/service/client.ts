import { constants } from 'node:fs';
import { lstat, open } from 'node:fs/promises';
import { request } from 'node:http';
import { homedir } from 'node:os';
import { join } from 'node:path';
import type { RuntimeDescriptor } from '../plugin/control-server.js';
import { publicStatus, type PublicStatus } from '../shared/status.js';

export const controlPort = 53971;
export type Route = 'status' | 'mode' | 'recheck';
const uuid = (v: unknown) => typeof v === 'string' && /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i.test(v);
export async function readDescriptor(directory = join(homedir(), '.codexplusbar-selector'), port = controlPort): Promise<RuntimeDescriptor> {
  let file;
  try {
    const parent = await lstat(directory);
    if (!parent.isDirectory() || parent.uid !== process.getuid?.() || (parent.mode & 0o777) !== 0o700) throw new Error('descriptor-invalid');
    file = await open(join(directory, 'runtime.json'), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const info = await file.stat(), after = await lstat(directory);
    if (!info.isFile() || info.uid !== process.getuid?.() || (info.mode & 0o777) !== 0o600 || info.size < 1 || info.size > 4096 ||
        parent.ino !== after.ino || parent.dev !== after.dev) throw new Error('descriptor-invalid');
    const bytes = Buffer.alloc(4097), { bytesRead } = await file.read(bytes, 0, bytes.length, 0);
    if (bytesRead > 4096) throw new Error('descriptor-invalid');
    const value = JSON.parse(bytes.subarray(0, bytesRead).toString('utf8'));
    if (!value || Object.keys(value).sort().join(',') !== 'bearer,epoch,pid,port,protocolVersion' || value.protocolVersion !== 1 ||
        !Number.isSafeInteger(value.pid) || value.pid <= 0 || !uuid(value.epoch) || value.port !== port ||
        typeof value.bearer !== 'string' || !/^[a-f0-9]{64}$/.test(value.bearer)) throw new Error('descriptor-invalid');
    return value;
  } catch (error) { throw new Error((error as NodeJS.ErrnoException).code === 'ENOENT' ? 'selector-unavailable' : 'descriptor-invalid'); }
  finally { await file?.close(); }
}

function send(descriptor: RuntimeDescriptor, path: Route, body?: Record<string, string>): Promise<{ status: number; value: any }> {
  return new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port: descriptor.port, path: `/v1/${path}`, method: body ? 'POST' : 'GET',
      agent: false, headers: { authorization: `Bearer ${descriptor.bearer}`, 'X-Selector-Epoch': descriptor.epoch, 'content-type': 'application/json' } }, response => {
      const chunks: Buffer[] = []; let size = 0;
      response.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > 1_048_576) { response.destroy(); reject(new Error('control-unavailable')); }
        else chunks.push(chunk);
      });
      response.on('error', () => reject(new Error('control-unavailable')));
      response.on('end', () => {
        try { resolve({ status: response.statusCode ?? 500, value: JSON.parse(Buffer.concat(chunks).toString('utf8')) }); }
        catch { reject(new Error('control-unavailable')); }
      });
    });
    req.setTimeout(45_000, () => req.destroy());
    req.on('error', () => reject(new Error('control-unavailable')));
    req.end(body ? JSON.stringify(body) : undefined);
  });
}

export class SelectorClient {
  constructor(private readonly options: { directory?: string; port?: number } = {}) {}
  async call(path: Route, body?: Record<string, string>): Promise<PublicStatus> {
    let descriptor = await readDescriptor(this.options.directory, this.options.port);
    for (let attempt = 0; attempt < 2; attempt++) {
      let result;
      try { result = await send(descriptor, path, body); }
      catch {
        if (attempt) throw new Error('control-unavailable');
        const next = await readDescriptor(this.options.directory, this.options.port);
        if (body && (next.epoch !== descriptor.epoch || next.bearer !== descriptor.bearer)) throw new Error('ownership-changed');
        descriptor = next; continue;
      }
      if (result.status === 401 || result.status === 409 || result.value?.epoch !== descriptor.epoch) {
        const next = await readDescriptor(this.options.directory, this.options.port);
        if (body && next.epoch !== descriptor.epoch) throw new Error('ownership-changed');
        if (!attempt) { descriptor = next; continue; }
        throw new Error('control-conflict');
      }
      if (result.status !== 200 || result.value?.protocolVersion !== 1) throw new Error('control-unavailable');
      return publicStatus(result.value);
    }
    throw new Error('control-unavailable');
  }
}
