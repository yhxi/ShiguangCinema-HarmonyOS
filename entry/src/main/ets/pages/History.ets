import { RouteParams } from './RouteParams';
/**
 * 历史页 —— 观看记录（续播入口、删除单条、清空）。
 */

import { router } from '@kit.ArkUI';
import { Prefs, WatchEntry } from '../store/Prefs';
import { Session } from '../store/Session';
import { Theme } from '../common/Theme';

@Entry
@Component
struct History {
  @State list: WatchEntry[] = [];

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;

  aboutToAppear(): void {
    Prefs.get(getContext(this)).then((p: Prefs) => {
      this.prefs = p;
      p.getHistory().then((l: WatchEntry[]) => {
        this.list = l;
      });
    });
  }

  private proxyImg(picUrl: string): string {
    const api = this.session.api;
    if (api === null || picUrl === '') {
      return '';
    }
    if (picUrl.includes('doubanio.com') || picUrl.includes('douban.com')) {
      return api.imageUrl(picUrl);
    }
    return picUrl;
  }

  private remove(key: string): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.removeWatch(key).then(() => {
      this.list = this.list.filter((e: WatchEntry) => e.key !== key);
    });
  }

  private clearAll(): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.clearHistory().then(() => {
      this.list = [];
    });
  }

  private goDetail(e: WatchEntry): void {
    router.pushUrl({
      url: 'pages/Detail',
      params: { sourceUrl: e.sourceUrl, vodId: e.vodId, resumeKey: e.key } as RouteParams
    });
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Text('观看历史').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Blank()
        Button('清空').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.DANGER)
          .enabled(this.list.length > 0)
          .onClick(() => { this.clearAll(); })
        Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 10 })

      if (this.list.length === 0) {
        Column() {
          Text('还没有观看记录').fontSize(14).fontColor(Theme.SECONDARY)
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
      } else {
        List({ space: 9 }) {
          ForEach(this.list, (e: WatchEntry) => {
            ListItem() {
              Row({ space: 12 }) {
                Image(this.proxyImg(e.cover))
                  .width(64).height(90).borderRadius(10)
                  .objectFit(ImageFit.Cover).backgroundColor(Theme.PLACEHOLDER)
                Column({ space: 5 }) {
                  Text(e.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`看到第${e.episodeIndex + 1}集 / 共${e.episodeCount}集 · ${this.fmtPos(e.positionMs)}`)
                    .fontSize(12).fontColor(Theme.SECONDARY)
                  Text(this.fmtTime(e.updatedAt)).fontSize(11).fontColor(Theme.TERTIARY)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('删除').fontSize(12).fontColor(Theme.DANGER).padding(8)
                  .onClick(() => { this.remove(e.key); })
              }
              .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
              .onClick(() => { this.goDetail(e); })
            }
          }, (e: WatchEntry) => e.key + e.updatedAt.toString())
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG)
  }

  private fmtPos(ms: number): string {
    const totalSec = Math.floor(ms / 1000);
    const m = Math.floor(totalSec / 60);
    const sec = totalSec % 60;
    return `${m}:${sec < 10 ? '0' : ''}${sec}`;
  }

  private fmtTime(ts: number): string {
    const d = new Date(ts);
    const mm = d.getMonth() + 1;
    const dd = d.getDate();
    const hh = d.getHours();
    const mi = d.getMinutes();
    const pad = (v: number): string => v < 10 ? `0${v}` : `${v}`;
    return `${mm}-${pad(dd)} ${pad(hh)}:${pad(mi)}`;
  }
}
