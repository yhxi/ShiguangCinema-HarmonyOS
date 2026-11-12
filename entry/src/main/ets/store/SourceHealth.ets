/**
 * 片源健康记录（本地持久化）。
 *
 * 为什么需要它：21 个源全测一遍要几十秒，以前结果只在内存里，退出片源管理就没了，
 * 下次进来又得重测。现在把「可用性 / 条目数 / 延迟 / 检测时间」写进首选项，
 * 进页面先用上次结果把状态标出来，点「检测全部」再刷新。
 *
 * 记录按 URL 索引（与具体服务端无关，换服务端仍然有效）。
 */

import { Prefs } from './Prefs';

const KEY_HEALTH = 'sourceHealth';

export interface HealthRecord {
  /** 是否可用 */
  ok: boolean;
  /** 探测到的条目数；0 表示没拿到 */
  count: number;
  /** 往返耗时（毫秒），失败时记录超时附近的耗时 */
  ms: number;
  /** 检测时间戳（毫秒） */
  at: number;
  /** 探测方式：direct 直连采集站 / server 服务端代理 */
  via: string;
}

type HealthMap = Map<string, HealthRecord>;

export class SourceHealth {
  /** 超过这个时长就在界面上标「结果较旧」，但不自动重测，避免开着页面偷偷跑流量 */
  static readonly STALE_MS: number = 6 * 3600 * 1000;

  static load(prefs: Prefs): HealthMap {
    const map: HealthMap = new Map<string, HealthRecord>();
    const raw = prefs.getRaw(KEY_HEALTH, '');
    if (raw === '') {
      return map;
    }
    try {
      const root = JSON.parse(raw) as Record<string, Object>;
      for (const url of Object.keys(root)) {
        const o = root[url] as Record<string, Object>;
        if (o === null || o === undefined) {
          continue;
        }
        const record: HealthRecord = {
          ok: o['ok'] === true,
          count: typeof o['count'] === 'number' ? o['count'] as number : 0,
          ms: typeof o['ms'] === 'number' ? o['ms'] as number : 0,
          at: typeof o['at'] === 'number' ? o['at'] as number : 0,
          via: typeof o['via'] === 'string' ? o['via'] as string : ''
        };
        map.set(url, record);
      }
    } catch (e) {
      // 记录坏了就当没有，不影响功能
    }
    return map;
  }

  static async save(prefs: Prefs, map: HealthMap): Promise<void> {
    const root: Record<string, Object> = {};
    map.forEach((v: HealthRecord, url: string) => {
      const o: Record<string, Object> = { 'ok': v.ok, 'count': v.count, 'ms': v.ms, 'at': v.at, 'via': v.via };
      root[url] = o;
    });
    await prefs.putRaw(KEY_HEALTH, JSON.stringify(root));
  }

  static isStale(record: HealthRecord | undefined): boolean {
    return record === undefined || Date.now() - record.at > SourceHealth.STALE_MS;
  }

  /** 「刚刚 / 3 分钟前 / 2 小时前 / 5 天前」 */
  static ageLabel(record: HealthRecord | undefined): string {
    if (record === undefined || record.at <= 0) {
      return '未检测';
    }
    const diff = Date.now() - record.at;
    if (diff < 60000) {
      return '刚刚';
    }
    if (diff < 3600000) {
      return `${Math.floor(diff / 60000)} 分钟前`;
    }
    if (diff < 86400000) {
      return `${Math.floor(diff / 3600000)} 小时前`;
    }
    return `${Math.floor(diff / 86400000)} 天前`;
  }
}
