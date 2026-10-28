/**
 * 检查 GitHub Releases 的最新版本 —— 对应 Android 版 UpdateChecker.kt。
 *
 * 只请求 `/releases/latest` 一次，拿 tag 名、更新说明、HAP 下载地址和发布页地址；
 * 网络失败、GitHub 限流、HTTP 错误和响应无法解析分开返回，便于手动检查时给出准确提示。
 */

import { http } from '@kit.NetworkKit';
import { JsonObj, asArr, asObj, parseObj, s } from './JsonUtil';

/** 发布仓库：与 Android 版一致，指向自己的 Releases */
export const UPDATE_REPO: string = 'yhxi/ShiguangCinema-HarmonyOS';
const API_URL: string = `https://api.github.com/repos/${UPDATE_REPO}/releases/latest`;
const RELEASES_PAGE: string = `https://github.com/${UPDATE_REPO}/releases`;

export interface ReleaseInfo {
  tag: string;
  notes: string;
  /** 发布里第一个 .hap 的下载地址，没有则为空 */
  downloadUrl: string;
  releaseUrl: string;
}

export interface UpdateResult {
  ok: boolean;
  release?: ReleaseInfo;
  /** 失败时的中文说明，可直接展示 */
  message?: string;
  httpCode: number;
}

export function releasesPageUrl(): string {
  return RELEASES_PAGE;
}

function fail(message: string, code: number): UpdateResult {
  return { ok: false, message: message, httpCode: code };
}

/** 请求 GitHub Releases；永不抛异常，失败信息放在 message 里 */
export async function checkUpdate(): Promise<UpdateResult> {
  const client = http.createHttp();
  try {
    const resp = await client.request(API_URL, {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'ShiguangCinema-HarmonyOS',
        'Accept': 'application/vnd.github+json'
      },
      connectTimeout: 8000,
      readTimeout: 8000,
      usingCache: false,
      expectDataType: http.HttpDataType.STRING
    });
    const code = resp.responseCode;
    if (code !== 200) {
      if (code === 403 || code === 429) {
        return fail('GitHub 检查次数达到限制，请稍后再试', code);
      }
      if (code === 404) {
        return fail('发布仓库还没有发布版本', code);
      }
      return fail(`GitHub 暂时无法提供更新信息（HTTP ${code}）`, code);
    }
    const body: string = typeof resp.result === 'string' ? resp.result as string : '';
    if (body === '') {
      return fail('GitHub 返回的版本信息无法读取', code);
    }
    let root: JsonObj;
    try {
      root = parseObj(body);
    } catch (e) {
      return fail('GitHub 返回的版本信息无法读取', code);
    }
    const tag: string = s(root['tag_name']);
    if (tag === '') {
      return fail('GitHub 返回的版本信息无法读取', code);
    }
    const releaseUrl: string = s(root['html_url']);
    if (releaseUrl === '') {
      return fail('GitHub 返回的版本信息无法读取', code);
    }
    let downloadUrl: string = '';
    const assets = asArr(root['assets']);
    if (assets !== null) {
      for (const item of assets) {
        const asset = asObj(item);
        if (asset === null) { continue; }
        if (s(asset['name']).toLowerCase().endsWith('.hap')) {
          downloadUrl = s(asset['browser_download_url']);
          if (downloadUrl !== '') { break; }
        }
      }
    }
    const release: ReleaseInfo = {
      tag: tag,
      notes: s(root['body']),
      downloadUrl: downloadUrl,
      releaseUrl: releaseUrl
    };
    return { ok: true, release: release, httpCode: code };
  } catch (e) {
    return fail('网络连接失败，请检查网络后重试', 0);
  } finally {
    client.destroy();
  }
}

/** 远端形如 v1.0.0，本地形如 1.0.0；忽略 -beta / -rc 之类的预发布后缀 */
export function isNewerVersion(tag: string, current: string): boolean {
  if (tag === '') { return false; }
  const remote = parseVersion(tag);
  const local = parseVersion(current);
  const len = Math.max(remote.length, local.length);
  for (let i = 0; i < len; i++) {
    const a = i < remote.length ? remote[i] : 0;
    const b = i < local.length ? local[i] : 0;
    if (a !== b) { return a > b; }
  }
  return false;
}

function parseVersion(v: string): number[] {
  let text = v.trim();
  if (text.startsWith('v') || text.startsWith('V')) { text = text.substring(1); }
  const dash = text.indexOf('-');
  if (dash >= 0) { text = text.substring(0, dash); }
  const out: number[] = [];
  for (const part of text.split('.')) {
    const num = parseInt(part);
    if (!isNaN(num)) { out.push(num); }
  }
  return out;
}
