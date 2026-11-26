import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export interface UpdatePackage {
  tag: string;
  url: string;
  size: number;
  digest: string;
}

export interface DownloadOutcome {
  ok: boolean;
  path: string;
  message?: string;
}

const ACTIVE_DOWNLOADS = new Map<string, Promise<DownloadOutcome>>();
const PACKAGE_NAME = /^ShiguangCinema-HarmonyOS-[vV]?\d+(?:\.\d+){1,5}(?:[-+][A-Za-z0-9.-]+)?-unsigned\.hap(?:\.part)?$/;

function packagePath(context: common.UIAbilityContext, info: UpdatePackage): string {
  const name = `ShiguangCinema-HarmonyOS-${info.tag}-unsigned.hap`;
  return PACKAGE_NAME.test(name) && !name.endsWith('.part') ? `${context.filesDir}/update/${name}` : '';
}

async function isValidPackage(path: string, info: UpdatePackage): Promise<boolean> {
  try {
    const stat = await fs.stat(path);
    if (stat.size < 22 || (info.size > 0 && stat.size !== info.size)) { return false; }
    const file = await fs.open(path, fs.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(64 * 1024);
      let offset = 0;
      let count = await fs.read(file.fd, buffer);
      const bytes = new Uint8Array(buffer);
      if (count < 4 || bytes[0] !== 0x50 || bytes[1] !== 0x4b || bytes[2] !== 3 || bytes[3] !== 4) { return false; }
      if (!/^sha256:[0-9a-f]{64}$/.test(info.digest)) {
        // Older release metadata may omit a digest. Check the ZIP end record as well.
        const tail = new ArrayBuffer(Math.min(stat.size, 22 + 65535));
        fs.lseek(file.fd, stat.size - tail.byteLength, fs.WhenceType.SEEK_SET);
        const length = await fs.read(file.fd, tail);
        const end = new Uint8Array(tail);
        for (let i = length - 22; i >= 0; i--) {
          if (end[i] === 0x50 && end[i + 1] === 0x4b && end[i + 2] === 5 && end[i + 3] === 6 &&
            i + 22 + end[i + 20] + end[i + 21] * 256 === length) { return true; }
        }
        return false;
      }
      const hash = cryptoFramework.createMd('SHA256');
      while (count > 0) {
        await hash.update({ data: new Uint8Array(buffer, 0, count) });
        offset += count;
        if (offset >= stat.size) { break; }
        count = await fs.read(file.fd, buffer);
      }
      if (offset !== stat.size) { return false; }
      const actual = (await hash.digest()).data;
      let hex = '';
      for (const value of actual) { hex += value.toString(16).padStart(2, '0'); }
      return info.digest === 'sha256:' + hex;
    } finally { await fs.close(file); }
  } catch (e) { return false; }
}

export async function findDownloadedUpdate(context: common.UIAbilityContext, info: UpdatePackage): Promise<string> {
  const path = packagePath(context, info);
  return path !== '' && await isValidPackage(path, info) ? path : '';
}

async function downloadToPart(context: common.UIAbilityContext, url: string, path: string,
  onProgress: (pct: number) => void): Promise<void> {
  const task = await request.downloadFile(context, { url: url, filePath: path, enableMetered: true, background: false });
  await new Promise<void>((resolve, reject) => {
    task.on('progress', (received: number, total: number) => {
      if (total > 0) { onProgress(Math.min(99, Math.round(received / total * 100))); }
    });
    task.on('complete', () => { resolve(); });
    task.on('fail', (code: number) => { reject(new Error(`下载失败（错误码 ${code}）`)); });
  });
}

async function downloadAndCache(context: common.UIAbilityContext, info: UpdatePackage, path: string,
  onProgress: (pct: number) => void): Promise<DownloadOutcome> {
  const dir = `${context.filesDir}/update`;
  const part = path + '.part';
  try {
    if (await isValidPackage(path, info)) { return { ok: true, path: path }; }
    if (!(await fs.access(dir).catch(() => false))) { await fs.mkdir(dir, true); }
    await fs.unlink(part).catch(() => {});
    await downloadToPart(context, info.url, part, onProgress);
    if (!(await isValidPackage(part, info))) { throw new Error('安装包校验失败，请重试'); }
    await fs.unlink(path).catch(() => {});
    await fs.rename(part, path);
    const names = await fs.listFile(dir).catch((): string[] => []);
    for (const name of names) {
      if (!PACKAGE_NAME.test(name)) { continue; }
      const old = `${dir}/${name}`;
      const owner = old.endsWith('.part') ? old.slice(0, -5) : old;
      if (old !== path && !ACTIVE_DOWNLOADS.has(owner)) { await fs.unlink(old).catch(() => {}); }
    }
    onProgress(100);
    return { ok: true, path: path };
  } catch (e) {
    await fs.unlink(part).catch(() => {});
    return { ok: false, path: '', message: (e as Error).message };
  }
}

export async function downloadUpdateFile(context: common.UIAbilityContext, info: UpdatePackage,
  onProgress: (pct: number) => void): Promise<DownloadOutcome> {
  const path = packagePath(context, info);
  if (path === '' || !info.url.startsWith('https://')) {
    return { ok: false, path: '', message: '没有有效的安装包下载地址' };
  }
  const existing = ACTIVE_DOWNLOADS.get(path);
  if (existing !== undefined) { return existing; }
  const job = downloadAndCache(context, info, path, onProgress);
  ACTIVE_DOWNLOADS.set(path, job);
  try { return await job; }
  finally { ACTIVE_DOWNLOADS.delete(path); }
}
