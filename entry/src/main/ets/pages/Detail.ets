import { RouteParams } from './RouteParams';
/**
 * 详情页 —— 拉取选集列表（服务端 /api/detail，直连源优先）+ 选集 + 续播入口。
 * 视觉对齐 Android 版 showDetail：浅色底 + 白色卡片 + 深墨绿主色。
 */

import { router } from '@kit.ArkUI';
import { Api } from '../api/Api';
import { Detail, SourceConfig } from '../api/Models';
import { Prefs, WatchEntry, watchKey } from '../store/Prefs';
import { Session } from '../store/Session';
import { Theme } from '../common/Theme';

@Entry
@Component
struct DetailPage {
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State episodes: string[] = [];
  @State info: Record<string, string> = {
    'title': '', 'cover': '', 'desc': '', 'remarks': '', 'year': '', 'area': '', 'actor': ''
  };
  @State lastWatch: WatchEntry | null = null;
  @State selected: number = -1;
  @State isFav: boolean = false;
  @State favBusy: boolean = false;
  @State sourceName: string = '';

  private session: Session = Session.getInstance();
  private sourceUrl: string = '';
  private vodId: string = '';
  private resumeKey: string = '';
  private prefs: Prefs | null = null;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string> | undefined;
    this.sourceUrl = params !== undefined && params['sourceUrl'] !== undefined ? params['sourceUrl'] : '';
    this.vodId = params !== undefined && params['vodId'] !== undefined ? params['vodId'] : '';
    this.resumeKey = params !== undefined && params['resumeKey'] !== undefined ? params['resumeKey'] : '';
    if (params !== undefined && params['title'] !== undefined && this.info['title'] === '') {
      this.info['title'] = params['title'];
    }
    Prefs.get(getContext(this)).then(async (p: Prefs) => {
      this.prefs = p;
      if (this.session.serverUrl !== '') {
        this.isFav = await p.isFavorite(this.session.serverUrl, this.sourceUrl, this.vodId);
      }
      if (this.resumeKey !== '') {
        const list = await p.getHistory();
        for (const e of list) {
          if (e.key === this.resumeKey) {
            this.lastWatch = e;
            break;
          }
        }
      } else if (this.session.serverUrl !== '') {
        const list = await p.getHistory();
        const key = watchKey(this.session.serverUrl, this.sourceUrl, this.vodId);
        for (const e of list) {
          if (e.key === key) {
            this.lastWatch = e;
            break;
          }
        }
      }
      this.loadDetail();
    });
  }

  private findSource(): SourceConfig | null {
    for (const src of this.session.sources) {
      if (src.url === this.sourceUrl) {
        this.sourceName = src.name;
        return src;
      }
    }
    // 搜索结果可能来自服务端下发的临时源，构造一个最小配置
    const fallback: SourceConfig = {
      name: this.sourceUrl, url: this.sourceUrl, detail: '', isAdult: false, enabled: true
    };
    return fallback;
  }

  private async loadDetail(): Promise<void> {
    const api = this.session.api;
    const src = this.findSource();
    if (api === null || src === null) {
      this.loading = false;
      this.errorMsg = '会话已断开，请返回首页重新连接';
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    // 直连源优先，失败回退服务端（与 Android 版一致）
    const direct = this.session.directCms;
    try {
      if (direct.shouldTryDirect(src)) {
        try {
          const d = await direct.detail(src, this.vodId);
          this.applyDetail(d);
          this.loading = false;
          return;
        } catch (e) {
          // 回退服务端
        }
      }
      const d = await api.detail(this.vodId, src);
      this.applyDetail(d);
    } catch (e) {
      this.errorMsg = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  private applyDetail(d: Detail): void {
    this.episodes = d.episodes;
    this.info = {
      'title': d.info.title !== '' ? d.info.title : this.info['title'],
      'cover': d.info.cover, 'desc': d.info.desc, 'remarks': d.info.remarks,
      'year': d.info.year, 'area': d.info.area, 'actor': d.info.actor
    };
    if (this.lastWatch !== null && this.lastWatch.episodeIndex >= 0 &&
      this.lastWatch.episodeIndex < d.episodes.length) {
      this.selected = this.lastWatch.episodeIndex;
    }
  }

  private proxyImg(picUrl: string): string {
    const api = this.session.api;
    if (api === null || picUrl === '') {
      return '';
    }
    // 豆瓣之外的图直连，失败时由 Image 组件自行灰底
    if (picUrl.includes('doubanio.com') || picUrl.includes('douban.com')) {
      return api.imageUrl(picUrl);
    }
    return picUrl;
  }

  /** 标题下方的信息行：年份 · 地区 · 备注 · 来源 · 共 N 集（与 Android 版一致） */
  private metaLine(): string {
    const parts: string[] = [];
    const keys: string[] = ['year', 'area', 'remarks'];
    for (const k of keys) {
      if (this.info[k] !== '') { parts.push(this.info[k]); }
    }
    if (this.sourceName !== '') { parts.push(this.sourceName); }
    if (this.episodes.length > 0) { parts.push(`共 ${this.episodes.length} 集`); }
    return parts.join(' · ');
  }

  private playAt(index: number): void {
    if (index < 0 || index >= this.episodes.length) {
      return;
    }
    const resumeMs = (this.lastWatch !== null && this.lastWatch.episodeIndex === index)
      ? this.lastWatch.positionMs : 0;
    router.pushUrl({
      url: 'pages/Player',
      params: {
        'episodes': JSON.stringify(this.episodes),
        'index': index.toString(),
        'title': this.info['title'],
        'cover': this.info['cover'],
        'sourceUrl': this.sourceUrl,
        'vodId': this.vodId,
        'resumeMs': resumeMs.toString()
      } as RouteParams
    });
  }

  private async toggleFav(): Promise<void> {
    if (this.prefs === null || this.favBusy || this.session.serverUrl === '') {
      return;
    }
    this.favBusy = true;
    try {
      const entry: WatchEntry = {
        key: watchKey(this.session.serverUrl, this.sourceUrl, this.vodId),
        serverUrl: this.session.serverUrl,
        sourceUrl: this.sourceUrl,
        vodId: this.vodId,
        title: this.info['title'],
        cover: this.info['cover'],
        episodeIndex: this.selected >= 0 ? this.selected : 0,
        episodeCount: this.episodes.length,
        positionMs: 0,
        durationMs: 0,
        updatedAt: Date.now()
      };
      this.isFav = await this.prefs.toggleFavorite(entry);
    } finally {
      this.favBusy = false;
    }
  }

  @Builder
  topBar() {
    Row({ space: 10 }) {
      Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
        .width(26).height(26).textAlign(TextAlign.Center)
        .borderRadius(8).backgroundColor(Theme.ACCENT)
      Text('时光影院').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
      Blank()
      Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
        .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
        .onClick(() => { router.back(); })
    }.width('100%').padding({ top: 8, bottom: 8 })
  }

  build() {
    Column() {
      this.topBar()

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color(Theme.ACCENT)
          Text('加载中…').fontSize(13).fontColor(Theme.SECONDARY)
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
      } else if (this.errorMsg !== '') {
        Column({ space: 14 }) {
          Text(this.errorMsg).fontSize(14).fontColor(Theme.DANGER).textAlign(TextAlign.Center)
          Button('重试').fontSize(15).height(42).borderRadius(21)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.loadDetail(); })
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%').padding(24)
      } else {
        Scroll() {
          Column({ space: 14 }) {
            Row({ space: 14 }) {
              Image(this.proxyImg(this.info['cover']))
                .width(108).height(158).borderRadius(12)
                .objectFit(ImageFit.Cover).backgroundColor(Theme.PLACEHOLDER)
              Column({ space: 7 }) {
                Text(this.info['title']).fontSize(21).fontWeight(FontWeight.Bold)
                  .fontColor(Theme.INK).maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (this.metaLine() !== '') {
                  Text(this.metaLine()).fontSize(12).fontColor(Theme.SECONDARY)
                    .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                if (this.info['actor'] !== '') {
                  Text(`主演：${this.info['actor']}`).fontSize(12).fontColor(Theme.SECONDARY)
                    .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                Row({ space: 8 }) {
                  if (this.lastWatch !== null) {
                    Button(`▶ 继续看第${this.lastWatch.episodeIndex + 1}集`)
                      .fontSize(13).height(34).borderRadius(17)
                      .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
                      .onClick(() => { this.playAt(this.lastWatch !== null ? this.lastWatch.episodeIndex : 0); })
                  }
                  Button(this.isFav ? '✓ 已追剧' : '＋ 加入追剧')
                    .fontSize(13).height(34).borderRadius(17)
                    .backgroundColor(this.isFav ? Theme.TINT : Theme.PANEL)
                    .fontColor(Theme.ACCENT)
                    .enabled(!this.favBusy)
                    .onClick(() => { this.toggleFav(); })
                }.width('100%').padding({ top: 4 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }.width('100%')

            if (this.info['desc'] !== '') {
              Text(this.info['desc']).fontSize(13).fontColor(Theme.BODY).lineHeight(21)
                .maxLines(6).textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%').padding(14).borderRadius(Theme.RADIUS_CARD)
                .backgroundColor(Theme.PANEL)
            }

            Text(`选择集数（共 ${this.episodes.length} 集）`)
              .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK).width('100%')
              .padding({ top: 2 })
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.episodes, (url: string, idx: number) => {
                Text(this.epLabel(idx))
                  .fontSize(13)
                  .fontColor(this.selected === idx ? Theme.ON_ACCENT : Theme.INK)
                  .padding({ left: 14, right: 14, top: 9, bottom: 9 })
                  .margin(4)
                  .borderRadius(10)
                  .backgroundColor(this.selected === idx ? Theme.ACCENT : Theme.PANEL)
                  .onClick(() => { this.playAt(idx); })
              }, (url: string, idx: number) => `${idx}`)
            }.width('100%')
          }
          .padding({ left: 16, right: 16, bottom: 28 })
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG)
  }

  private epLabel(idx: number): string {
    return idx < 100 ? `第${idx + 1}集` : `${idx + 1}`;
  }
}
