/**
 * 采集站客户端直连（自 Android 版 DirectCms.kt 移植，仅标准苹果CMS）。
 *
 * 适用条件：
 *   · https（明文 http 容易被劫持）
 *   · 路径带 /api.php 或 /provide/vod —— 即标准苹果CMS
 *   · 非成人源
 * 直连连续失败 2 次后 5 分钟内改走服务端，与 Android 版策略一致。
 */

import { http } from '@kit.NetworkKit';
import { Detail, SearchItem, SourceConfig, VideoInfo } from './Models';
import { JsonObj, asArr, asObj, getArr, getObj, parseObj, s } from './JsonUtil';
import { parsePlayUrls } from './PlayUrls';

const UA = 'okhttp/3.12.0';
const CONNECT_TIMEOUT_MS = 3500;
const READ_TIMEOUT_MS = 6000;
const DIRECT_RETRY_DELAY_MS = 5 * 60 * 1000;

interface FailureState {
  count: number;
  retryAt: number;
}

function isEligible(src: SourceConfig): boolean {
  if (src.isAdult) {
    return false;
  }
  const u = src.url;
  if (!u.startsWith('https://')) {
    return false;
  }
  return u.includes('/api.php') || u.includes('/provide/vod');
}

export class DirectCms {
  private failures: Map<string, FailureState> = new Map();

  shouldTryDirect(src: SourceConfig): boolean {
    if (!isEligible(src)) {
      return false;
    }
    const f = this.failures.get(src.url);
    if (f === undefined) {
      return true;
    }
    return f.retryAt <= Date.now();
  }

  private recordFailure(url: string): void {
    const prev = this.failures.get(url);
    const count = (prev === undefined || prev.retryAt > 0) ? 1 : prev.count + 1;
    const state: FailureState = {
      count: count,
      retryAt: count >= 2 ? Date.now() + DIRECT_RETRY_DELAY_MS : 0
    };
    this.failures.set(url, state);
  }

  private async getSourceJson(src: SourceConfig, url: string): Promise<JsonObj> {
    const client = http.createHttp();
    try {
      const resp = await client.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': UA, 'Accept': 'application/json' },
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        usingCache: false
      });
      if (resp.responseCode < 200 || resp.responseCode > 299) {
        throw new Error(`直连失败 HTTP ${resp.responseCode}`);
      }
      if (typeof resp.result !== 'string') {
        throw new Error('直连响应不是文本');
      }
      const root = parseObj(resp.result as string);
      this.failures.delete(src.url);
      return root;
    } catch (e) {
      this.recordFailure(src.url);
      throw e as Error;
    } finally {
      client.destroy();
    }
  }

  private buildUrl(base: string, keyword: string | null, vodId: string | null): string {
    let url = base;
    if (url.includes('?')) {
      url += '&';
    } else {
      url += '?';
    }
    url += vodId !== null
      ? `ac=detail&ids=${encodeURIComponent(vodId)}`
      : `ac=detail&wd=${encodeURIComponent(keyword ?? '')}`;
    return url;
  }

  /** 搜索。失败直接抛异常，由调用方决定是否回退服务端。 */
  async search(src: SourceConfig, keyword: string): Promise<SearchItem[]> {
    const root = await this.getSourceJson(src, this.buildUrl(src.url, keyword, null));
    const out: SearchItem[] = [];
    const list = getArr(root, 'list');
    if (list === null) {
      throw new Error('采集站响应缺少列表');
    }
    for (const item of list) {
      const o = asObj(item);
      if (o === null) {
        continue;
      }
      const id = s(o['vod_id']);
      const name = s(o['vod_name']);
      if (id === '' || name === '') {
        continue;
      }
      out.push({
        sourceName: src.name,
        vodId: id,
        name: name,
        pic: s(o['vod_pic']),
        typeName: s(o['type_name']),
        year: s(o['vod_year']),
        remarks: s(o['vod_remarks']),
        sourceUrl: src.url
      });
    }
    return out;
  }

  /** 详情。返回的 episodes 已是纯播放地址数组，和服务端 /api/detail 对齐。 */
  async detail(src: SourceConfig, vodId: string): Promise<Detail> {
    const root = await this.getSourceJson(src, this.buildUrl(src.url, null, vodId));
    const list = getArr(root, 'list');
    let item: JsonObj | null = null;
    if (list !== null && list.length > 0) {
      item = asObj(list[0]);
    }
    if (item === null) {
      throw new Error('详情为空');
    }
    const urls = parsePlayUrls(s(item['vod_play_url']), s(item['vod_play_from']));
    if (urls.length === 0) {
      // 区分"确实没有地址"和"只有网页播放器地址"，后者给用户更明确的提示
      throw new Error(s(item['vod_play_url']).indexOf('http') >= 0
        ? '该片源只提供网页播放地址，无法直接播放' : '没有播放地址');
    }
    const info: VideoInfo = {
      title: s(item['vod_name']),
      cover: s(item['vod_pic']),
      desc: s(item['vod_content']),
      remarks: s(item['vod_remarks']),
      year: s(item['vod_year']),
      area: s(item['vod_area']),
      actor: s(item['vod_actor'])
    };
    return { episodes: urls, info: info };
  }
}

