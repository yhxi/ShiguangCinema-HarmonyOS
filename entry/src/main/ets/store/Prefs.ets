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
const KEY_SEARCH_HISTORY = 'searchHistory'; // string[] 最近搜索词
const MAX_SEARCH_HISTORY = 12;

export interface WatchEntry {
  /** 唯一键：serverUrl|sourceUrl|vodId */
  key: string;
  serverUrl: string;
  sourceUrl: string;
  vodId: string;
  title: string;
  cover: string;
  episodeIndex: number;
  episodeLabel?: string;
  episodeCount: number;
  /** 毫秒 */
  positionMs: number;
  durationMs: number;
  updatedAt: number;
}

/** 同一服务端中，片名完全一致的不同来源合并显示。 */
function sameHistoryTitle(a: WatchEntry, b: WatchEntry): boolean {
  const title = a.title.trim().toLowerCase();
  return title !== '' && title === b.title.trim().toLowerCase() && a.serverUrl === b.serverUrl;
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
  /**
   * v1.5.2 起，片尾标记改记「距结束还有多少毫秒」，而不是绝对位置。
   * 这样同一部剧里时长不同的剧集也能落到真正一致的片尾点。
   * 旧标记这两个字段是 0，走 legacyStart 兼容路径。
   */
  outroRemainingMs: number;
  /** 记标记时那一集的总时长，用来判断后续剧集是否差异过大（>max(30s, 25%)）就不再自动跳 */
  outroReferenceMs: number;
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

const VIEWING_BACKUP_FORMAT = 'shiguang-harmonyos-viewing-backup';

interface BackupMark {
  title: string;
  marks: SkipMarks;
}

export class Prefs {
  private static instance: Prefs | null = null;
  private store: preferences.Preferences | null = null;

  async recordCrash(err: Error): Promise<void> {
    // Do not persist messages, URLs, credentials or raw stacks from external data.
    const name = (err.name ?? 'Error').replace(/[^A-Za-z0-9_.-]/g, '').slice(0, 80);
    const lines = (err.stack ?? '').split('\n').filter((line: string) =>
      line.includes('entry/src/main/ets/')).map((line: string) => {
      const match = line.match(/entry\/src\/main\/ets\/[A-Za-z0-9_./-]+(?::[0-9]+){0,2}/);
      return match === null ? '' : match[0];
    }).filter((line: string) => line !== '').slice(0, 20);
    const text = `${new Date().toISOString()}\n${name}\n${lines.join('\n')}`;
    await (this.store as preferences.Preferences).put('lastCrash', text);
    await (this.store as preferences.Preferences).flush();
  }

  async getCrashLog(): Promise<string> {
    return s((this.store as preferences.Preferences).getSync('lastCrash', ''));
  }

  async getSkipMarks(title: string): Promise<SkipMarks> {
    const raw = s((this.store as preferences.Preferences).getSync(`skip:${title.trim().toLowerCase()}`, ''));
    if (raw === '') {
      return { introEndMs: 90000, outroStartMs: 0, autoIntro: false, autoOutro: false,
        outroRemainingMs: 0, outroReferenceMs: 0 };
    }
    const o = parseObj(raw);
    return { introEndMs: Math.max(0, n(o['introEndMs'], 90000)), outroStartMs: Math.max(0, n(o['outroStartMs'])),
      autoIntro: b(o['autoIntro']), autoOutro: b(o['autoOutro']),
      outroRemainingMs: Math.max(0, n(o['outroRemainingMs'])), outroReferenceMs: Math.max(0, n(o['outroReferenceMs'])) };
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

  /** Distinguish an explicitly saved empty list from a server without saved sources. */
  async hasSources(serverUrl: string): Promise<boolean> {
    return (await this.getMap(KEY_SOURCES)).has(serverUrl);
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

  private historyCache: WatchEntry[] | null = null;
  private historyWrites: Promise<void> = Promise.resolve();

  private enqueueHistory(work: () => Promise<void>): Promise<void> {
    const next = this.historyWrites.catch(() => {}).then(work);
    this.historyWrites = next.catch(() => {});
    return next;
  }

  /** 从磁盘解析历史并写入缓存；调用方不要改动返回的数组 */
  private async loadHistoryFromDisk(): Promise<WatchEntry[]> {
    const raw = s((this.store as preferences.Preferences).getSync(KEY_HISTORY, ''));
    const out: WatchEntry[] = [];
    if (raw !== '') {
      const root = parseObj(raw);
      const arr = asArr(root['list'] as Object);
      if (arr !== null) {
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
            episodeLabel: s(o['episodeLabel']),
            episodeCount: n(o['episodeCount']),
            positionMs: n(o['positionMs']),
            durationMs: n(o['durationMs']),
            updatedAt: n(o['updatedAt'])
          });
        }
      }
    }
    out.sort((a: WatchEntry, c: WatchEntry) => c.updatedAt - a.updatedAt);
    this.historyCache = out;
    return out;
  }

  async getHistory(): Promise<WatchEntry[]> {
    await this.historyWrites;
    // 播放中每 5 秒就会保存一次进度，历史必须常驻内存，
    // 否则每次保存都要全量解析 + 全量序列化 100 条
    if (this.historyCache === null) {
      await this.loadHistoryFromDisk();
    }
    const result: WatchEntry[] = [];
    for (const entry of this.historyCache as WatchEntry[]) {
      if (!result.some((other: WatchEntry) => other.key === entry.key || sameHistoryTitle(other, entry))) {
        result.push(entry);
      }
    }
    return result;
  }

  async saveWatch(entry: WatchEntry): Promise<void> {
    return this.enqueueHistory(() => this.saveWatchNow(entry));
  }

  private async saveWatchNow(entry: WatchEntry): Promise<void> {
    if (this.historyCache === null) {
      await this.loadHistoryFromDisk();
    }
    const list = this.historyCache as WatchEntry[];
    const idx = list.findIndex((e: WatchEntry) => e.key === entry.key);
    if (idx >= 0) {
      if (entry.cover.trim() === '') { entry.cover = list[idx].cover; }
      list.splice(idx, 1);
    }
    list.unshift(entry);
    // 只保留最近 100 条
    while (list.length > 100) {
      list.pop();
    }
    await this.putEntryList(KEY_HISTORY, list);
  }

  async updateWatchCover(key: string, previous: string, cover: string): Promise<void> {
    return this.enqueueHistory(async () => {
      if (this.historyCache === null) { await this.loadHistoryFromDisk(); }
      const list = this.historyCache as WatchEntry[];
      const entry = list.find((item: WatchEntry) => item.key === key);
      if (entry === undefined || entry.cover !== previous || cover === '' || cover === previous) { return; }
      entry.cover = cover;
      await this.putEntryList(KEY_HISTORY, list);
    });
  }

  async clearHistory(): Promise<void> {
    return this.enqueueHistory(() => this.clearHistoryNow());
  }

  private async clearHistoryNow(): Promise<void> {
    this.historyCache = [];
    await (this.store as preferences.Preferences).put(KEY_HISTORY, '');
    await (this.store as preferences.Preferences).flush();
  }

  async removeWatch(key: string): Promise<void> {
    return this.enqueueHistory(() => this.removeWatchNow(key));
  }

  private async removeWatchNow(key: string): Promise<void> {
    if (this.historyCache === null) {
      await this.loadHistoryFromDisk();
    }
    const target = (this.historyCache as WatchEntry[]).find((e: WatchEntry) => e.key === key);
    const list = (this.historyCache as WatchEntry[]).filter((e: WatchEntry) =>
      e.key !== key && (target === undefined || !sameHistoryTitle(e, target)));
    this.historyCache = list;
    await this.putEntryList(KEY_HISTORY, list);
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
        episodeLabel: s(o['episodeLabel']),
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

  private backupAddressContainsCredentials(url: string): boolean {
    return /^(?:https?:)?\/\/[^/?#]*@/i.test(url) ||
      /[?&](?:password|passwd|pwd|token|access_token|auth|authorization|cookie|session|key)=/i.test(url);
  }

  async exportViewingBackup(server: string, sources: SourceConfig[]): Promise<string> {
    if (this.backupAddressContainsCredentials(server)) { throw new Error('服务端地址含登录信息，无法导出'); }
    const canExport = (entry: WatchEntry): boolean => entry.serverUrl === server &&
      !this.backupAddressContainsCredentials(entry.sourceUrl);
    const snapshot = (entry: WatchEntry): Record<string, Object> => {
      const row = entryToObj(entry);
      if (this.backupAddressContainsCredentials(entry.cover)) { row['cover'] = ''; }
      return row;
    };
    const history = (await this.getHistory()).filter(canExport).map(snapshot);
    const favorites = (await this.getFavorites()).filter(canExport).map(snapshot);
    const exportedSources = sources
      .filter((source: SourceConfig) => !this.backupAddressContainsCredentials(source.url))
      .map((source: SourceConfig): SourceConfig => ({
        name: source.name, url: source.url, detail: this.backupAddressContainsCredentials(source.detail) ? '' : source.detail,
        isAdult: source.isAdult, enabled: source.enabled
      }));
    const raw = await (this.store as preferences.Preferences).getAll() as Record<string, Object>;
    const marks: BackupMark[] = [];
    for (const key of Object.keys(raw)) {
      if (key.startsWith('skip:') && key.length > 5) {
        marks.push({ title: key.substring(5), marks: await this.getSkipMarks(key.substring(5)) });
      }
    }
    return JSON.stringify({
      format: VIEWING_BACKUP_FORMAT, version: 1, server: server,
      history: history, favorites: favorites, sources: exportedSources, marks: marks
    });
  }

  async restoreViewingBackup(text: string, server: string, currentSources: SourceConfig[]): Promise<SourceConfig[]> {
    const root = asObj(JSON.parse(text) as Object);
    if (root === null || root['format'] !== VIEWING_BACKUP_FORMAT || root['version'] !== 1) {
      throw new Error('文件不是时光影院鸿蒙版的观看备份');
    }
    if (root['server'] !== server) { throw new Error('请先连接备份所对应的服务端'); }
    const history = this.parseBackupEntries(root['history'], server);
    const favorites = this.parseBackupEntries(root['favorites'], server);
    const sourceRows = asArr(root['sources']);
    const markRows = asArr(root['marks']);
    if (sourceRows === null || markRows === null || sourceRows.length > 1000 || markRows.length > 4000) {
      throw new Error('备份项目缺失或超出容量');
    }
    const sources = new Map<string, SourceConfig>();
    for (const current of currentSources) { sources.set(current.url, current); }
    for (const value of sourceRows) {
      const row = asObj(value);
      if (row === null || !/^https?:\/\//i.test(s(row['url'])) ||
        typeof row['enabled'] !== 'boolean' || typeof row['isAdult'] !== 'boolean') {
        throw new Error('备份片源格式错误');
      }
      const url = s(row['url']);
      sources.set(url, { name: s(row['name'], url), url: url, detail: s(row['detail']),
        enabled: b(row['enabled']), isAdult: b(row['isAdult']) });
    }
    const marks: BackupMark[] = [];
    for (const value of markRows) {
      const row = asObj(value);
      const mark = row === null ? null : asObj(row['marks']);
      const title = row === null ? '' : s(row['title']).trim().toLowerCase();
      if (title === '' || mark === null || typeof mark['autoIntro'] !== 'boolean' ||
        typeof mark['autoOutro'] !== 'boolean') { throw new Error('备份跳过标记格式错误'); }
      const positions = ['introEndMs', 'outroStartMs', 'outroRemainingMs', 'outroReferenceMs'];
      for (const name of positions) {
        if (typeof mark[name] !== 'number' || !Number.isFinite(n(mark[name])) || n(mark[name]) < 0) {
          throw new Error('备份跳过时间无效');
        }
      }
      marks.push({ title: title, marks: { introEndMs: n(mark['introEndMs']), outroStartMs: n(mark['outroStartMs']),
        autoIntro: b(mark['autoIntro']), autoOutro: b(mark['autoOutro']),
        outroRemainingMs: n(mark['outroRemainingMs']), outroReferenceMs: n(mark['outroReferenceMs']) } });
    }
    const mergedSources = Array.from(sources.values());
    await this.enqueueHistory(async () => {
      if (this.historyCache === null) { await this.loadHistoryFromDisk(); }
      const mergedHistory = this.mergeBackupEntries(this.historyCache as WatchEntry[], history).slice(0, 100);
      await this.putEntryList(KEY_HISTORY, mergedHistory);
      this.historyCache = mergedHistory;
      const mergedFavorites = this.mergeBackupEntries(await this.getFavorites(), favorites);
      await this.putEntryList(KEY_FAVORITES, mergedFavorites);
      await this.setSources(server, mergedSources);
      const store = this.store as preferences.Preferences;
      for (const item of marks) {
        const key = 'skip:' + item.title;
        if (this.getRaw(key, '') === '') { await store.put(key, JSON.stringify(item.marks)); }
      }
      await store.flush();
    });
    return mergedSources;
  }

  private parseBackupEntries(value: Object | undefined, server: string): WatchEntry[] {
    const rows = asArr(value);
    if (rows === null || rows.length > 4000) { throw new Error('备份记录格式错误'); }
    const out: WatchEntry[] = [];
    for (const value of rows) {
      const row = asObj(value);
      if (row === null || row['serverUrl'] !== server || s(row['vodId']) === '' || s(row['title']) === '' ||
        !/^https?:\/\//i.test(s(row['sourceUrl']))) { throw new Error('备份观看记录格式错误'); }
      const numbers = ['episodeIndex', 'episodeCount', 'positionMs', 'durationMs', 'updatedAt'];
      for (const name of numbers) {
        if (typeof row[name] !== 'number' || !Number.isFinite(n(row[name])) || n(row[name]) < 0) {
          throw new Error('备份观看进度无效');
        }
      }
      if (!Number.isSafeInteger(n(row['episodeIndex'])) || !Number.isSafeInteger(n(row['episodeCount']))) {
        throw new Error('备份集数无效');
      }
      const source = s(row['sourceUrl']);
      const vodId = s(row['vodId']);
      out.push({ key: watchKey(server, source, vodId), serverUrl: server, sourceUrl: source, vodId: vodId,
        title: s(row['title']), cover: s(row['cover']), episodeIndex: n(row['episodeIndex']),
        episodeLabel: s(row['episodeLabel']), episodeCount: n(row['episodeCount']), positionMs: n(row['positionMs']),
        durationMs: n(row['durationMs']), updatedAt: n(row['updatedAt']) });
    }
    return out;
  }

  private mergeBackupEntries(current: WatchEntry[], imported: WatchEntry[]): WatchEntry[] {
    const entries = new Map<string, WatchEntry>();
    for (const entry of current) { entries.set(entry.key, entry); }
    for (const entry of imported) {
      const prior = entries.get(entry.key);
      if (prior === undefined || entry.updatedAt > prior.updatedAt) { entries.set(entry.key, entry); }
    }
    return Array.from(entries.values()).sort((a: WatchEntry, b: WatchEntry) => b.updatedAt - a.updatedAt);
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

  // ---------- 通用键值（儿童额度、直播本地频道等模块共用） ----------

  /** 读原始字符串。模块自己的小状态不必都在这类里加一个方法。 */
  getRaw(key: string, def: string): string {
    return s((this.store as preferences.Preferences).getSync(key, def));
  }

  async putRaw(key: string, value: string): Promise<void> {
    await (this.store as preferences.Preferences).put(key, value);
    await (this.store as preferences.Preferences).flush();
  }

  /** 读字符串数组（JSON 数组）；解析失败一律当空 */
  getStringList(key: string): string[] {
    const raw = s((this.store as preferences.Preferences).getSync(key, ''));
    if (raw === '') {
      return [];
    }
    let arr: Object[] | null = null;
    try {
      arr = asArr(JSON.parse(raw) as Object);
    } catch (e) {
      return [];
    }
    const out: string[] = [];
    if (arr !== null) {
      for (const item of arr) {
        if (typeof item === 'string' && (item as string).trim() !== '') {
          out.push(item as string);
        }
      }
    }
    return out;
  }

  async putStringList(key: string, list: string[]): Promise<void> {
    await this.putRaw(key, JSON.stringify(list));
  }

  // ---------- 搜索历史（v1.5.5 补齐：对齐 Android 的 addSearchHistory） ----------

  /** 最近搜索关键词，最新的在前，最多 12 条 */
  getSearchHistory(): string[] {
    return this.getStringList(KEY_SEARCH_HISTORY);
  }

  async addSearchHistory(keyword: string): Promise<void> {
    const value: string = keyword.trim();
    if (value === '') {
      return;
    }
    const out: string[] = [value];
    for (const item of this.getSearchHistory()) {
      // 同一个词再搜一次就挪到最前面，而不是留两条
      if (item !== value && out.length < MAX_SEARCH_HISTORY) {
        out.push(item);
      }
    }
    await this.putStringList(KEY_SEARCH_HISTORY, out);
  }

  async removeSearchHistory(keyword: string): Promise<void> {
    const out: string[] = [];
    for (const item of this.getSearchHistory()) {
      if (item !== keyword) {
        out.push(item);
      }
    }
    await this.putStringList(KEY_SEARCH_HISTORY, out);
  }

  async clearSearchHistory(): Promise<void> {
    await this.putStringList(KEY_SEARCH_HISTORY, []);
  }
}

function entryToObj(e: WatchEntry): Record<string, Object> {
  return {
    'key': e.key, 'serverUrl': e.serverUrl, 'sourceUrl': e.sourceUrl,
    'vodId': e.vodId, 'title': e.title, 'cover': e.cover,
    'episodeIndex': e.episodeIndex, 'episodeLabel': e.episodeLabel ?? '', 'episodeCount': e.episodeCount,
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
