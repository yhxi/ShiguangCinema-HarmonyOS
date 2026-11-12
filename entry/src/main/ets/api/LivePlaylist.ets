/**
 * 直播频道表解析与排序（对齐 Android 版 LivePlaylist.kt）。
 *
 * 支持两种本地导入格式：
 *   · M3U：#EXTINF 带 group-title / tvg-logo / tvg-name，频道名取最后一个未被引号包住
 *     的逗号之后的内容（引号里的逗号不算分隔符）；#EXTVLCOPT 里的 User-Agent /
 *     Referer / Origin 会作为请求头保留，其他指令计入「不支持」并提示。
 *   · TXT：`频道名,地址` 每行一条，`分组名,#genre#` 切换当前分组。
 *
 * 榜单顺序（v1.3.17）：央视编号频道 → 地方台 → 其余，组内保持原顺序。
 * 同名频道（去掉 高清/4K/HD 等后缀后同名）作为备用线路依次尝试。
 */

import { Channel } from './Models';

export interface LivePlaylistReport {
  channels: Channel[];
  /** 无法解析的行数 */
  skipped: number;
  /** 不支持的指令条数 */
  unsupportedDirectives: number;
}

const ATTR = /([a-z-]+)="([^"]*)"/gi;

function headerToText(headers: Map<string, string>): string {
  const lines: string[] = [];
  headers.forEach((v: string, k: string) => {
    lines.push(`${k}: ${v}`);
  });
  return lines.join('\n');
}

/** 把 "K: V\nK: V" 解析回 Map，供播放器设置请求头 */
export function parseChannelHeaders(text: string | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (text === undefined || text === '') {
    return out;
  }
  for (const line of text.split('\n')) {
    const idx = line.indexOf(':');
    if (idx <= 0) {
      continue;
    }
    const key = line.substring(0, idx).trim();
    const value = line.substring(idx + 1).trim();
    if (key !== '' && value !== '') {
      out[key] = value;
    }
  }
  return out;
}

/** 解析本地列表；report 同时给出跳过项，导入后可以如实告诉用户 */
export function inspectLocalLivePlaylist(text: string): LivePlaylistReport {
  const channels: Map<string, Channel> = new Map<string, Channel>();
  let skipped = 0;
  let unsupported = 0;
  let name = '';
  let group = '其他';
  let logo = '';
  const headers: Map<string, string> = new Map<string, string>();
  const cleaned = text.charCodeAt(0) === 0xFEFF ? text.substring(1) : text;

  const add = (label: string, url: string): void => {
    if (!/^https?:\/\//i.test(url)) {
      skipped++;
      return;
    }
    const headerText = headerToText(headers);
    const key = `${url}\u0000${headerText}`;
    if (!channels.has(key)) {
      channels.set(key, {
        name: label.trim() === '' ? `频道 ${channels.size + 1}` : label.trim(),
        url: url,
        group: group === '' ? '其他' : group,
        logo: logo,
        headers: headerText
      });
    }
  };

  for (const rawLine of cleaned.split('\n')) {
    const line = rawLine.trim();
    if (line === '') {
      continue;
    }
    if (/^#EXTINF/i.test(line)) {
      ATTR.lastIndex = 0;
      const attrs: Map<string, string> = new Map<string, string>();
      let match = ATTR.exec(line);
      while (match !== null) {
        attrs.set(match[1].toLowerCase(), match[2]);
        match = ATTR.exec(line);
      }
      // 找第一个引号外的逗号（与 Android 版一致：属性区之后的第一个逗号即名称起点，
      // 名称里自带的逗号属于名称）
      let quoted = false;
      let comma = -1;
      for (let i = 0; i < line.length; i++) {
        const ch = line.charAt(i);
        if (ch === '"') {
          quoted = !quoted;
        } else if (ch === ',' && !quoted) {
          comma = i;
          break;
        }
      }
      const tvgName = attrs.get('tvg-name');
      name = comma >= 0 ? line.substring(comma + 1).trim() : (tvgName !== undefined ? tvgName : '');
      const groupTitle = attrs.get('group-title');
      group = groupTitle !== undefined && groupTitle !== '' ? groupTitle : '其他';
      const tvgLogo = attrs.get('tvg-logo');
      logo = tvgLogo !== undefined ? tvgLogo : '';
      headers.clear();
      continue;
    }
    if (/^#EXTGRP:/i.test(line)) {
      const value = line.substring(line.indexOf(':') + 1).trim();
      group = value === '' ? '其他' : value;
      continue;
    }
    if (/^#EXTVLCOPT:/i.test(line)) {
      const option = line.substring(line.indexOf(':') + 1).trim();
      const eq = option.indexOf('=');
      const key = (eq >= 0 ? option.substring(0, eq) : option).trim().toLowerCase();
      const value = eq >= 0 ? option.substring(eq + 1).trim() : '';
      let header = '';
      if (key === 'http-user-agent') {
        header = 'User-Agent';
      } else if (key === 'http-referrer' || key === 'http-referer') {
        header = 'Referer';
      } else if (key === 'http-origin') {
        header = 'Origin';
      }
      if (header === '' || value === '' || value.length > 512) {
        unsupported++;
      } else {
        headers.set(header, value);
      }
      continue;
    }
    if (/^#KODIPROP/i.test(line) || /^#EXTHTTP/i.test(line)) {
      unsupported++;
      continue;
    }
    if (line.startsWith('#')) {
      continue;
    }
    if (/^https?:\/\//i.test(line)) {
      add(name, line);
      name = '';
      logo = '';
      headers.clear();
      continue;
    }
    const comma = line.indexOf(',');
    if (comma > 0) {
      const label = line.substring(0, comma).trim();
      const url = line.substring(comma + 1).trim();
      if (url.toLowerCase() === '#genre#') {
        group = label === '' ? '其他' : label;
      } else {
        logo = '';
        headers.clear();
        add(label, url);
      }
      continue;
    }
    skipped++;
  }

  const out: Channel[] = [];
  channels.forEach((v: Channel) => out.push(v));
  return { channels: out, skipped: skipped, unsupportedDirectives: unsupported };
}

export function parseLocalLivePlaylist(text: string): Channel[] {
  return inspectLocalLivePlaylist(text).channels;
}

/** 默认播 CCTV1，找不到就第一台 */
export function isCctvOne(name: string): boolean {
  const key = name.toLowerCase().trim().replace(/[_—·-]/g, '');
  if (/^((?:央视)?cctv|央视|中央)\s*0?1(?![0-9])/.test(key)) {
    return true;
  }
  return key === '中央一台' || key === '央视一套' || key === '央视综合' || key === '中央电视台综合频道';
}

export function defaultLiveChannelIndex(channels: Channel[]): number {
  if (channels.length === 0) {
    return -1;
  }
  for (let i = 0; i < channels.length; i++) {
    if (isCctvOne(channels[i].name)) {
      return i;
    }
  }
  return 0;
}

export function stepLiveChannel(index: number, delta: number, count: number): number {
  if (count <= 0) {
    return -1;
  }
  return ((index + delta) % count + count) % count;
}

const CCTV_NUMBER = /^(?:(?:央视)?cctv|央视|中央)\s*0?([0-9]{1,2})(?![0-9])/i;
const LOCAL_HINT =
  /卫视|地方|省台|市台|北京|上海|天津|重庆|河北|山西|辽宁|吉林|黑龙江|江苏|浙江|安徽|福建|江西|山东|河南|湖北|湖南|广东|广西|海南|四川|贵州|云南|陕西|甘肃|青海|宁夏|新疆|内蒙古|西藏|深圳|厦门|青岛|大连|宁波/;

interface Ranked {
  index: number;
  channel: Channel;
  primary: number;
  secondary: number;
}

/** 央视编号（含 CCTV5+ 排 5 后面）→ 地方台 → 其余；组内稳定 */
export function sortedLiveChannels(channels: Channel[]): Channel[] {
  const ranked: Ranked[] = [];
  for (let i = 0; i < channels.length; i++) {
    const channel = channels[i];
    const name = channel.name.trim().replace(/[_—·-]/g, '');
    let primary = 2;
    let secondary = 0;
    if (/^(?:央视)?cctv[48]k$/i.test(name.replace(/\s+/g, ''))) {
      primary = 0;
      secondary = 1000;
    } else {
      const match = CCTV_NUMBER.exec(name);
      if (match !== null) {
        const number = parseInt(match[1], 10);
        primary = 0;
        const plus = name.substring(match[0].length).trim().startsWith('+') ? 1 : 0;
        secondary = (isNaN(number) ? 99 : number) * 2 + plus;
      } else if (isCctvOne(channel.name)) {
        primary = 0;
        secondary = 2;
      } else if (/^cctv/i.test(name) || name.startsWith('央视')) {
        primary = 0;
        secondary = 1000;
      } else if (LOCAL_HINT.test(channel.name) || LOCAL_HINT.test(channel.group)) {
        primary = 1;
      }
    }
    ranked.push({ index: i, channel: channel, primary: primary, secondary: secondary });
  }
  ranked.sort((a: Ranked, b: Ranked) => {
    if (a.primary !== b.primary) {
      return a.primary - b.primary;
    }
    if (a.secondary !== b.secondary) {
      return a.secondary - b.secondary;
    }
    return a.index - b.index;
  });
  return ranked.map((r: Ranked) => r.channel);
}

/** 去掉画质/清晰度后缀后的频道名，用来把同名频道视作同一台的不同线路 */
export function liveChannelKey(name: string): string {
  const original = name.trim().toLowerCase().replace(/[\s_—·-]/g, '');
  if (original === 'cctv4k' || original === 'cctv8k' || original === '央视cctv4k' || original === '央视cctv8k') {
    return original;
  }
  const key = original.replace(/(超高清|高清|标清|fhd|uhd|hd|4k|1080p|720p)+$/, '');
  const cctvOneAliases: Set<string> = new Set<string>([
    'cctv1综合', 'cctv01综合', '央视cctv1', '央视cctv1综合', 'cctv01',
    '央视综合', '中央一台', '央视一套', '中央电视台综合频道'
  ]);
  return cctvOneAliases.has(key) ? 'cctv1' : key;
}
