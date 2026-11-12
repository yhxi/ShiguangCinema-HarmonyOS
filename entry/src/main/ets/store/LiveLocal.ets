/**
 * 本地导入的直播频道表 + 频道收藏（对齐 Android v1.3.16 / v1.3.17 / v1.5.2）。
 *
 * 导入的列表存在应用内部（不走 U 盘常驻），因此换设备或清数据就没了；
 * 有意不做云同步——频道源里常带私人地址。
 */

import { Channel } from '../api/Models';
import { Prefs } from './Prefs';
import { inspectLocalLivePlaylist, LivePlaylistReport, sortedLiveChannels } from '../api/LivePlaylist';

const KEY_CHANNELS = 'liveLocalChannels';
const KEY_FAVORITES = 'liveFavoriteKeys';

function channelToObj(c: Channel): Record<string, Object> {
  return {
    'name': c.name,
    'url': c.url,
    'group': c.group,
    'logo': c.logo,
    'headers': c.headers !== undefined ? c.headers : ''
  };
}

export class LiveLocal {
  /** 读取本地导入的频道；返回时已按「央视 → 地方 → 其他」排好序 */
  static load(prefs: Prefs): Channel[] {
    const raw = prefs.getRaw(KEY_CHANNELS, '');
    if (raw === '') {
      return [];
    }
    const out: Channel[] = [];
    try {
      const arr = JSON.parse(raw) as Object[];
      if (Array.isArray(arr)) {
        for (const value of arr) {
          const o = value as Record<string, Object>;
          const url = typeof o['url'] === 'string' ? (o['url'] as string) : '';
          if (url === '') {
            continue;
          }
          out.push({
            name: typeof o['name'] === 'string' ? (o['name'] as string) : url,
            url: url,
            group: typeof o['group'] === 'string' ? (o['group'] as string) : '其他',
            logo: typeof o['logo'] === 'string' ? (o['logo'] as string) : '',
            headers: typeof o['headers'] === 'string' ? (o['headers'] as string) : ''
          });
        }
      }
    } catch (e) {
      return [];
    }
    return sortedLiveChannels(out);
  }

  static async save(prefs: Prefs, channels: Channel[]): Promise<void> {
    const arr: Object[] = [];
    for (const c of channels) {
      arr.push(channelToObj(c) as Object);
    }
    await prefs.putRaw(KEY_CHANNELS, JSON.stringify(arr));
  }

  static async clear(prefs: Prefs): Promise<void> {
    await prefs.putRaw(KEY_CHANNELS, '');
    await prefs.putStringList(KEY_FAVORITES, []);
  }

  /** 导入文本，返回解析报告；成功解析到的频道直接落到本地存储 */
  static async importText(prefs: Prefs, text: string): Promise<LivePlaylistReport> {
    const report = inspectLocalLivePlaylist(text);
    if (report.channels.length > 0) {
      await LiveLocal.save(prefs, sortedLiveChannels(report.channels));
    }
    return report;
  }

  static favorites(prefs: Prefs): Set<string> {
    return new Set<string>(prefs.getStringList(KEY_FAVORITES));
  }

  /** 返回切换后的收藏状态 */
  static async toggleFavorite(prefs: Prefs, key: string): Promise<boolean> {
    const list = prefs.getStringList(KEY_FAVORITES);
    const idx = list.indexOf(key);
    let added = false;
    if (idx >= 0) {
      list.splice(idx, 1);
    } else {
      list.unshift(key);
      added = true;
    }
    await prefs.putStringList(KEY_FAVORITES, list);
    return added;
  }
}
