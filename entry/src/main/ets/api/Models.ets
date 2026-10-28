/**
 * 数据模型 —— 与 Android 版 Api.kt 的 HTTP 契约一一对应。
 */

export interface SourceConfig {
  name: string;
  url: string;
  detail: string;
  isAdult: boolean;
  enabled: boolean;
}

export interface SearchItem {
  sourceName: string;
  vodId: string;
  name: string;
  pic: string;
  typeName: string;
  year: string;
  remarks: string;
  sourceUrl: string;
}

export interface VideoInfo {
  title: string;
  cover: string;
  desc: string;
  remarks: string;
  year: string;
  area: string;
  actor: string;
}

export interface Detail {
  episodes: string[];
  info: VideoInfo;
}

export interface DoubanItem {
  title: string;
  cover: string;
  rating: string;
}

export interface Channel {
  name: string;
  url: string;
  group: string;
  logo: string;
}

export interface AppStatus {
  passwordRequired: boolean;
  verified: boolean;
  version: string;
  defaultSources: SourceConfig[];
  defaultLiveSources: string[];
  defaultSubscriptions: string[];
}

export interface SearchResult {
  items: SearchItem[];
  failures: number;
}

export class HttpError extends Error {
  readonly status: number;
  readonly body: string;

  constructor(status: number, body: string) {
    super(`HTTP ${status}`);
    this.status = status;
    this.body = body;
  }
}

export function makeSource(name: string, url: string): SourceConfig {
  const s: SourceConfig = { name: name, url: url, detail: '', isAdult: false, enabled: true };
  return s;
}

/** sourceConfig -> 服务端需要的 JSON 字符串 */
export function sourceToJson(src: SourceConfig): string {
  const o: Record<string, Object> = {
    'name': src.name,
    'url': src.url,
    'enabled': src.enabled,
    'isAdult': src.isAdult
  };
  if (src.detail !== '') {
    o['detail'] = src.detail;
  }
  return JSON.stringify(o);
}

/** Android 版 BuiltInSources.kt 固化的 2026-10-23 实测源清单 */
export function builtInSources(): SourceConfig[] {
  const list: SourceConfig[] = [
    makeSource('虎牙', 'https://www.huyaapi.com/api.php/provide/vod/from/hym3u8'),
    makeSource('火狐', 'https://hhzyapi.com/api.php/provide/vod'),
    makeSource('暴风', 'https://bfzyapi.com/api.php/provide/vod'),
    makeSource('量子', 'https://cj.lziapi.com/api.php/provide/vod'),
    makeSource('如意', 'https://cj.rycjapi.com/api.php/provide/vod'),
    makeSource('360采集', 'https://360zy.com/api.php/provide/vod'),
    makeSource('百度', 'https://api.apibdzy.com/api.php/provide/vod'),
    makeSource('尤酷', 'https://api.ukuapi.com/api.php/provide/vod'),
    makeSource('淘片', 'https://taopianapi.com/cjapi/mc/vod/json.html'),
    makeSource('极速', 'https://jszyapi.com/api.php/provide/vod'),
    makeSource('电影天堂', 'http://caiji.dyttzyapi.com/api.php/provide/vod'),
    makeSource('天涯', 'http://tyyszy.com/api.php/provide/vod'),
    makeSource('非凡(ffzy)', 'http://ffzy.tv/api.php/provide/vod'),
    makeSource('非凡(ffzy1)', 'http://ffzy1.tv/api.php/provide/vod'),
    makeSource('非凡(ffzy5)', 'http://ffzy5.tv/api.php/provide/vod')
  ];
  return list;
}
