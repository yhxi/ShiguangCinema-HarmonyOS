import { RouteParams } from './RouteParams';
/**
 * 详情页 —— 拉取选集列表（服务端 /api/detail，直连源优先）+ 选集 + 续播入口。
 * 视觉对齐 Android 版 showDetail：浅色底 + 白色卡片 + 深墨绿主色。
 */

import { promptAction, router } from '@kit.ArkUI';
import { Api } from '../api/Api';
import { Detail, SourceConfig } from '../api/Models';
import { Prefs, WatchEntry, watchKey } from '../store/Prefs';
import { Session } from '../store/Session';
import { ChildrenQuota } from '../store/ChildrenQuota';
import { EpisodeCache } from '../store/EpisodeCache';
import { DETAIL_CACHE, DETAIL_CACHE_TTL_MS, detailCacheGeneration } from '../store/DetailCache';
import { stripHtml } from '../common/TextClean';
import { PosterImage } from '../components/PosterImage';
import { Theme } from '../common/Theme';

/**
 * 详情缓存（内存，10 分钟）：
 *   从详情进播放页再返回、或同一部片从历史又点进来时，不必重新拉选集。
 *   命中就先渲染缓存内容，同时后台静默重新拉一次（不显示 loading、不闪屏），
 *   片源那边补了新集也能刷出来。
 */
/** 选集分段长度：上千集一次铺完会卡住首屏 */
const EPISODE_SEGMENT = 100;

@Entry
@Component
struct DetailPage {
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State cacheNotice: string = '';
  @State episodes: string[] = [];
  @State info: Record<string, string> = {
    'title': '', 'cover': '', 'desc': '', 'remarks': '', 'year': '', 'area': '', 'actor': ''
  };
  @State lastWatch: WatchEntry | null = null;
  @State selected: number = -1;
  @State isFav: boolean = false;
  @State favBusy: boolean = false;
  @State sourceName: string = '';
  /** 该片是否已纳入儿童每日额度（v1.3.7/v1.3.8：详情页提供加入入口） */
  @State kidManaged: boolean = false;
  @State kidLabel: string = '';
  /** 当前选集分段（每段 100 集） */
  @State epSegment: number = 0;

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
    if (params !== undefined && params['cover'] !== undefined) {
      this.info['cover'] = params['cover'];
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
      const cacheKey = `${this.session.serverUrl}|${this.sourceUrl}|${this.vodId}`;
      const cached = DETAIL_CACHE.get(cacheKey);
      if (cached !== undefined && Date.now() - cached.at < DETAIL_CACHE_TTL_MS) {
        this.applyDetail(cached.detail, false);
        this.cacheNotice = '正在更新缓存的选集…';
        this.loading = false;
        // 有缓存就后台静默校验，用户看到的始终是内容而不是转圈
        this.loadDetail(true).catch(() => {});
      } else if (this.useEpisodeCache()) {
        this.cacheNotice = '正在更新缓存的选集…';
        // 上千集的剧，选集列表落过盘就直接铺出来，详情信息随后补上
        this.loading = false;
        this.loadDetail(true).catch(() => {});
      } else {
        this.loadDetail();
      }
    });
  }

  /** 只是把缓存里的选集铺上去；标题等元信息仍等网络回来再填 */
  private useEpisodeCache(): boolean {
    if (this.vodId === '' || this.sourceUrl === '') {
      return false;
    }
    const urls = EpisodeCache.get(getContext(this), this.session.serverUrl, this.sourceUrl, this.vodId, '');
    if (urls === null) {
      return false;
    }
    this.episodes = urls;
    if (this.lastWatch !== null && this.lastWatch.episodeIndex >= 0 &&
      this.lastWatch.episodeIndex < urls.length) {
      this.selected = this.lastWatch.episodeIndex;
      this.focusSegment(this.lastWatch.episodeIndex);
    }
    return true;
  }

  /** 标题拿到之后才知道这片归不归儿童额度管 */
  private async refreshKidState(): Promise<void> {
    const p = this.prefs;
    if (p === null || this.info['title'] === '') {
      return;
    }
    const quota = await ChildrenQuota.get(p);
    this.kidManaged = quota.isManaged(this.info['title']);
    this.kidLabel = quota.label();
  }

  private async addToKidQuota(): Promise<void> {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    const quota = await ChildrenQuota.get(p);
    await quota.mark(this.info['title']);
    this.kidManaged = true;
    this.kidLabel = quota.label();
    promptAction.showToast({ message: `已加入儿童计时，${quota.label()}` });
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

  private async loadDetail(silent: boolean = false): Promise<void> {
    const cacheGeneration = detailCacheGeneration();
    const api = this.session.api;
    const src = this.findSource();
    if (api === null || src === null) {
      if (silent) { this.cacheNotice = '选集更新失败，当前显示缓存，地址可能已失效'; return; }
      this.loading = false;
      this.errorMsg = '会话已断开，请返回首页重新连接';
      return;
    }
    if (!silent) {
      this.loading = true;
      this.errorMsg = '';
    }
    // 直连源优先，失败回退服务端（与 Android 版一致）
    const direct = this.session.directCms;
    try {
      if (direct.shouldTryDirect(src)) {
        try {
          const d = await direct.detail(src, this.vodId);
          if (cacheGeneration !== detailCacheGeneration()) { return; }
          this.applyDetail(d);
          this.loading = false;
          return;
        } catch (e) {
          // 回退服务端
        }
      }
      const d = await api.detail(this.vodId, src);
      if (cacheGeneration !== detailCacheGeneration()) { return; }
      this.applyDetail(d);
    } catch (e) {
      // 静默刷新失败就保留缓存内容，不弹错
      if (!silent) { this.errorMsg = (e as Error).message; }
      else { this.cacheNotice = '选集更新失败，当前显示缓存，地址可能已失效'; }
    } finally {
      this.loading = false;
    }
  }

  private applyDetail(d: Detail, fresh: boolean = true): void {
    if (fresh) { this.cacheNotice = ''; }
    this.episodes = d.episodes;
    this.info = {
      'title': d.info.title !== '' ? d.info.title : this.info['title'],
      'cover': d.info.cover !== '' ? d.info.cover : this.info['cover'],
      'desc': stripHtml(d.info.desc), 'remarks': d.info.remarks,
      'year': d.info.year, 'area': d.info.area, 'actor': d.info.actor
    };
    if (this.lastWatch !== null && this.lastWatch.episodeIndex >= 0 &&
      this.lastWatch.episodeIndex < d.episodes.length) {
      this.selected = this.lastWatch.episodeIndex;
      this.focusSegment(this.lastWatch.episodeIndex);
    }
    if (fresh) {
      DETAIL_CACHE.set(`${this.session.serverUrl}|${this.sourceUrl}|${this.vodId}`, { detail: d, at: Date.now() });
      EpisodeCache.put(getContext(this), this.session.serverUrl, this.sourceUrl, this.vodId, d.episodes);
    }
    // 片名以详情为准，拿到后再判断是否受儿童额度管理
    this.refreshKidState().catch(() => {});
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
    if (this.cacheNotice !== '') { parts.push(this.cacheNotice); }
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
          if (this.info['title'] !== '') {
            Row({ space: 14 }) {
              PosterImage({ url: this.info['cover'], proxy: this.proxyImg(this.info['cover']),
                cookie: this.session.api !== null ? this.session.api.currentCookie() : '', posterHeight: 158 })
                .width(108).height(158)
              Text(this.info['title']).fontSize(21).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
                .maxLines(2).layoutWeight(1)
            }.width('100%').padding({ left: 16, right: 16, top: 20 })
          }
          Column({ space: 10 }) {
            LoadingProgress().width(36).height(36).color(Theme.ACCENT)
            Text('正在加载选集…').fontSize(13).fontColor(Theme.SECONDARY)
          }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
        }.layoutWeight(1).width('100%')
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
              Stack() {
                PosterImage({ url: this.info['cover'], proxy: this.proxyImg(this.info['cover']),
                  cookie: this.session.api !== null ? this.session.api.currentCookie() : '',
                  posterHeight: 158 })
              }.width(108).height(158)
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
                  Button(this.isFav ? '✓ 已收藏' : '＋ 收藏')
                    .fontSize(13).height(34).borderRadius(17)
                    .backgroundColor(this.isFav ? Theme.TINT : Theme.PANEL)
                    .fontColor(Theme.ACCENT)
                    .enabled(!this.favBusy)
                    .onClick(() => { this.toggleFav(); })
                }.width('100%').padding({ top: 4 })
                Row({ space: 8 }) {
                  if (this.kidManaged) {
                    Text(`儿童计时 · ${this.kidLabel}`).fontSize(11).fontColor(Theme.KID_ACCENT_DEEP)
                      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                      .borderRadius(11).backgroundColor(Theme.KID_TINT)
                  } else {
                    Button('＋ 加入儿童计时').fontSize(11).height(30).borderRadius(15)
                      .backgroundColor(Theme.KID_TINT).fontColor(Theme.KID_ACCENT_DEEP)
                      .onClick(() => { this.addToKidQuota(); })
                  }
                }.width('100%').padding({ top: 2 })
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

            Row({ space: 8 }) {
              Text(`选择集数（共 ${this.episodes.length} 集）`)
                .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK).layoutWeight(1)
              if (this.segmentCount() > 1) {
                Text(`${this.segmentStart() + 1}-${this.segmentEnd()}`)
                  .fontSize(12).fontColor(Theme.SECONDARY)
              }
            }.width('100%').padding({ top: 2 })

            // 上千集的剧一次铺 1000 个可选格子会卡住首屏，按 100 集分段
            if (this.segmentCount() > 1) {
              Scroll() {
                Row({ space: 6 }) {
                  ForEach(this.segmentLabels(), (label: string, seg: number) => {
                    Text(label).fontSize(12)
                      .fontColor(this.epSegment === seg ? Theme.ON_ACCENT : Theme.INK)
                      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
                      .borderRadius(12)
                      .backgroundColor(this.epSegment === seg ? Theme.ACCENT : Theme.PANEL)
                      .onClick(() => { this.epSegment = seg; })
                  }, (label: string, seg: number) => `${seg}`)
                }
              }
              .width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off)
            }

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.segmentIndexes(), (idx: number) => {
                Text(this.epLabel(idx))
                  .fontSize(13)
                  .fontColor(this.selected === idx ? Theme.ON_ACCENT : Theme.INK)
                  .padding({ left: 14, right: 14, top: 9, bottom: 9 })
                  .margin(4)
                  .borderRadius(10)
                  .backgroundColor(this.selected === idx ? Theme.ACCENT : Theme.PANEL)
                  .onClick(() => { this.playAt(idx); })
              }, (idx: number) => `${idx}`)
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

  private segmentCount(): number {
    return Math.max(1, Math.ceil(this.episodes.length / EPISODE_SEGMENT));
  }

  private segmentStart(): number {
    return this.epSegment * EPISODE_SEGMENT;
  }

  private segmentEnd(): number {
    return Math.min(this.episodes.length, this.segmentStart() + EPISODE_SEGMENT);
  }

  private segmentIndexes(): number[] {
    const out: number[] = [];
    for (let i = this.segmentStart(); i < this.segmentEnd(); i++) {
      out.push(i);
    }
    return out;
  }

  private segmentLabels(): string[] {
    const out: string[] = [];
    const total = this.segmentCount();
    for (let s = 0; s < total; s++) {
      const from = s * EPISODE_SEGMENT + 1;
      const to = Math.min(this.episodes.length, (s + 1) * EPISODE_SEGMENT);
      out.push(`${from}-${to}`);
    }
    return out;
  }

  /** 让当前选集落在看得见的那一段里 */
  private focusSegment(index: number): void {
    if (index < 0) {
      return;
    }
    this.epSegment = Math.floor(index / EPISODE_SEGMENT);
  }
}
