/**
 * 全局会话状态单例 —— 当前服务端、Api 实例、合并后的片源。
 * 页面间通过 router 传参 + 本单例共享状态。
 */

import { Api } from '../api/Api';
import { DirectCms } from '../api/DirectCms';
import { AppStatus, SourceConfig, SearchItem, builtInSources } from '../api/Models';

interface SearchCacheEntry {
  items: SearchItem[];
  at: number;
}

/** 最近 20 个关键词的结果（对齐 Android 的 searchCache 上限） */
const SEARCH_CACHE_MAX = 20;

export class Session {
  private static instance: Session | null = null;

  /** 应用本次启动的时间（单例首次创建 ≈ 冷启动），内存监控页用它算运行时长 */
  readonly startedAt: number = Date.now();

  serverUrl: string = '';
  api: Api | null = null;
  appStatus: AppStatus | null = null;
  sources: SourceConfig[] = [];
  readonly directCms: DirectCms = new DirectCms();
  private connectionGeneration: number = 0;
  /** 键：serverUrl|keyword；换服务端不会串结果 */
  private searchCache: Map<string, SearchCacheEntry> = new Map();

  private searchCacheKey(keyword: string): string {
    return `${this.serverUrl}|${keyword.trim()}`;
  }

  /**
   * 记住一次搜索的结果。
   * 空结果不记：搜不到往往是片源临时抽风，记下来只会让下次进搜索页先铺一层空。
   */
  rememberSearch(keyword: string, items: SearchItem[]): void {
    if (items.length === 0) {
      return;
    }
    const key = this.searchCacheKey(keyword);
    this.searchCache.delete(key);
    this.searchCache.set(key, { items: items.slice(), at: Date.now() });
    if (this.searchCache.size > SEARCH_CACHE_MAX) {
      let oldestKey = '';
      let oldestAt = Number.MAX_SAFE_INTEGER;
      this.searchCache.forEach((entry: SearchCacheEntry, k: string) => {
        if (entry.at < oldestAt) {
          oldestAt = entry.at;
          oldestKey = k;
        }
      });
      if (oldestKey !== '') {
        this.searchCache.delete(oldestKey);
      }
    }
  }

  clearSearchCache(): void { this.searchCache.clear(); }

  forgetSearch(keyword: string): void { this.searchCache.delete(this.searchCacheKey(keyword)); }

  cachedSearch(keyword: string): SearchItem[] {
    const entry = this.searchCache.get(this.searchCacheKey(keyword));
    if (entry === undefined) { return []; }
    const enabled = new Set<string>(this.enabledSources().map((src: SourceConfig) => src.url));
    return entry.items.filter((item: SearchItem) => enabled.has(item.sourceUrl));
  }

  invalidateConnection(): void { this.connectionGeneration++; }

  static getInstance(): Session {
    if (Session.instance === null) {
      Session.instance = new Session();
    }
    return Session.instance;
  }

  isLogged(): boolean {
    return this.api !== null && this.appStatus !== null &&
      (!this.appStatus.passwordRequired || this.appStatus.verified);
  }

  restoreCached(baseUrl: string, cookie: string, sources: SourceConfig[], sourcesSaved: boolean = false): void {
    const api = new Api(baseUrl);
    api.restoreCookie(cookie);
    this.serverUrl = api.baseUrl;
    this.api = api;
    this.sources = sourcesSaved || sources.length > 0 ? sources : builtInSources();
  }

  /** 连接服务端：拉 status -> 必要时登录 -> 合并片源（服务端下发优先，内置兜底） */
  async connect(baseUrl: string, password: string, savedCookie: string, loginFirst: boolean = false): Promise<AppStatus> {
    const generation = ++this.connectionGeneration;
    const api = new Api(baseUrl);
    if (savedCookie !== '') {
      api.restoreCookie(savedCookie);
    }
    if (loginFirst && password !== '' && savedCookie === '') {
      const after = await api.login(password);
      if (after.passwordRequired && !after.verified) { throw new Error('登录成功但会话未生效，请重试'); }
      if (generation !== this.connectionGeneration) { throw new Error('CONNECTION_CANCELLED'); }
      this.serverUrl = api.baseUrl;
      this.api = api;
      this.appStatus = after;
      this.mergeSources(after.defaultSources);
      return after;
    }
    const status = await api.status();
    if (status.passwordRequired && !status.verified) {
      if (password === '') {
        throw new Error('NEED_PASSWORD');
      }
      const after = await api.login(password);
      if (!after.verified) {
        throw new Error('登录成功但会话未生效，请重试');
      }
      if (generation !== this.connectionGeneration) { throw new Error('CONNECTION_CANCELLED'); }
      this.serverUrl = api.baseUrl;
      this.api = api;
      this.appStatus = after;
      this.mergeSources(after.defaultSources);
      return after;
    }
    if (generation !== this.connectionGeneration) { throw new Error('CONNECTION_CANCELLED'); }
    this.serverUrl = api.baseUrl;
    this.api = api;
    this.appStatus = status;
    this.mergeSources(status.defaultSources);
    return status;
  }

  /** 服务端下发的源优先（去重），内置源补位 */
  private mergeSources(defaultSources: SourceConfig[]): void {
    const byUrl: Map<string, SourceConfig> = new Map();
    for (const src of defaultSources) {
      byUrl.set(src.url, src);
    }
    for (const src of builtInSources()) {
      if (!byUrl.has(src.url)) {
        byUrl.set(src.url, src);
      }
    }
    const list: SourceConfig[] = [];
    byUrl.forEach((v: SourceConfig) => {
      list.push(v);
    });
    this.sources = list;
  }

  /** 参与搜索的源：服务端源 + 启用的直连源；直连源在 DirectCms 失败时由服务端兜底 */
  enabledSources(): SourceConfig[] {
    return this.sources.filter((s: SourceConfig) => s.enabled);
  }
}
