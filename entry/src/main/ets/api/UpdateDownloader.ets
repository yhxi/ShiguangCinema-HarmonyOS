/**
 * 应用内下载更新包。
 *
 * 保存到应用沙箱 `filesDir/update/`，通过 `request.downloadFile` 下载，
 * 用 on('progress') 上报百分比；完成后由调用方决定怎么打开。
 * 注意：沙箱文件其他应用默认读不到，"打开"时要用 fileUri + 读权限标记。
 */

import { common } from '@kit.AbilityKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export interface DownloadOutcome {
  ok: boolean;
  /** 下载完成的沙箱绝对路径 */
  path: string;
  /** 失败时的中文说明 */
  message?: string;
}

function ensureDir(dir: string): void {
  try {
    if (!fs.accessSync(dir)) { fs.mkdirSync(dir, true); }
  } catch (e) {
    try { fs.mkdirSync(dir, true); } catch (e2) { /* 目录建不出来时下载会自己报错 */ }
  }
}

export async function downloadUpdateFile(context: common.UIAbilityContext, url: string,
  fileName: string, onProgress: (pct: number) => void): Promise<DownloadOutcome> {
  const dir = `${context.filesDir}/update`;
  ensureDir(dir);
  const filePath = `${dir}/${fileName}`;
  try {
    if (fs.accessSync(filePath)) { fs.unlinkSync(filePath); }
  } catch (e) { /* 文件不存在是常态 */ }
  try {
    const config: request.DownloadConfig = {
      url: url,
      filePath: filePath,
      enableMetered: true,
      background: false
    };
    const task: request.DownloadTask = await request.downloadFile(context, config);
    return await new Promise<DownloadOutcome>((resolve) => {
      task.on('progress', (received: number, total: number) => {
        if (total > 0) { onProgress(Math.min(100, Math.round(received / total * 100))); }
      });
      task.on('complete', () => {
        onProgress(100);
        resolve({ ok: true, path: filePath });
      });
      task.on('fail', (err: number) => {
        resolve({ ok: false, path: '', message: `下载失败（错误码 ${err}）` });
      });
    });
  } catch (e) {
    return { ok: false, path: '', message: `下载失败：${(e as Error).message}` };
  }
}
