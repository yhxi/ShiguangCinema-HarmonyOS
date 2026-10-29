import { RouteParams } from './RouteParams';
/**
 * 搜索页 —— 服务端聚合搜索 + 直连源并行加速（失败回退服务端）。
 * 支持从首页推荐点击带入关键词。视觉对齐 Android 版：浅色底 + 白色行卡片。
 */

import { router } from '@kit.ArkUI';
import { SearchItem, SourceConfig } from '../api/Models';
import { Session } from '../store/Session';
import { Theme } from '../common/Theme';

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State searching: boolean = false;
  @State statusMsg: string = '';
  @State items: SearchItem[] = [];

  private session: Session = Session.getInstance();
  private searchGeneration: number = 0;

  aboutToDisappear(): void { this.searchGeneration++; }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string> | undefined;
    if (params !== undefined && params['keyword'] !== undefined) {
      this.keyword = params['keyword'];
      this.doSearch();
    }
  }

  private async doSearch(): Promise<void> {
    const kw = this.keyword.trim();
    const api = this.session.api;
    if (kw === '' || api === null) {
      return;
    }
    const generation = ++this.searchGeneration;
    this.searching = true;
    this.statusMsg = '搜索中…';
    this.items = [];
    const fallback: SourceConfig[] = [];
    const direct: SourceConfig[] = [];
    for (const src of this.session.enabledSources()) {
      if (this.session.directCms.shouldTryDirect(src)) { direct.push(src); }
      else { fallback.push(src); }
    }
    const initialFallback = fallback.splice(0, fallback.length);
    const serverTask: Promise<void> = initialFallback.length > 0
      ? api.search(kw, initialFallback).then((r) => {
        if (generation === this.searchGeneration) { this.mergeItems(r.items); }
      }).catch(() => {}) : Promise.resolve();
    let next = 0;
    const run = async (): Promise<void> => {
      while (generation === this.searchGeneration && next < direct.length) {
        const src = direct[next++];
        try {
          const list = await this.session.directCms.search(src, kw);
          if (generation !== this.searchGeneration) { return; }
          this.mergeItems(list);
          this.statusMsg = `搜索中，已找到 ${this.items.length} 条`;
        } catch (e) {
          if (generation === this.searchGeneration) { fallback.push(src); }
        }
      }
    };
    await Promise.all([serverTask, run(), run(), run(), run()]);
    if (generation !== this.searchGeneration) { return; }
    if (fallback.length > 0) {
      try {
        const result = await api.search(kw, fallback);
        if (generation !== this.searchGeneration) { return; }
        this.mergeItems(result.items);
      } catch (e) {
        if (generation !== this.searchGeneration) { return; }
        if (this.items.length === 0) { this.statusMsg = `搜索失败：${(e as Error).message}`; }
      }
    }
    if (generation !== this.searchGeneration) { return; }
    this.searching = false;
    this.session.rememberSearch(kw, this.items);
    if (this.items.length === 0 && !this.statusMsg.startsWith('搜索失败')) {
      this.statusMsg = '没有结果';
    } else if (this.items.length > 0) {
      this.statusMsg = `共 ${this.items.length} 条`;
    }
  }

  private mergeItems(incoming: SearchItem[]): void {
    const seen = new Set<string>();
    for (const it of this.items) {
      seen.add(`${it.sourceUrl}|${it.vodId}`);
    }
    const fresh: SearchItem[] = [];
    for (const it of incoming) {
      const k = `${it.sourceUrl}|${it.vodId}`;
      if (it.vodId !== '' && !seen.has(k)) {
        seen.add(k);
        fresh.push(it);
      }
    }
    this.items = this.items.concat(fresh);
  }

  private goDetail(item: SearchItem): void {
    router.pushUrl({
      url: 'pages/Detail',
      params: {
        sourceUrl: item.sourceUrl,
        vodId: item.vodId,
        title: item.name
      } as RouteParams
    });
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Text('时光影院').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Blank()
        Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Row({ space: 10 }) {
        TextInput({ placeholder: '搜索片名、演员…', text: this.keyword })
          .fontSize(15).height(46).borderRadius(14).layoutWeight(1)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .placeholderColor(Theme.SECONDARY)
          .onChange((v: string) => { this.keyword = v; })
          .onSubmit(() => { this.doSearch(); })
        Button('搜索')
          .fontSize(15).height(46).borderRadius(14)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
          .enabled(!this.searching && this.keyword.trim() !== '')
          .onClick(() => { this.doSearch(); })
      }
      .width('100%').padding({ left: 16, right: 16, bottom: 8 })

      if (this.statusMsg !== '') {
        Text(this.statusMsg).fontSize(13).fontColor(Theme.SECONDARY)
          .width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }

      if (this.items.length === 0 && !this.searching && this.statusMsg === '没有结果') {
        Column() {
          Text('没有找到相关影片，换个关键词试试').fontSize(14).fontColor(Theme.SECONDARY)
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
      } else {
        List({ space: 9 }) {
          ForEach(this.items, (item: SearchItem) => {
            ListItem() {
              Row({ space: 12 }) {
                Image(item.pic !== '' ? item.pic : '')
                  .width(64).height(90).borderRadius(10)
                  .objectFit(ImageFit.Cover)
                  .backgroundColor(Theme.PLACEHOLDER)
                Column({ space: 5 }) {
                  Text(item.name).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text([item.typeName, item.year, item.remarks]
                    .filter((v: string) => v !== '').join(' · '))
                    .fontSize(12).fontColor(Theme.SECONDARY)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(`来源：${item.sourceName}`).fontSize(11).fontColor(Theme.TERTIARY)
                    .maxLines(1)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Text('›').fontSize(24).fontColor(Theme.ACCENT)
              }
              .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
              .onClick(() => { this.goDetail(item); })
            }
          }, (item: SearchItem) => `${item.sourceUrl}|${item.vodId}`)
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
