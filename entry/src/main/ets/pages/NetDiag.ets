/**
 * 网络诊断页 —— 简化版 NetDiag：
 *   · 服务端 /api/status TTFB（含会话）
 *   · 豆瓣推荐接口
 *   · 启用的点播源逐一直连探测（https 直连，8 秒超时）
 *   · 每项按耗时分级：绿（<800ms）/ 黄（<2500ms）/ 红（失败或更慢）
 */

import { router } from '@kit.ArkUI';
import { http } from '@kit.NetworkKit';
import { Session } from '../store/Session';
import { Theme } from '../common/Theme';

interface DiagRow {
  key: string;
  label: string;
  status: string;
  color: string;
}

const GREEN = '#0F766E';
const AMBER = '#B4761A';
const RED = '#C34545';
const GREY = '#617A70';

function grade(ms: number): string {
  return ms < 800 ? GREEN : (ms < 2500 ? AMBER : RED);
}

@Entry
@Component
struct NetDiag {
  @State running: boolean = false;
  @State rows: DiagRow[] = [];
  @State summary: string = '';

  private session: Session = Session.getInstance();

  private setRow(key: string, status: string, color: string): void {
    const idx = this.rows.findIndex((r: DiagRow) => r.key === key);
    if (idx >= 0) {
      const updated = this.rows.slice();
      updated[idx] = { key: key, label: updated[idx].label, status: status, color: color };
      this.rows = updated;
    } else {
      this.rows = this.rows.concat([{ key: key, label: key, status: status, color: color }]);
    }
  }

  private async timeGet(url: string, timeoutMs: number, readTimeoutMs: number,
    onBody: ((body: string) => void) | null): Promise<number> {
    const client = http.createHttp();
    const t0 = Date.now();
    try {
      const resp = await client.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: timeoutMs,
        readTimeout: readTimeoutMs,
        usingCache: false,
        header: { 'Accept': 'application/json' }
      });
      const ms = Date.now() - t0;
      if (resp.responseCode < 200 || resp.responseCode > 299) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      if (onBody !== null && typeof resp.result === 'string') {
        onBody(resp.result as string);
      }
      return ms;
    } finally {
      client.destroy();
    }
  }

  private async probeServer(): Promise<void> {
    const api = this.session.api;
    if (api === null) {
      this.setRow('服务端', '未连接', GREY);
      return;
    }
    this.setRow('服务端', '测试中…', GREY);
    try {
      const ms = await this.timeGet(`${api.baseUrl}/api/status`, 8000, 12000, null);
      this.setRow('服务端', `${ms} ms`, grade(ms));
    } catch (e) {
      this.setRow('服务端', `失败 · ${(e as Error).message}`, RED);
    }
  }

  private async probeDouban(): Promise<void> {
    const api = this.session.api;
    if (api === null) {
      return;
    }
    this.setRow('豆瓣推荐', '测试中…', GREY);
    try {
      const ms = await this.timeGet(
        `${api.baseUrl}/api/douban?type=tv&tag=热门&pageStart=0&pageSize=1`, 8000, 12000, null);
      this.setRow('豆瓣推荐', `${ms} ms`, grade(ms));
    } catch (e) {
      this.setRow('豆瓣推荐', `失败 · ${(e as Error).message}`, RED);
    }
  }

  /** 点播源直连探测：直连采集站 ac=detail 空查询 */
  private async probeSource(name: string, url: string): Promise<void> {
    this.setRow(name, '测试中…', GREY);
    const client = http.createHttp();
    const t0 = Date.now();
    try {
      const probeUrl = url.includes('?') ? `${url}&ac=detail&wd=` : `${url}?ac=detail&wd=`;
      const resp = await client.request(probeUrl, {
        method: http.RequestMethod.GET,
        connectTimeout: 8000,
        readTimeout: 8000,
        usingCache: false,
        header: { 'User-Agent': 'okhttp/3.12.0' }
      });
      const ms = Date.now() - t0;
      if (resp.responseCode < 200 || resp.responseCode > 299) {
        this.setRow(name, `HTTP ${resp.responseCode}`, RED);
      } else {
        this.setRow(name, `直连 ${ms} ms`, grade(ms));
      }
    } catch (e) {
      const ms = Date.now() - t0;
      this.setRow(name, `直连失败 · ${ms} ms`, RED);
    } finally {
      client.destroy();
    }
  }

  private async runAll(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.rows = [];
    this.summary = '';

    await this.probeServer();
    await this.probeDouban();

    // 点播源并行探测
    const enabled = this.session.enabledSources();
    const tasks: Promise<void>[] = [];
    for (const src of enabled.slice(0, 16)) {
      tasks.push(this.probeSource(src.name, src.url));
    }
    await Promise.all(tasks);

    const failed = this.rows.filter((r: DiagRow) => r.color === RED).length;
    this.summary = failed === 0 ? '全部通过 ✓' : `${failed} 项异常`;
    this.running = false;
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Text('网络诊断').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Blank()
        Button(this.running ? '诊断中…' : '开始诊断')
          .fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
          .enabled(!this.running)
          .onClick(() => { this.runAll(); })
        Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 10 })

      if (this.summary !== '') {
        Text(this.summary).fontSize(13).fontColor(Theme.SECONDARY)
          .width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }

      List({ space: 7 }) {
        ForEach(this.rows, (r: DiagRow) => {
          ListItem() {
            Row() {
              Text(r.key).fontSize(14).fontColor(Theme.INK)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              Text(r.status).fontSize(13).fontColor(r.color)
            }
            .width('100%').padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
            .border({ width: 1, color: Theme.BORDER })
          }
        }, (r: DiagRow) => r.key + r.status)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
      .scrollBar(BarState.Off)
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG)
  }
}
