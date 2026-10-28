/**
 * LibreTV HTTP 契约（自 Android 版 Api.kt 移植，契约逐字段对齐）：
 *
 *   GET  /api/status            -> {passwordRequired, verified, version, defaultSources...}
 *   POST /api/auth {"password"} -> {"success":true} + Set-Cookie ltv_session
 *   POST /api/search {"wd","sources","filterAdult"}
 *                               -> {list:[...], failures:[]}
 *   GET  /api/detail?id&source  -> {episodes:[m3u8...], videoInfo:{...}}
 *   GET  /api/douban?type&tag&pageStart&pageSize -> {items:[{title,cover,rating}]}
 *
 * 会话 Cookie（ltv_session）手动捕获/回放，与 Android 版一致。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  AppStatus, Channel, Detail, DoubanItem, HttpError, SearchItem, SearchResult,
  SourceConfig, VideoInfo, sourceToJson
} from './Models';
import { JsonObj, asArr, asObj, getArr, getObj, parseObj, s, b, n } from './JsonUtil';

const CONNECT_TIMEOUT_MS = 15000;
const DEFAULT_READ_TIMEOUT_MS = 30000;
const SEARCH_READ_TIMEOUT_MS = 45000;
const DETAIL_READ_TIMEOUT_MS = 30000;

export class Api {
  readonly baseUrl: string;
  private cookie: string = '';

  constructor(baseUrl: string) {
    this.baseUrl = baseUrl.trim().replace(/\/+$/, '');
  }

  restoreCookie(value: string): void {
    this.cookie = value;
  }

  currentCookie(): string {
    return this.cookie;
  }

  /** 图片走站点代理：豆瓣封面有防盗链，直连 403 */
  imageUrl(picUrl: string): string {
    if (picUrl === '') {
      return '';
    }
    return `${this.baseUrl}/api/proxy?url=${encodeURIComponent(picUrl)}`;
  }

  private async request(
    path: string,
    method: string,
    body: string | null,
    readTimeoutMs: number
  ): Promise<string> {
    const client = http.createHttp();
    try {
      const header: Record<string, string> = { 'Accept': 'application/json' };
      if (this.cookie !== '') {
        header['Cookie'] = this.cookie;
      }
      if (body !== null) {
        header['Content-Type'] = 'application/json';
      }
      const options: http.HttpRequestOptions = {
        method: method === 'POST' ? http.RequestMethod.POST : http.RequestMethod.GET,
        header: header,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: readTimeoutMs,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== null) {
        options.extraData = body;
      }
      const resp = await client.request(this.baseUrl + path, options);
      // 抓 Set-Cookie（LibreTV 只发一条 ltv_session）
      const headers = resp.header as Record<string, Object>;
      if (headers !== undefined && headers !== null) {
        const setCookie = headers['set-cookie'] ?? headers['Set-Cookie'] ?? headers['SET-COOKIE'];
        if (typeof setCookie === 'string') {
          this.captureSessionCookie(setCookie as string);
        } else if (Array.isArray(setCookie) && (setCookie as Object[]).length > 0) {
          for (const item of setCookie as Object[]) {
            if (typeof item === 'string') {
              this.captureSessionCookie(item as string);
            }
          }
        }
      }
      // Some HarmonyOS versions expose Set-Cookie through cookies rather than header.
      if (resp.cookies) {
        this.captureSessionCookie(resp.cookies);
      }
      if (resp.responseCode < 200 || resp.responseCode > 299) {
        const errText = typeof resp.result === 'string' ? resp.result as string : '';
        throw new HttpError(resp.responseCode, errText);
      }
      if (typeof resp.result !== 'string') {
        throw new Error('响应不是文本');
      }
      return resp.result as string;
    } catch (e) {
      const err = e as BusinessError;
      const phase = path === '/api/status' ? '查询服务器状态' :
        (path === '/api/auth' ? '验证密码' : '请求服务器');
      hilog.error(0x0000, 'ShiguangCinema', '%{public}s failed, code=%{public}s, message=%{public}s',
        phase, String(err.code ?? ''), String(err.message ?? '未知错误'));
      if (err instanceof HttpError) {
        const httpError = err as HttpError;
        throw new HttpError(httpError.status, httpError.body);
      }
      throw new Error(`${phase}失败：${err.message ?? '未知错误'}${err.code ? `（${err.code}）` : ''}`);
    } finally {
      client.destroy();
    }
  }

  private captureSessionCookie(raw: string): void {
    const match = raw.match(/(?:^|[,;]\s*)(ltv_session=[^;,\s]+)/i);
    if (match !== null) {
      this.cookie = match[1];
    }
  }

  private async getText(path: string, readTimeoutMs: number = DEFAULT_READ_TIMEOUT_MS): Promise<string> {
    return this.request(path, 'GET', null, readTimeoutMs);
  }

  private async postJson(path: string, body: string, readTimeoutMs: number): Promise<string> {
    return this.request(path, 'POST', body, readTimeoutMs);
  }

  async status(): Promise<AppStatus> {
    const root = parseObj(await this.getText('/api/status'));
    const defaultSources: SourceConfig[] = [];
    const srcArr = getArr(root, 'defaultSources');
    if (srcArr !== null) {
      for (const item of srcArr) {
        const o = asObj(item);
        if (o === null) {
          continue;
        }
        const url = s(o['url']);
        if (url === '') {
          continue;
        }
        defaultSources.push({
          name: s(o['name'], url.split('//')[1] ?? url),
          url: url,
          detail: s(o['detail']),
          isAdult: b(o['isAdult']),
          enabled: b(o['enabled'], true)
        });
      }
    }
    const defaultLive: string[] = [];
    const liveArr = getArr(root, 'defaultLiveSources');
    if (liveArr !== null) {
      for (const item of liveArr) {
        if (typeof item === 'string' && (item as string) !== '') {
          defaultLive.push(item as string);
        } else {
          const o = asObj(item);
          if (o !== null && s(o['url']) !== '') {
            defaultLive.push(s(o['url']));
          }
        }
      }
    }
    const defaultSubs: string[] = [];
    const subsArr = getArr(root, 'defaultSubscriptions');
    if (subsArr !== null) {
      for (const item of subsArr) {
        if (typeof item === 'string' && (item as string) !== '') {
          defaultSubs.push(item as string);
        }
      }
    }
    return {
      passwordRequired: b(root['passwordRequired']),
      verified: b(root['verified']),
      version: s(root['version'], '?'),
      defaultSources: defaultSources,
      defaultLiveSources: defaultLive,
      defaultSubscriptions: defaultSubs
    };
  }

  /** 登录成功后复查 status.verified —— 会话没生效要明确报出来 */
  async login(password: string): Promise<AppStatus> {
    const payload: Record<string, Object> = { 'password': password };
    const text = await this.postJson('/api/auth', JSON.stringify(payload), DEFAULT_READ_TIMEOUT_MS);
    const root = parseObj(text);
    if (!b(root['success'])) {
      throw new HttpError(401, '密码错误');
    }
    return this.status();
  }

  async search(keyword: string, sources: SourceConfig[]): Promise<SearchResult> {
    const srcArr: Object[] = [];
    for (const src of sources) {
      const parsed: Object = JSON.parse(sourceToJson(src)) as Object;
      srcArr.push(parsed);
    }
    const payload: Record<string, Object> = {
      'wd': keyword,
      'sources': srcArr,
      'filterAdult': true
    };
    const text = await this.postJson('/api/search', JSON.stringify(payload), SEARCH_READ_TIMEOUT_MS);
    const root = parseObj(text);
    const items: SearchItem[] = [];
    const list = getArr(root, 'list');
    if (list !== null) {
      for (const item of list) {
        const o = asObj(item);
        if (o === null) {
          continue;
        }
        items.push({
          sourceName: s(o['sourceName']),
          vodId: s(o['vodId']),
          name: s(o['name']),
          pic: s(o['pic']),
          typeName: s(o['typeName']),
          year: s(o['year']),
          remarks: s(o['remarks']),
          sourceUrl: s(o['sourceUrl'])
        });
      }
    }
    let failures = 0;
    const failArr = getArr(root, 'failures');
    if (failArr !== null) {
      failures = failArr.length;
    }
    return { items: items, failures: failures };
  }

  async detail(vodId: string, source: SourceConfig): Promise<Detail> {
    const path = `/api/detail?id=${encodeURIComponent(vodId)}&source=${encodeURIComponent(sourceToJson(source))}`;
    const root = parseObj(await this.getText(path, DETAIL_READ_TIMEOUT_MS));
    if (root['error'] !== undefined) {
      throw new Error(s(root['error'], '获取详情失败'));
    }
    const urls: string[] = [];
    const eps = getArr(root, 'episodes');
    if (eps !== null) {
      for (const ep of eps) {
        if (typeof ep === 'string' && (ep as string) !== '') {
          urls.push(ep as string);
        }
      }
    }
    let info: VideoInfo = {
      title: '', cover: '', desc: '', remarks: '', year: '', area: '', actor: ''
    };
    const vi = getObj(root, 'videoInfo');
    if (vi !== null) {
      info = {
        title: s(vi['title']),
        cover: s(vi['cover']),
        desc: s(vi['desc']),
        remarks: s(vi['remarks']),
        year: s(vi['year']),
        area: s(vi['area']),
        actor: s(vi['actor'])
      };
    }
    return { episodes: urls, info: info };
  }

  async douban(type: string, tag: string, pageStart: number, pageSize: number): Promise<DoubanItem[]> {
    const path = `/api/douban?type=${encodeURIComponent(type)}&tag=${encodeURIComponent(tag)}` +
      `&pageStart=${pageStart}&pageSize=${pageSize}`;
    const root = parseObj(await this.getText(path));
    // 实测返回 {"items":[...]}；list/subjects 仅作兼容
    const arr = getArr(root, 'items') ?? getArr(root, 'list') ?? getArr(root, 'subjects');
    const out: DoubanItem[] = [];
    if (arr !== null) {
      for (const item of arr) {
        const o = asObj(item);
        if (o === null) {
          continue;
        }
        const title = s(o['title'], s(o['name']));
        if (title === '') {
          continue;
        }
        out.push({
          title: title,
          cover: s(o['cover'], s(o['pic'], s(o['img']))),
          rating: s(o['rating'], s(o['rate']))
        });
      }
    }
    return out;
  }

  /** 抓任意文本（源订阅等），不经过服务端 */
  static async fetchText(url: string, readTimeoutMs: number = 15000): Promise<string> {
    const client = http.createHttp();
    try {
      const resp = await client.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: readTimeoutMs,
        usingCache: false
      });
      if (resp.responseCode < 200 || resp.responseCode > 299) {
        throw new HttpError(resp.responseCode, '');
      }
      if (typeof resp.result !== 'string') {
        throw new Error('响应不是文本');
      }
      return resp.result as string;
    } finally {
      client.destroy();
    }
  }

  /**
   * 源测试：POST /api/source/test {"url"} -> {ok, count|status}
   * 与 Android 版一致，走服务端测（App 端网络环境不代表服务端可达性）。
   */
  async testSource(url: string): Promise<[boolean, number]> {
    const payload: Record<string, Object> = { 'url': url };
    const text = await this.postJson('/api/source/test', JSON.stringify(payload), DEFAULT_READ_TIMEOUT_MS);
    const root = parseObj(text);
    if (typeof root['ok'] !== 'boolean') {
      throw new Error('检测接口未返回有效结果');
    }
    const count = n(root['count'], n(root['status'], 0));
    return [b(root['ok']), count];
  }

  /** 订阅导入：GET /api/source-list?url= -> {sources:[...], liveSources:[...]} */
  async importSourceList(subscriptionUrl: string): Promise<SourceConfig[]> {
    const path = `/api/source-list?url=${encodeURIComponent(subscriptionUrl)}`;
    return parseSourceList(await this.getText(path, 20000));
  }

  /** 直播频道：GET /api/live/playlist?url= -> {channels:[{id,name,url,logo,group,tvgId}]} */
  async liveChannels(m3uUrl: string): Promise<Channel[]> {
    const path = `/api/live/playlist?url=${encodeURIComponent(m3uUrl)}`;
    const root = parseObj(await this.getText(path, 20000));
    const out: Channel[] = [];
    const arr = getArr(root, 'channels');
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
        name: s(o['name']),
        url: url,
        group: s(o['group'], '其他'),
        logo: s(o['logo'])
      });
    }
    return out;
  }
}

/**
 * 本地解析订阅文本。兼容三种格式（对齐 Android 版 parseSourceList）：
 *   1. 网页版导出（LibreTV-Settings_*.json）
 *   2. LibreTV-SourceList：{sources:[{name,url,...}]} 或纯数组
 *   3. TVBOX 配置：{sites:[{name/key,api,type}]}
 */
export function parseSourceList(text: string): SourceConfig[] {
  const fromExport = exportSources(text);
  if (fromExport !== null) {
    return fromExport;
  }
  let root: JsonObj | null = null;
  let arr: Object[] | null = null;
  try {
    root = parseObj(text);
    arr = getArr(root, 'sources');
  } catch (e) {
    try {
      const parsed: Object = JSON.parse(text) as Object;
      if (Array.isArray(parsed)) {
        arr = parsed as Object[];
      }
    } catch (e2) {
      return [];
    }
  }
  if (arr === null && root !== null) {
    arr = getArr(root, 'sites');
  }
  const out: SourceConfig[] = [];
  if (arr === null) {
    return out;
  }
  for (const item of arr) {
    const o = asObj(item);
    if (o === null) {
      continue;
    }
    if (o['api'] !== undefined) {
      // TVBOX 的 sites 用 api 字段，Spider 类型（type 非 0/1/空）跳过
      const type = s(o['type']);
      if (type !== '1' && type !== '0' && type !== '') {
        continue;
      }
      const url = s(o['api']);
      if (url === '') {
        continue;
      }
      out.push({
        name: s(o['name'], s(o['key'], url)),
        url: url,
        detail: '',
        isAdult: false,
        enabled: true
      });
    } else {
      const url = s(o['url']);
      if (url === '') {
        continue;
      }
      out.push({
        name: s(o['name'], url.split('//')[1] ?? url),
        url: url,
        detail: s(o['detail']),
        isAdult: b(o['isAdult']),
        enabled: b(o['enabled'], true)
      });
    }
  }
  return out;
}

/** 网页版导出文件里的直播源（M3U 订阅地址） */
export function parseLiveFromExport(text: string): string[] {
  const state = exportState(text);
  if (state === null) {
    return [];
  }
  const out: string[] = [];
  const seen = new Set<string>();
  const subs = getArr(state, 'liveSubscriptions');
  if (subs !== null) {
    for (const item of subs) {
      let u = '';
      if (typeof item === 'string') {
        u = item as string;
      } else {
        const o = asObj(item);
        if (o !== null) {
          u = s(o['url']);
        }
      }
      if (u !== '' && !seen.has(u)) {
        seen.add(u);
        out.push(u);
      }
    }
  }
  const sel = getArr(state, 'liveSelectedUrls');
  if (sel !== null) {
    for (const item of sel) {
      if (typeof item === 'string' && (item as string) !== '' && !seen.has(item as string)) {
        seen.add(item as string);
        out.push(item as string);
      }
    }
  }
  return out;
}

/**
 * 网页版「设置 → 导出」生成的文件（LibreTV-Settings_*.json）：
 *   { data: { "libretv-settings": "<JSON 字符串>", ... } }
 * 内层是 zustand 持久化结构，片源在 state.customAPIs，启用与顺序在 state.selectedKeys。
 */
function exportState(text: string): JsonObj | null {
  let root: JsonObj;
  try {
    root = parseObj(text);
  } catch (e) {
    return null;
  }
  const data = getObj(root, 'data');
  if (data === null) {
    return null;
  }
  const inner = s(data['libretv-settings']);
  if (inner === '') {
    return null;
  }
  try {
    const innerRoot = parseObj(inner);
    return getObj(innerRoot, 'state');
  } catch (e) {
    return null;
  }
}

function exportSources(text: string): SourceConfig[] | null {
  const state = exportState(text);
  if (state === null) {
    return null;
  }
  const apis = getArr(state, 'customAPIs');
  if (apis === null) {
    return [];
  }
  const byKey: Map<string, SourceConfig> = new Map();
  const order: string[] = [];
  for (const item of apis) {
    const o = asObj(item);
    if (o === null) {
      continue;
    }
    const url = s(o['url']);
    if (url === '') {
      continue;
    }
    const key = s(o['key'], url);
    const sc: SourceConfig = {
      name: s(o['name'], url.split('//')[1] ?? url),
      url: url,
      detail: s(o['detail']),
      isAdult: b(o['isAdult']),
      enabled: b(o['enabled'], true)
    };
    if (!byKey.has(key)) {
      order.push(key);
    }
    byKey.set(key, sc);
  }
  const selected = getArr(state, 'selectedKeys');
  if (selected === null || selected.length === 0) {
    const all: SourceConfig[] = [];
    for (const k of order) {
      const sc = byKey.get(k);
      if (sc !== undefined) {
        all.push(sc);
      }
    }
    return all;
  }
  const ordered: SourceConfig[] = [];
  for (const item of selected) {
    if (typeof item !== 'string') {
      continue;
    }
    const sc = byKey.get(item as string);
    if (sc !== undefined) {
      ordered.push(sc);
    }
  }
  // selectedKeys 里一个都对不上时，退回全部（宁多勿少，用户可在 App 里删）
  if (ordered.length === 0) {
    const all: SourceConfig[] = [];
    for (const k of order) {
      const sc = byKey.get(k);
      if (sc !== undefined) {
        all.push(sc);
      }
    }
    return all;
  }
  return ordered;
}

/** 内置 IPTV 播放单（对齐 Android 版 BuiltInLiveSources.kt） */
export const BUILT_IN_LIVE_SOURCES: string[] = [
  'https://gh-proxy.com/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u',
  'https://ghproxy.net/https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u'
];

export function liveSourceLabel(url: string): string {
  if (url === BUILT_IN_LIVE_SOURCES[0]) {
    return 'Guovin IPTV';
  }
  if (url === BUILT_IN_LIVE_SOURCES[1]) {
    return 'IPTV4 备用源';
  }
  return url;
}
