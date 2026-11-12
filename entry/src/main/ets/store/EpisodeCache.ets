/**
 * 整季选集列表的本地缓存（对齐 Android 版 EpisodeCache.kt）。
 *
 * 为什么需要：像《海贼王》这种上千集的剧，从历史记录进来时播放页只拿到一个播放地址，
 * 要选集就得先把服务端搜一遍、再查详情，动辄十几秒；而这个列表一天里几乎不变
 * （变了就是更新几集）。缓存下来之后，第二次进详情页可以直接铺出选集。
 *
 * 键：服务端 + 片源地址 + vodId —— 必须带片源地址：同名剧在不同采集站的集数与地址
 * 完全不同，混用会串剧。
 *
 * 失效条件（任一命中就重新拉取，绝不拿旧数据硬套）：
 *   · 超过 7 天
 *   · 当前正在播的地址不在缓存列表里（片源换线路了）
 *   · 缓存自身首末集与列表不一致（数据损坏）
 * 网络刷新成功时详情页会替换缓存；离线时旧地址可能失效。
 *
 * 为什么落文件而不是 preferences：一季上千条 URL，40 部就是数 MB，
 * preferences 的字符串值撑不住这个量级。
 */

import { fileIo as fs } from '@kit.CoreFileKit';
import { Context } from '@kit.AbilityKit';

export interface EpisodeRecord {
  /** 每集播放地址 */
  urls: string[];
  /** 写入时间 */
  ts: number;
  /** 首集地址：整季换版本时用来识别 */
  first: string;
  /** 末集地址 */
  last: string;
}

/** 7 天。采集站换地址一般也就这个节奏 */
export const EPISODE_CACHE_TTL_MS: number = 7 * 24 * 60 * 60 * 1000;
/** 最多留 40 部，超了按最旧的淘汰 */
export const EPISODE_CACHE_MAX: number = 40;

export function episodeCacheKey(server: string, sourceUrl: string, vodId: string): string {
  return `${server.replace(/\/+$/, '')}|${sourceUrl.replace(/\/+$/, '')}|${vodId}`;
}

/** 记录是否还能用；currentUrl 非空时还要求当前地址仍在列表里 */
export function episodeRecordUsable(record: EpisodeRecord | undefined, currentUrl: string, now: number): boolean {
  if (record === undefined || record.urls.length <= 1) {
    return false;
  }
  if (now - record.ts >= EPISODE_CACHE_TTL_MS) {
    return false;
  }
  if (record.first !== record.urls[0] || record.last !== record.urls[record.urls.length - 1]) {
    return false;
  }
  if (currentUrl !== '' && record.urls.indexOf(currentUrl) < 0) {
    return false;
  }
  return true;
}

/** 先砍过期，再按写入时间砍到上限以内（就地修改） */
export function pruneEpisodeRecords(records: Map<string, EpisodeRecord>, now: number): void {
  const alive: string[] = [];
  const dead: string[] = [];
  records.forEach((record: EpisodeRecord, key: string) => {
    if (now - record.ts >= EPISODE_CACHE_TTL_MS) {
      dead.push(key);
    } else {
      alive.push(key);
    }
  });
  for (const key of dead) {
    records.delete(key);
  }
  if (alive.length <= EPISODE_CACHE_MAX) {
    return;
  }
  alive.sort((a: string, b: string) => {
    const av = records.get(a);
    const bv = records.get(b);
    return (av !== undefined ? av.ts : 0) - (bv !== undefined ? bv.ts : 0);
  });
  for (let i = 0; i < alive.length - EPISODE_CACHE_MAX; i++) {
    records.delete(alive[i]);
  }
}

export class EpisodeCache {
  private static records: Map<string, EpisodeRecord> | null = null;
  private static filePath: string = '';
  private static writeTimer: number = -1;

  private static ensure(context: Context): Map<string, EpisodeRecord> {
    if (EpisodeCache.records !== null) {
      return EpisodeCache.records;
    }
    const records: Map<string, EpisodeRecord> = new Map();
    EpisodeCache.filePath = `${context.filesDir}/episode-cache.json`;
    try {
      if (fs.accessSync(EpisodeCache.filePath)) {
        const raw: string = fs.readTextSync(EpisodeCache.filePath);
        const parsed: Object = JSON.parse(raw) as Object;
        const root = parsed as Record<string, Object>;
        const keys: string[] = Object.keys(root);
        for (const key of keys) {
          const o = root[key] as Record<string, Object>;
          if (o === undefined || o === null) {
            continue;
          }
          const list = o['urls'] as Object[];
          if (list === undefined || list === null || list.length === 0) {
            continue;
          }
          const urls: string[] = [];
          for (const item of list) {
            if (typeof item === 'string' && (item as string) !== '') {
              urls.push(item as string);
            }
          }
          if (urls.length < 2) {
            continue;
          }
          const record: EpisodeRecord = {
            urls: urls,
            ts: typeof o['ts'] === 'number' ? o['ts'] as number : 0,
            first: typeof o['first'] === 'string' ? o['first'] as string : urls[0],
            last: typeof o['last'] === 'string' ? o['last'] as string : urls[urls.length - 1]
          };
          records.set(key, record);
        }
      }
    } catch (e) {
      // 文件损坏/读不到就当没有缓存，不影响主流程
    }
    pruneEpisodeRecords(records, Date.now());
    EpisodeCache.records = records;
    return records;
  }

  /** 命中返回选集地址；过期或对不上返回 null */
  static get(context: Context, server: string, sourceUrl: string, vodId: string,
    currentUrl: string = ''): string[] | null {
    if (vodId === '') {
      return null;
    }
    const records = EpisodeCache.ensure(context);
    const record = records.get(episodeCacheKey(server, sourceUrl, vodId));
    if (!episodeRecordUsable(record, currentUrl, Date.now())) {
      return null;
    }
    return (record as EpisodeRecord).urls.slice();
  }

  /** 写入缓存；只有一集的不写（多半是详情接口只回了半截） */
  static put(context: Context, server: string, sourceUrl: string, vodId: string, urls: string[]): void {
    if (vodId === '') { return; }
    const records = EpisodeCache.ensure(context);
    if (urls.length <= 1) {
      if (records.delete(episodeCacheKey(server, sourceUrl, vodId))) { EpisodeCache.scheduleWrite(); }
      return;
    }
    const record: EpisodeRecord = {
      urls: urls.slice(0),
      ts: Date.now(),
      first: urls[0],
      last: urls[urls.length - 1]
    };
    records.set(episodeCacheKey(server, sourceUrl, vodId), record);
    pruneEpisodeRecords(records, Date.now());
    EpisodeCache.scheduleWrite();
  }

  static clear(context: Context): boolean {
    const records = EpisodeCache.ensure(context);
    records.clear();
    if (EpisodeCache.writeTimer >= 0) { clearTimeout(EpisodeCache.writeTimer); EpisodeCache.writeTimer = -1; }
    return EpisodeCache.flush();
  }

  static count(context: Context): number {
    return EpisodeCache.ensure(context).size;
  }

  /** 合并短时间内的多次写入，避免一次详情页刷新连写几次几 MB */
  private static scheduleWrite(): void {
    if (EpisodeCache.writeTimer >= 0) {
      return;
    }
    EpisodeCache.writeTimer = setTimeout(() => {
      EpisodeCache.writeTimer = -1;
      EpisodeCache.flush();
    }, 1200);
  }

  static flush(): boolean {
    const records = EpisodeCache.records;
    if (records === null || EpisodeCache.filePath === '') {
      return false;
    }
    const root: Record<string, Object> = {};
    records.forEach((record: EpisodeRecord, key: string) => {
      root[key] = {
        'urls': record.urls,
        'ts': record.ts,
        'first': record.first,
        'last': record.last
      } as Record<string, Object>;
    });
    try {
      const file = fs.openSync(EpisodeCache.filePath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, JSON.stringify(root));
      } finally {
        fs.closeSync(file);
      }
      return true;
    } catch (e) {
      // 写盘失败只影响下次冷启动的体验
      return false;
    }
  }
}
