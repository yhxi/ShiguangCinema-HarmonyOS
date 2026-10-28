import { RouteParams } from './RouteParams';
/**
 * 追剧页 —— 收藏的剧集，点击进详情续播。
 */

import { router } from '@kit.ArkUI';
import { Prefs, WatchEntry } from '../store/Prefs';
import { Session } from '../store/Session';
import { SourceConfig } from '../api/Models';
import { Theme } from '../common/Theme';

@Entry
@Component
struct Favorites {
  @State list: WatchEntry[] = [];
  @State checking: boolean = false;
  @State checkMessage: string = '';
  @State updates: Map<string, number> = new Map();

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;

  aboutToAppear(): void {
    Prefs.get(getContext(this)).then((p: Prefs) => {
      this.prefs = p;
      p.getFavorites().then((l: WatchEntry[]) => {
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

  private unfollow(e: WatchEntry): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.toggleFavorite(e).then(() => {
      this.list = this.list.filter((x: WatchEntry) => x.key !== e.key);
    });
  }

  private async checkUpdates(): Promise<void> {
    const api = this.session.api;
    if (api === null || this.checking) { return; }
    this.checking = true;
    this.checkMessage = '正在检查更新…';
    let failed = 0;
    let checked = 0;
    const updates: Map<string, number> = new Map();
    for (const item of this.list) {
      if (item.serverUrl !== this.session.serverUrl) { continue; }
      const source = this.session.sources.find((src: SourceConfig) => src.url === item.sourceUrl);
      if (source === undefined) { failed++; continue; }
      try {
        let count = 0;
        if (this.session.directCms.shouldTryDirect(source)) {
          try {
            count = (await this.session.directCms.detail(source, item.vodId)).episodes.length;
          } catch (e) {
            count = (await api.detail(item.vodId, source)).episodes.length;
          }
        } else {
          count = (await api.detail(item.vodId, source)).episodes.length;
        }
        checked++;
        if (count > item.episodeCount) { updates.set(item.key, count); }
      } catch (e) { failed++; }
    }
    this.updates = updates;
    this.checkMessage = `检查 ${checked} 部，${updates.size} 部有更新${failed > 0 ? `，${failed} 部失败` : ''}`;
    this.checking = false;
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Text('追剧').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Blank()
        Button(this.checking ? '检查中…' : '检查更新').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.ACCENT)
          .enabled(!this.checking).onClick(() => { this.checkUpdates(); })
        Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 10 })

      if (this.checkMessage !== '') {
        Text(this.checkMessage).fontSize(13).fontColor(Theme.SECONDARY)
          .width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }

      if (this.list.length === 0) {
        Column({ space: 6 }) {
          Text('还没有收藏的剧集').fontSize(14).fontColor(Theme.SECONDARY)
          Text('在详情页点「＋ 加入追剧」即可收藏').fontSize(13).fontColor(Theme.TERTIARY)
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
                  Text(e.episodeCount > 0 ? `共${e.episodeCount}集 · 已看第${e.episodeIndex + 1}集` : '点击查看')
                    .fontSize(12).fontColor(Theme.SECONDARY)
                  if (this.updates.has(e.key)) {
                    Text(`更新至 ${this.updates.get(e.key)} 集`).fontSize(12).fontColor(Theme.ACCENT)
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('取消').fontSize(12).fontColor(Theme.DANGER).padding(8)
                  .onClick(() => { this.unfollow(e); })
              }
              .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
              .onClick(() => {
                router.pushUrl({
                  url: 'pages/Detail',
                  params: { sourceUrl: e.sourceUrl, vodId: e.vodId, resumeKey: '' } as RouteParams
                });
              })
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
}
