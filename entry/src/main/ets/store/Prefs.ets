/**
 * 持久化 —— 对应 Android 版 Prefs.kt 的 MVP 子集：
 *   · 服务端地址 + 会话 Cookie（按服务端分别保存）
 *   · 片源列表（服务端下发 + 内置合并后的结果）
 *   · 观看历史（续播进度）
 * 全部以 JSON 存在用户首选项里。
 */

import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { AppStatus, DoubanItem, SourceConfig } from '../api/Models';
import { JsonObj, asArr, asObj, parseObj, s, b, n } from '../api/JsonUtil';

const STORE_NAME = 'shiguang_prefs';
const KEY_SERVER_URL = 'serverUrl';
const KEY_SERVERS = 'servers';          // 连接过的服务端地址列表
const KEY_COOKIES = 'cookies';          // { url: cookie }
const KEY_SOURCES = 'sources';          // { url: SourceConfig[] }
const KEY_HISTORY = 'history';          // WatchEntry[]
const KEY_FAVORITES = 'favorites';      // WatchEntry[]（追剧：只存元数据）
const KEY_LIVE = 'live';                // { serverUrl: {list: string[], selected: number} }

export interface WatchEntry {
  /** 唯一键：serverUrl|sourceUrl|vodId */
  key: string;
  serverUrl: string;
  sourceUrl: string;
  vodId: string;
  title: string;
  cover: string;
  episodeIndex: number;
  episodeCount: number;
  /** 毫秒 */
  positionMs: number;
  durationMs: number;
  updatedAt: number;
}

export interface PlaybackSettings {
  speedIndex: number;
  autoNext: boolean;
  cropVideo: boolean;
  seekStepSeconds: number;
  rememberProgress: boolean;
  resumeThresholdSeconds: number;
  backgroundPlayback: boolean;
}

export interface SkipMarks {
  introEndMs: number;
  outroStartMs: number;
  autoIntro: boolean;
  autoOutro: boolean;
}

/** 检查更新结果缓存 */
export interface UpdateState {
  /** 远端最新 tag，如 v1.0.1；空表示没有新版本 */
  tag: string;
  notes: string;
  downloadUrl: string;
  releaseUrl: string;
  /** 用户已经点开看过提示的 tag，用于决定首页胶囊要不要带小圆点 */
  seenTag: string;
  /** 上次检查时间（毫秒），用于 6 小时内不重复请求 */
  checkedAt: number;
}

export class Prefs {
  private static instance: Prefs | null = null;
  private store: preferences.Preferences | null = null;

  async getSkipMarks(title: string): Promise<SkipMarks> {
    const raw = s((this.store as preferences.Preferences).getSync(`skip:${title.trim().toLowerCase()}`, ''));
    if (raw === '') { return { introEndMs: 90000, outroStartMs: 0, autoIntro: false, autoOutro: false }; }
    const o = parseObj(raw);
    return { introEndMs: Math.max(0, n(o['introEndMs'], 90000)), outroStartMs: Math.max(0, n(o['outroStartMs'])),
      autoIntro: b(o['autoIntro']), autoOutro: b(o['autoOutro']) };
  }

  async setSkipMarks(title: string, marks: SkipMarks): Promise<void> {
    await (this.store as preferences.Preferences).put(`skip:${title.trim().toLowerCase()}`, JSON.stringify(marks));
    await (this.store as preferences.Preferences).flush();
  }

  async getPlaybackSettings(): Promise<PlaybackSettings> {
    const raw = s((this.store as preferences.Preferences).getSync('playbackSettings', ''));
    if (raw === '') { return { speedIndex: 1, autoNext: true, cropVideo: false, seekStepSeconds: 10,
      rememberProgress: true, resumeThresholdSeconds: 5, backgroundPlayback: false }; }
    const o = parseObj(raw);
    return { speedIndex: n(o['speedIndex'], 1), autoNext: b(o['autoNext'], true), cropVideo: b(o['cropVideo'], false),
      seekStepSeconds: Math.max(5, Math.min(60, n(o['seekStepSeconds'], 10))),
      rememberProgress: b(o['rememberProgress'], true),
      resumeThresholdSeconds: Math.max(0, Math.min(120, n(o['resumeThresholdSeconds'], 5))),
      backgroundPlayback: b(o['backgroundPlayback'], false) };
  }

  async setPlaybackSettings(settings: PlaybackSettings): Promise<void> {
    await (this.store as preferences.Preferences).put('playbackSettings', JSON.stringify(settings));
    await (this.store as preferences.Preferences).flush();
  }

  /** 检查更新留下的状态：已知新版本、更新说明、以及用户是否已看过提示 */
  async getUpdateState(): Promise<UpdateState> {
    const empty: UpdateState = {
      tag: '', notes: '', downloadUrl: '', releaseUrl: '', seenTag: '', checkedAt: 0
    };
    const raw = s((this.store as preferences.Preferences).getSync('updateState', ''));
    if (raw === '') { return empty; }
    let o: JsonObj;
    try {
      o = parseObj(raw);
    } catch (e) {
      return empty;
    }
    return {
      tag: s(o['tag']), notes: s(o['notes']), downloadUrl: s(o['downloadUrl']),
      releaseUrl: s(o['releaseUrl']), seenTag: s(o['seenTag']), checkedAt: n(o['checkedAt'])
    };
  }

  async setUpdateState(state: UpdateState): Promise<void> {
    await (this.store as preferences.Preferences).put('updateState', JSON.stringify(state));
    await (this.store as preferences.Preferences).flush();
  }

  static async get(ctx: Context): Promise<Prefs> {
    if (Prefs.instance !== null) {
      return Prefs.instance;
    }
    const p = new Prefs();
    p.store = await preferences.getPreferences(ctx, STORE_NAME);
    Prefs.instance = p;
    return p;
  }

  private async getMap(key: string): Promise<Map<string, string>> {
    const raw = s((this.store as preferences.Preferences).getSync(key, ''));
    const map = new Map<string, string>();
    if (raw === '') {
      return map;
    }
    const root = parseObj(raw);
    for (const k of Object.keys(root)) {
      map.set(k, s(root[k]));
    }
    return map;
  }

  private async putMap(key: string, map: Map<string, string>): Promise<void> {
    const obj: Record<string, Object> = {};
    map.forEach((v: string, k: string) => {
      obj[k] = v;
    });
    await (this.store as preferences.Preferences).put(key, JSON.stringify(obj));
    await (this.store as preferences.Preferences).flush();
  }

  async getServerUrl(): Promise<string> {
    return s((this.store as preferences.Preferences).getSync(KEY_SERVER_URL, ''));
  }

  async setServerUrl(url: string): Promise<void> {
    await (this.store as preferences.Preferences).put(KEY_SERVER_URL, url);
    await (this.store as preferences.Preferences).flush();
    if (url !== '') {
      const servers = await this.getMap(KEY_SERVERS);
      if (!servers.has(url)) {
        servers.set(url, '1');
        await this.putMap(KEY_SERVERS, servers);
      }
    }
  }

  async getServers(): Promise<string[]> {
    const map = await this.getMap(KEY_SERVERS);
    return Array.from(map.keys());
  }

  async getRecommendations(serverUrl: string, type: string): Promise<DoubanItem[]> {
    const map = await this.getMap('recommendations');
    const raw = map.get(`${serverUrl}|${type}`) ?? '';
    if (raw === '') { return []; }
    const arr = asArr(parseObj(raw)['items']);
    const result: DoubanItem[] = [];
    if (arr !== null) {
      for (const value of arr) {
        const item = asObj(value);
        if (item !== null && s(item['title']) !== '') {
          result.push({ title: s(item['title']), cover: s(item['cover']), rating: s(item['rating']) });
        }
      }
    }
    return result;
  }

  async setRecommendations(serverUrl: string, type: string, items: DoubanItem[]): Promise<void> {
    const map = await this.getMap('recommendations');
    const root: Record<string, Object> = { 'items': items as Object };
    map.set(`${serverUrl}|${type}`, JSON.stringify(root));
    await this.putMap('recommendations', map);
  }

  async getCookie(serverUrl: string): Promise<string> {
    const map = await this.getMap(KEY_COOKIES);
    return map.get(serverUrl) ?? '';
  }

  async setCookie(serverUrl: string, cookie: string): Promise<void> {
    const map = await this.getMap(KEY_COOKIES);
    map.set(serverUrl, cookie);
    await this.putMap(KEY_COOKIES, map);
  }

  /** 保存合并后的片源列表（按服务端分开） */
  async getSources(serverUrl: string): Promise<SourceConfig[]> {
    const map = await this.getMap(KEY_SOURCES);
    const raw = map.get(serverUrl) ?? '';
    if (raw === '') {
      return [];
    }
    const root = parseObj(raw);
    const out: SourceConfig[] = [];
    const arr = asArr(root['sources'] as Object);
    if (arr === null) {
      return out;
    }
    for (const item of arr) {
      const o = asObj(item);
      if (o === null) {
        continue;
      }
      const url = s(o['url']);
      if (url === '') {
        continue;
      }
      out.push({
        name: s(o['name'], url),
        url: url,
        detail: s(o['detail']),
        isAdult: b(o['isAdult']),
        enabled: b(o['enabled'], true)
      });
    }
    return out;
  }

  async setSources(serverUrl: string, sources: SourceConfig[]): Promise<void> {
    const map = await this.getMap(KEY_SOURCES);
    const arr: Object[] = [];
    for (const src of sources) {
      const o: Record<string, Object> = {
        'name': src.name, 'url': src.url, 'detail': src.detail,
        'isAdult': src.isAdult, 'enabled': src.enabled
      };
      arr.push(o as Object);
    }
    const root: Record<string, Object> = { 'sources': arr as Object };
    map.set(serverUrl, JSON.stringify(root));
    await this.putMap(KEY_SOURCES, map);
  }

  async getHistory(): Promise<WatchEntry[]> {
    const raw = s((this.store as preferences.Preferences).getSync(KEY_HISTORY, ''));
    if (raw === '') {
      return [];
    }
    const root = parseObj(raw);
    const out: WatchEntry[] = [];
    const arr = asArr(root['list'] as Object);
    if (arr === null) {
      return out;
    }
    for (const item of arr) {
      const o = asObj(item);
      if (o === null) {
        continue;
      }
      out.push({
        key: s(o['key']),
        serverUrl: s(o['serverUrl']),
        sourceUrl: s(o['sourceUrl']),
        vodId: s(o['vodId']),
        title: s(o['title']),
        cover: s(o['cover']),
        episodeIndex: n(o['episodeIndex']),
        episodeCount: n(o['episodeCount']),
        positionMs: n(o['positionMs']),
        durationMs: n(o['durationMs']),
        updatedAt: n(o['updatedAt'])
      });
    }
    out.sort((a: WatchEntry, c: WatchEntry) => c.updatedAt - a.updatedAt);
    return out;
  }

  async saveWatch(entry: WatchEntry): Promise<void> {
    const list = await this.getHistory();
    const idx = list.findIndex((e: WatchEntry) => e.key === entry.key);
    if (idx >= 0) {
      list.splice(idx, 1);
    }
    list.unshift(entry);
    // 只保留最近 100 条
    while (list.length > 100) {
      list.pop();
    }
    const arr: Object[] = [];
    for (const e of list) {
      const o: Record<string, Object> = {
        'key': e.key, 'serverUrl': e.serverUrl, 'sourceUrl': e.sourceUrl,
        'vodId': e.vodId, 'title': e.title, 'cover': e.cover,
        'episodeIndex': e.episodeIndex, 'episodeCount': e.episodeCount,
        'positionMs': e.positionMs, 'durationMs': e.durationMs, 'updatedAt': e.updatedAt
      };
      arr.push(o as Object);
    }
    const root: Record<string, Object> = { 'list': arr as Object };
    await (this.store as preferences.Preferences).put(KEY_HISTORY, JSON.stringify(root));
    await (this.store as preferences.Preferences).flush();
  }

  async clearHistory(): Promise<void> {
    await (this.store as preferences.Preferences).put(KEY_HISTORY, '');
    await (this.store as preferences.Preferences).flush();
  }

  async removeWatch(key: string): Promise<void> {
    const list = await this.getHistory();
    const filtered = list.filter((e: WatchEntry) => e.key !== key);
    await this.putEntryList(KEY_HISTORY, filtered);
  }

  // ---------- 追剧 / 收藏 ----------

  async getFavorites(): Promise<WatchEntry[]> {
    const raw = s((this.store as preferences.Preferences).getSync(KEY_FAVORITES, ''));
    if (raw === '') {
      return [];
    }
    const root = parseObj(raw);
    const out: WatchEntry[] = [];
    const arr = asArr(root['list'] as Object);
    if (arr === null) {
      return out;
    }
    for (const item of arr) {
      const o = asObj(item);
      if (o === null) {
        continue;
      }
      out.push({
        key: s(o['key']),
        serverUrl: s(o['serverUrl']),
        sourceUrl: s(o['sourceUrl']),
        vodId: s(o['vodId']),
        title: s(o['title']),
        cover: s(o['cover']),
        episodeIndex: n(o['episodeIndex']),
        episodeCount: n(o['episodeCount']),
        positionMs: n(o['positionMs']),
        durationMs: n(o['durationMs']),
        updatedAt: n(o['updatedAt'])
      });
    }
    out.sort((a: WatchEntry, c: WatchEntry) => c.updatedAt - a.updatedAt);
    return out;
  }

  async isFavorite(serverUrl: string, sourceUrl: string, vodId: string): Promise<boolean> {
    const key = watchKey(serverUrl, sourceUrl, vodId);
    const list = await this.getFavorites();
    return list.some((e: WatchEntry) => e.key === key);
  }

  async toggleFavorite(entry: WatchEntry): Promise<boolean> {
    const list = await this.getFavorites();
    const idx = list.findIndex((e: WatchEntry) => e.key === entry.key);
    if (idx >= 0) {
      list.splice(idx, 1);
      await this.putEntryList(KEY_FAVORITES, list);
      return false;
    }
    list.unshift(entry);
    await this.putEntryList(KEY_FAVORITES, list);
    return true;
  }

  private async putEntryList(key: string, list: WatchEntry[]): Promise<void> {
    const arr: Object[] = [];
    for (const e of list) {
      arr.push(entryToObj(e) as Object);
    }
    const root: Record<string, Object> = { 'list': arr as Object };
    await (this.store as preferences.Preferences).put(key, JSON.stringify(root));
    await (this.store as preferences.Preferences).flush();
  }

  // ---------- 直播源（按服务端分别保存） ----------

  async getLiveSources(serverUrl: string): Promise<string[]> {
    const map = await this.getMap(KEY_LIVE);
    const raw = map.get(serverUrl) ?? '';
    if (raw === '') {
      return [];
    }
    const root = parseObj(raw);
    const out: string[] = [];
    const arr = asArr(root['list'] as Object);
    if (arr !== null) {
      for (const item of arr) {
        if (typeof item === 'string' && (item as string) !== '') {
          out.push(item as string);
        }
      }
    }
    return out;
  }

  async getSelectedLiveIndex(serverUrl: string): Promise<number> {
    const map = await this.getMap(KEY_LIVE);
    const raw = map.get(serverUrl) ?? '';
    if (raw === '') {
      return 0;
    }
    const root = parseObj(raw);
    return n(root['selected'], 0);
  }

  async setLiveSources(serverUrl: string, list: string[], selected: number): Promise<void> {
    const map = await this.getMap(KEY_LIVE);
    const arr: Object[] = [];
    for (const u of list) {
      arr.push(u as Object);
    }
    const root: Record<string, Object> = { 'list': arr as Object, 'selected': selected };
    map.set(serverUrl, JSON.stringify(root));
    await this.putMap(KEY_LIVE, map);
  }
}

function entryToObj(e: WatchEntry): Record<string, Object> {
  return {
    'key': e.key, 'serverUrl': e.serverUrl, 'sourceUrl': e.sourceUrl,
    'vodId': e.vodId, 'title': e.title, 'cover': e.cover,
    'episodeIndex': e.episodeIndex, 'episodeCount': e.episodeCount,
    'positionMs': e.positionMs, 'durationMs': e.durationMs, 'updatedAt': e.updatedAt
  };
}

/** 保存状态到 WatchEntry 的便捷构造 */
export function watchKey(serverUrl: string, sourceUrl: string, vodId: string): string {
  return `${serverUrl}|${sourceUrl}|${vodId}`;
}

export function entryFromStatus(serverUrl: string, sourceUrl: string, vodId: string,
  title: string, cover: string, episodeIndex: number, episodeCount: number,
  positionMs: number, durationMs: number): WatchEntry {
  return {
    key: watchKey(serverUrl, sourceUrl, vodId),
    serverUrl: serverUrl,
    sourceUrl: sourceUrl,
    vodId: vodId,
    title: title,
    cover: cover,
    episodeIndex: episodeIndex,
    episodeCount: episodeCount,
    positionMs: positionMs,
    durationMs: durationMs,
    updatedAt: Date.now()
  };
}
