import { readFile, mkdir, writeFile, copyFile } from 'node:fs/promises';
import { resolve, dirname, join } from 'node:path';
import { createHash } from 'node:crypto';

// Read-only extraction of the installed host for isolated lifecycle tests.
// Never load these modules in the user's application process or write its store.
const archivePath = '/Applications/OpenChamber.app/Contents/Resources/app.asar';
const archive = await readFile(archivePath);
const checksum = createHash('sha256').update(archive).digest('hex');
const root = resolve('.runtime/host');
try { if (await readFile(join(root, '.checksum'), 'utf8') === checksum) process.exit(0); } catch {}
const header = JSON.parse(archive.subarray(16, 16 + archive.readUInt32LE(12)).toString());
const base = 8 + archive.readUInt32LE(4);
async function extract(node, path = '') {
  for (const [name, entry] of Object.entries(node.files ?? {})) {
    const relative = path ? `${path}/${name}` : name;
    const destination = resolve(root, relative);
    if (!destination.startsWith(root + '/')) throw new Error('Invalid archive path');
    if (entry.files) { await mkdir(destination, { recursive: true }); await extract(entry, relative); continue; }
    if (entry.link) throw new Error('Unexpected archive link');
    await mkdir(dirname(destination), { recursive: true });
    if (entry.unpacked) await copyFile(`${archivePath}.unpacked/${relative}`, destination);
    else await writeFile(destination, archive.subarray(base + Number(entry.offset), base + Number(entry.offset) + entry.size));
  }
}
await extract(header);
await writeFile(join(root, '.checksum'), checksum);
console.log(`Extracted isolated OpenChamber host: sha256 ${checksum}`);
