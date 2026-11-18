import { RouteParams } from './RouteParams';
/**
 * 历史页 —— 观看记录（续播入口、删除单条、清空）。
 */

import { router, promptAction } from '@kit.ArkUI';
import { Prefs, WatchEntry } from '../store/Prefs';
import { Session } from '../store/Session';
import { Theme } from '../common/Theme';
import { PosterImage, PosterLocation } from '../components/PosterImage';
import { EntrySource } from '../components/EntrySource';
import { resumePlaybackParams } from '../common/ResumePlayback';
import { Detail, SourceConfig } from '../api/Models';
import { DETAIL_CACHE, DETAIL_CACHE_TTL_MS, detailCacheGeneration } from '../store/DetailCache';

@Entry
@Component
struct History {
  @State list: WatchEntry[] = [];

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;
  private source: EntrySource = new EntrySource();
  private disposed: boolean = false;
  private resuming: boolean = false;
  @State confirmingClear: boolean = false;
  private resumeGeneration: number = 0;

  aboutToAppear(): void {
    this.disposed = false;
    Prefs.get(getContext(this)).then((p: Prefs) => {
      this.prefs = p;
      p.getHistory().then((l: WatchEntry[]) => {
        this.setList(l);
      });
    });
  }

  aboutToDisappear(): void { this.disposed = true; this.resumeGeneration++; }

  onPageShow(): void {
    this.disposed = false;
    if (this.prefs !== null) { this.prefs.getHistory().then((l: WatchEntry[]) => { this.setList(l); }).catch(() => {}); }
  }

  private setList(l: WatchEntry[]): void {
    this.list = l;
    this.source.setItems(l);
  }

  private posterUrl(raw: string, sourceUrl: string): string {
    const url = raw.trim();
    if (url.startsWith('https://') || url.startsWith('http://')) { return url; }
    if (url.startsWith('//')) { return `https:${url}`; }
    const origin = sourceUrl.match(/^https?:\/\/[^/?#]+/);
    if (url.startsWith('/') && origin !== null) { return origin[0] + url; }
    return '';
  }

  private posterProxy(url: string, entry: WatchEntry): string {
    const api = this.session.api;
    return api !== null && entry.serverUrl === this.session.serverUrl && url !== '' ? api.imageUrl(url) : '';
  }

  private async recoverHistoryPoster(entry: WatchEntry, refresh: boolean): Promise<PosterLocation[]> {
    const api = this.session.api;
    const candidates: PosterLocation[] = [];
    if (api === null || entry.serverUrl !== this.session.serverUrl) { return candidates; }

    const previousUrl = this.posterUrl(entry.cover, entry.sourceUrl);
    const add = (url: string): void => {
      if (url !== '' && url !== previousUrl && !candidates.some((item: PosterLocation) => item.url === url)) {
        candidates.push({ url: url, proxy: api.imageUrl(url), cookie: api.currentCookie() });
      }
    };
    const key = `${entry.serverUrl}|${entry.sourceUrl}|${entry.vodId}`;
    const generation = detailCacheGeneration();
    if (!refresh) {
      const cached = DETAIL_CACHE.get(key);
      if (cached !== undefined && Date.now() - cached.at < DETAIL_CACHE_TTL_MS) {
        add(this.posterUrl(cached.detail.info.cover, entry.sourceUrl));
      }
      for (const item of this.session.cachedSearch(entry.title)) {
        if (item.name.trim() === entry.title.trim()) { add(this.posterUrl(item.pic, item.sourceUrl)); }
        if (candidates.length >= 3) { break; }
      }
      return candidates;
    }

    const source = this.session.sources.find((item: SourceConfig) => item.url === entry.sourceUrl);
    if (source === undefined || !source.enabled || entry.vodId === '') { return candidates; }
    let detail: Detail;
    if (this.session.directCms.shouldTryDirect(source)) {
      try { detail = await this.session.directCms.detail(source, entry.vodId); }
      catch (e) { detail = await api.detail(entry.vodId, source); }
    } else {
      detail = await api.detail(entry.vodId, source);
    }
    if (this.disposed || api !== this.session.api || generation !== detailCacheGeneration()) { return []; }
    add(this.posterUrl(detail.info.cover, entry.sourceUrl));
    if (candidates.length > 0 && detail.episodes.length > 0) {
      DETAIL_CACHE.set(key, { detail: detail, at: Date.now() });
    }
    return candidates;
  }

  private remove(key: string): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.removeWatch(key).then(() => {
      this.setList(this.list.filter((e: WatchEntry) => e.key !== key));
    });
  }

  private async clearAll(): Promise<void> {
    const prefs = this.prefs;
    if (prefs === null || this.list.length === 0 || this.confirmingClear) { return; }
    this.confirmingClear = true;
    try {
      const result = await promptAction.showDialog({
        title: '清空观看历史？',
        message: '清空后将无法从这些记录继续播放。',
        buttons: [{ text: '取消', color: Theme.INK }, { text: '清空', color: Theme.DANGER }]
      }).catch(() => null);
      if (result?.index !== 1 || this.disposed) { return; }
      await prefs.clearHistory();
      if (!this.disposed) { this.setList([]); }
    } catch (e) {
      if (!this.disposed) { promptAction.showToast({ message: '清空历史失败，请重试' }); }
    } finally {
      this.confirmingClear = false;
    }
  }

  private async resume(e: WatchEntry): Promise<void> {
    if (this.resuming) { return; }
    this.resuming = true;
    const generation = this.resumeGeneration;
    promptAction.showToast({ message: '正在准备续播…', duration: 1000 });
    try {
      const params = await resumePlaybackParams(getContext(this), e, this.session);
      if (!this.disposed && generation === this.resumeGeneration) { await router.pushUrl({ url: 'pages/Player', params: params }); }
    } catch (error) {
      if (!this.disposed && generation === this.resumeGeneration) { promptAction.showToast({ message: (error as Error).message || '无法继续播放' }); }
    } finally { this.resuming = false; }
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Text('全部历史').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Blank()
        Button('清空').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.DANGER)
          .enabled(this.list.length > 0 && !this.confirmingClear)
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
          LazyForEach(this.source, (e: WatchEntry) => {
            ListItem() {
              Row({ space: 12 }) {
                Stack() {
                  PosterImage({
                    url: this.posterUrl(e.cover, e.sourceUrl),
                    proxy: this.posterProxy(this.posterUrl(e.cover, e.sourceUrl), e),
                    fallbackLabel: e.title,
                    recoverPoster: (refresh: boolean) => this.recoverHistoryPoster(e, refresh),
                    onPosterRecovered: (url: string) => {
                      this.prefs?.updateWatchCover(e.key, e.cover, url).catch(() => {});
                    },
                    cookie: this.session.api !== null ? this.session.api.currentCookie() : '',
                    posterHeight: 90
                  })
                }.width(64).height(90)
                Column({ space: 5 }) {
                  Text(e.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`看到${e.episodeLabel || `第${e.episodeIndex + 1}集`} / 共${e.episodeCount}集 · ${this.fmtPos(e.positionMs)}`)
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
              .onClick(() => { this.resume(e); })
            }
          }, (e: WatchEntry) => e.key + e.updatedAt.toString())
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
        .cachedCount(4)
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
