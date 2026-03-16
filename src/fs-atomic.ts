/**
 * Atomic file-write helpers.
 *
 * Pattern: write to `{path}.tmp`, then rename.
 * Rename is atomic on POSIX, so readers never see a half-written file.
 */
import fs from 'fs';

/** Write arbitrary string content atomically. */
export function writeFileAtomic(filePath: string, content: string): void {
  const tmpPath = `${filePath}.tmp`;
  fs.writeFileSync(tmpPath, content);
  fs.renameSync(tmpPath, filePath);
}

/** Serialize `data` as pretty JSON and write atomically. */
export function writeJsonAtomic(filePath: string, data: unknown): void {
  writeFileAtomic(filePath, JSON.stringify(data, null, 2));
}
