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
  /** 播放时需要的请求头，序列化成 "K: V\nK: V"；空串表示没有（v1.3.17 起支持 EXTVLCOPT） */
  headers?: string;
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

/** Android 版 BuiltInSources.kt 固化的 2026-11-11 实测源清单（21 个，顺序与 Android 一致） */
export function builtInSources(): SourceConfig[] {
  const list: SourceConfig[] = [
    // ---- 已验证可播（https，支持客户端直连）----
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
    // ---- 2026-11-09 新增：搜索、详情及 HLS 清单已验证 ----
    makeSource('厂长', 'https://api.changzhang.tv/api.php/provide/vod/'),
    makeSource('红牛', 'https://www.hongniuzy2.com/api.php/provide/vod'),
    makeSource('金鹰', 'https://jinyingzy.com/api.php/provide/vod'),
    makeSource('猫眼', 'https://api.maoyanapi.top/api.php/provide/vod'),
    // ---- 2026-11-11：HTTPS 搜索、详情及 HLS 清单已验证 ----
    makeSource('非凡 HTTPS', 'https://api.ffzyapi.com/api.php/provide/vod/'),
    // ---- 待验证（http，走服务端代理）----
    makeSource('电影天堂', 'http://caiji.dyttzyapi.com/api.php/provide/vod'),
    makeSource('天涯', 'http://tyyszy.com/api.php/provide/vod'),
    makeSource('非凡(ffzy)', 'http://ffzy.tv/api.php/provide/vod'),
    makeSource('建安', 'http://154.219.117.232:9981/jacloudapi.php/provide/vod'),
    makeSource('非凡(ffzy1)', 'http://ffzy1.tv/api.php/provide/vod'),
    makeSource('非凡(ffzy5)', 'http://ffzy5.tv/api.php/provide/vod')
  ];
  return list;
}

/**
 * 给已有配置补入新增的内置源（对齐 Android supplementBuiltInSources / supplementFeifanSource）：
 * 只有配置里本来就含旧内置源时才补，纯自定义配置不动；按 URL 去重，保留原顺序与禁用状态。
 */
export function supplementBuiltInSources(current: SourceConfig[]): SourceConfig[] {
  const additions: SourceConfig[] = [];
  for (const src of builtInSources()) {
    if (src.name === '厂长' || src.name === '红牛' || src.name === '金鹰' ||
      src.name === '猫眼' || src.name === '非凡 HTTPS' || src.name === '建安') {
      additions.push(src);
    }
  }
  const priorUrls: Set<string> = new Set();
  for (const src of builtInSources()) {
    if (additions.some((a: SourceConfig) => a.url === src.url)) {
      continue;
    }
    priorUrls.add(src.url.replace(/\/+$/, ''));
  }
  const seen: Set<string> = new Set();
  for (const src of current) {
    seen.add(src.url.replace(/\/+$/, ''));
  }
  let isBuiltInConfig = false;
  for (const url of seen) {
    if (priorUrls.has(url)) {
      isBuiltInConfig = true;
      break;
    }
  }
  if (!isBuiltInConfig) {
    return current;
  }
  const out: SourceConfig[] = current.slice();
  for (const add of additions) {
    const key = add.url.replace(/\/+$/, '');
    if (!seen.has(key)) {
      seen.add(key);
      out.push(add);
    }
  }
  return out;
}
