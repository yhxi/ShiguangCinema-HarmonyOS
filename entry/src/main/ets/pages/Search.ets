import { RouteParams } from './RouteParams';
/**
 * 搜索页 —— 服务端聚合搜索 + 直连源并行加速（失败回退服务端）。
 *
 * v1.5.5 对齐 Android 版之后的行为：
 *   · 结果按片名分组：21 个源里同一部片只出现一次，卡片上标「N 个源」，
 *     点开默认用最健康的那个源，长按可以换采集站
 *   · 完全同名的片名排在前面；先到的一批不会被后到的结果打乱顺序
 *   · 一次都没搜到时，用去掉括号注记的干净片名再试一轮（采集站对噪声很敏感）
 *   · 输入框有拼音首字母联想，空输入时给最近搜索
 */

import { router } from '@kit.ArkUI';
import { SearchItem, SourceConfig } from '../api/Models';
import { Session } from '../store/Session';
import { Prefs } from '../store/Prefs';
import { SourceHealth, HealthRecord } from '../store/SourceHealth';
import { PinyinInitials } from '../api/PinyinInitials';
import { cleanKeyword, matchesInitials, searchTitleRank } from '../common/TextClean';
import { PosterImage } from '../components/PosterImage';
import { Theme } from '../common/Theme';

interface SearchGroup {
  /** 展示用片名 */
  title: string;
  /** 同一部片名在各采集站的条目，第一个是默认打开的那个 */
  items: SearchItem[];
}

interface Suggestion {
  label: string;
  hint: string;
}

/** 选源排序用：条目 + 健康权重 + 原始下标 */
interface ScoredItem {
  item: SearchItem;
  weight: number;
  idx: number;
}

/** 联想池里的一项：片名 + 来源说明 + 拼音首字母（懒算） */
interface PoolEntry {
  label: string;
  hint: string;
  initials: string;
}

class SearchGroupSource implements IDataSource {
  private groups: SearchGroup[] = [];
  private listeners: DataChangeListener[] = [];

  setGroups(groups: SearchGroup[]): void {
    this.groups = groups;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.groups.length;
  }

  getData(index: number): SearchGroup {
    return this.groups[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }
}

@Entry
@Component
struct SearchPage {
  @State keyword: string = '';
  @State searching: boolean = false;
  @State statusMsg: string = '';
  @State groups: SearchGroup[] = [];
  /** 来源：fromChildren 从儿童乐园来 / fromPlayer 是播放页换源 */
  @State origin: string = '';
  @State history: string[] = [];
  @State suggestions: Suggestion[] = [];
  /** 选源浮层：非空时显示 */
  @State pickerTitle: string = '';
  @State pickerItems: SearchItem[] = [];

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;
  private source: SearchGroupSource = new SearchGroupSource();
  private searchGeneration: number = 0;
  /** 已经搜过的关键词：输入框内容与它不同才给联想，避免结果页被联想条顶掉 */
  private searchedKeyword: string = '';
  private pool: PoolEntry[] = [];
  private health: Map<string, HealthRecord> = new Map();

  aboutToDisappear(): void { this.searchGeneration++; }

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string> | undefined;
    if (params !== undefined && params['fromChildren'] === '1') {
      this.origin = 'children';
    } else if (params !== undefined && params['fromPlayer'] === '1') {
      this.origin = 'player';
    }
    Prefs.get(getContext(this)).then(async (p: Prefs) => {
      this.prefs = p;
      this.health = SourceHealth.load(p);
      this.history = p.getSearchHistory();
      await this.buildPool();
      if (params !== undefined && params['keyword'] !== undefined) {
        this.keyword = params['keyword'];
        // 先把关键词记成"已搜"，缓存结果才会按匹配权重排而不是按字母排
        this.searchedKeyword = this.keyword.trim();
        // 同一个关键词刚刚搜过：先把结果铺上去，再后台刷新，避免整页空白等全源扫描
        const cached = this.session.cachedSearch(this.keyword);
        if (cached.length > 0) {
          this.applyIncoming(cached);
          this.statusMsg = `共 ${this.groups.length} 部 · 上次结果，正在刷新`;
        }
        this.doSearch(cached.length > 0);
      }
    }).catch(() => {});
  }

  /** 联想池：最近搜索 + 收藏 + 看过的，够覆盖日常片名，不必联网 */
  private async buildPool(): Promise<void> {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    const seen: Set<string> = new Set();
    const out: PoolEntry[] = [];
    const add = (label: string, hint: string): void => {
      const v = label.trim();
      if (v === '' || seen.has(v)) {
        return;
      }
      seen.add(v);
      out.push({ label: v, hint: hint, initials: PinyinInitials.initialsOf(v) });
    };
    for (const kw of this.history) {
      add(kw, '最近搜索');
    }
    const favorites = await p.getFavorites();
    for (const e of favorites) {
      add(e.title, '收藏');
    }
    const watch = await p.getHistory();
    for (let i = 0; i < watch.length && i < 40; i++) {
      add(watch[i].title, '看过的');
    }
    this.pool = out;
    this.refreshSuggestions();
  }

  /** 输入联想：片名包含关键词，或拼音首字母命中（「cjqc」→《超级汽车》） */
  private refreshSuggestions(): void {
    const q = this.keyword.trim().toLowerCase();
    if (q === '' || q === this.searchedKeyword) {
      this.suggestions = [];
      return;
    }
    const out: Suggestion[] = [];
    for (const entry of this.pool) {
      const hit = entry.label.toLowerCase().indexOf(q) >= 0 || matchesInitials(entry.initials, q);
      if (hit) {
        out.push({ label: entry.label, hint: entry.hint });
        if (out.length >= 6) {
          break;
        }
      }
    }
    this.suggestions = out;
  }

  private async doSearch(keepExisting: boolean = false): Promise<void> {
    const kw = this.keyword.trim();
    const api = this.session.api;
    if (kw === '' || api === null) {
      return;
    }
    const generation = ++this.searchGeneration;
    this.searching = true;
    this.searchedKeyword = kw;
    this.suggestions = [];
    if (!keepExisting) {
      this.statusMsg = '搜索中…';
      this.setGroups([]);
    }
    if (this.prefs !== null) {
      this.prefs.addSearchHistory(kw).then(() => {
        if (this.prefs !== null) {
          this.history = this.prefs.getSearchHistory();
        }
      }).catch(() => {});
    }
    await this.runSearch(kw, generation);
    if (generation !== this.searchGeneration) {
      return;
    }
    // 一条都没搜到：把「（2023）」「：副标题」这类噪声去掉再试一次
    if (this.groups.length === 0) {
      const cleaned = cleanKeyword(kw);
      if (cleaned !== '' && cleaned !== kw) {
        this.statusMsg = `没搜到，改用「${cleaned}」再试…`;
        await this.runSearch(cleaned, generation);
        if (generation !== this.searchGeneration) {
          return;
        }
      }
    }
    this.searching = false;
    const flat: SearchItem[] = [];
    for (const g of this.groups) {
      for (const it of g.items) {
        flat.push(it);
      }
    }
    this.session.rememberSearch(kw, flat);
    if (this.groups.length === 0 && !this.statusMsg.startsWith('搜索失败')) {
      this.statusMsg = '没有结果';
    } else if (this.groups.length > 0) {
      this.statusMsg = `${this.groups.length} 部 · ${flat.length} 条来源`;
    }
    this.refreshSuggestions();
  }

  /** 直连源并发跑，剩下的交给服务端一次性聚合 */
  private async runSearch(kw: string, generation: number): Promise<void> {
    const api = this.session.api;
    if (api === null) {
      return;
    }
    const fallback: SourceConfig[] = [];
    const direct: SourceConfig[] = [];
    for (const src of this.session.enabledSources()) {
      if (this.session.directCms.shouldTryDirect(src)) { direct.push(src); }
      else { fallback.push(src); }
    }
    const serverTask: Promise<void> = fallback.length > 0
      ? api.search(kw, fallback).then((r) => {
        if (generation === this.searchGeneration) { this.applyIncoming(r.items); }
      }).catch(() => {}) : Promise.resolve();
    let next = 0;
    const run = async (): Promise<void> => {
      while (generation === this.searchGeneration && next < direct.length) {
        const src = direct[next++];
        try {
          const list = await this.session.directCms.search(src, kw);
          if (generation !== this.searchGeneration) { return; }
          this.applyIncoming(list);
          this.statusMsg = `搜索中，已找到 ${this.groups.length} 部`;
        } catch (e) {
          if (generation === this.searchGeneration) { fallback.push(src); }
        }
      }
    };
    await Promise.all([serverTask, run(), run(), run(), run(), run()]);
    if (generation !== this.searchGeneration) {
      return;
    }
    if (fallback.length > 0) {
      try {
        const result = await api.search(kw, fallback);
        if (generation !== this.searchGeneration) { return; }
        this.applyIncoming(result.items);
      } catch (e) {
        if (generation !== this.searchGeneration) { return; }
        if (this.groups.length === 0) { this.statusMsg = `搜索失败：${(e as Error).message}`; }
      }
    }
  }

  /**
   * 合并一批结果：已有的片名保持原位，新片名按匹配权重插在后面。
   * 先到的一批不会因为后到的结果被重新洗牌，用户正在点的那一行不会跳走。
   */
  private applyIncoming(incoming: SearchItem[]): void {
    const prevTitles: string[] = [];
    const bucket: Map<string, SearchItem[]> = new Map();
    for (const g of this.groups) {
      prevTitles.push(g.title);
      bucket.set(g.title, g.items.slice(0));
    }
    for (const it of incoming) {
      if (it.vodId === '' || it.name === '') {
        continue;
      }
      let list = bucket.get(it.name);
      if (list === undefined) {
        list = [];
        bucket.set(it.name, list);
      }
      let dup = false;
      for (const e of list) {
        if (e.sourceUrl === it.sourceUrl && e.vodId === it.vodId) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        list.push(it);
      }
    }
    const prevIndex: Map<string, number> = new Map();
    for (let i = 0; i < prevTitles.length; i++) {
      prevIndex.set(prevTitles[i], i);
    }
    const titles: string[] = Array.from(bucket.keys());
    titles.sort((a: string, b: string): number => {
      const ai = prevIndex.has(a) ? prevIndex.get(a) as number : Number.MAX_SAFE_INTEGER;
      const bi = prevIndex.has(b) ? prevIndex.get(b) as number : Number.MAX_SAFE_INTEGER;
      if (ai !== bi) {
        return ai - bi;
      }
      const ra = searchTitleRank(a, this.searchedKeyword);
      const rb = searchTitleRank(b, this.searchedKeyword);
      if (ra !== rb) {
        return ra - rb;
      }
      return a.localeCompare(b);
    });
    const groups: SearchGroup[] = [];
    for (const title of titles) {
      const items = bucket.get(title);
      if (items === undefined || items.length === 0) {
        continue;
      }
      const group: SearchGroup = { title: title, items: this.sortByHealth(items) };
      groups.push(group);
    }
    this.setGroups(groups);
  }

  /** 同一个片名里，上次测过不能用的源往后排，免得默认打开的是个死源 */
  private sortByHealth(items: SearchItem[]): SearchItem[] {
    const scored: ScoredItem[] = items.map((it: SearchItem, idx: number): ScoredItem => {
      const record = this.health.get(it.sourceUrl);
      const weight = record === undefined ? 1 : (record.ok ? 0 : 2);
      const entry: ScoredItem = { item: it, weight: weight, idx: idx };
      return entry;
    });
    scored.sort((a: ScoredItem, b: ScoredItem): number => {
      if (a.weight !== b.weight) {
        return a.weight - b.weight;
      }
      return a.idx - b.idx;
    });
    return scored.map((s: ScoredItem) => s.item);
  }

  private setGroups(groups: SearchGroup[]): void {
    this.groups = groups;
    this.source.setGroups(groups);
  }

  /** 豆瓣图走服务端代理，图床直连 */
  private posterProxy(pic: string): string {
    const api = this.session.api;
    if (api === null || pic === '') {
      return '';
    }
    if (pic.includes('doubanio.com') || pic.includes('douban.com')) {
      return api.imageUrl(pic);
    }
    return '';
  }

  private goDetail(item: SearchItem): void {
    this.pickerTitle = '';
    this.pickerItems = [];
    router.pushUrl({
      url: 'pages/Detail',
      params: {
        sourceUrl: item.sourceUrl,
        vodId: item.vodId,
        title: item.name
      } as RouteParams
    });
  }

  private openGroup(g: SearchGroup): void {
    if (g.items.length === 0) {
      return;
    }
    this.goDetail(g.items[0]);
  }

  private showPicker(g: SearchGroup): void {
    if (g.items.length <= 1) {
      this.goDetail(g.items[0]);
      return;
    }
    this.pickerTitle = g.title;
    this.pickerItems = g.items;
  }

  /** 源的名字：搜索条目里带的 sourceName，没有就用域名兜底 */
  private sourceLabel(item: SearchItem): string {
    if (item.sourceName !== '') {
      return item.sourceName;
    }
    const host = item.sourceUrl.replace(/^https?:\/\//, '').split('/')[0];
    return host !== '' ? host : '未知来源';
  }

  private healthLabel(url: string): string {
    const record = this.health.get(url);
    if (record === undefined) {
      return '未检测';
    }
    return record.ok ? `可用 ${record.ms}ms` : '上次不可用';
  }

  private pickSuggestion(s: Suggestion): void {
    this.keyword = s.label;
    this.suggestions = [];
    this.doSearch();
  }

  private useHistory(kw: string): void {
    this.keyword = kw;
    this.suggestions = [];
    this.doSearch();
  }

  private searchSourceCount(): string {
    const n = this.session.enabledSources().length;
    return n > 0 ? `已启用 ${n} 个片源` : '';
  }

  @Builder
  suggestionBar() {
    Column({ space: 6 }) {
      ForEach(this.suggestions, (s: Suggestion) => {
        Row({ space: 8 }) {
          Text('⌕').fontSize(13).fontColor(Theme.ACCENT)
          Text(s.label).fontSize(14).fontColor(Theme.INK).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(s.hint).fontSize(11).fontColor(Theme.TERTIARY)
        }
        .width('100%').padding({ left: 12, right: 12, top: 9, bottom: 9 })
        .borderRadius(10).backgroundColor(Theme.PANEL)
        .onClick(() => { this.pickSuggestion(s); })
      }, (s: Suggestion) => s.label)
    }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  historyBar() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        Text('最近搜索').fontSize(13).fontColor(Theme.SECONDARY).layoutWeight(1)
        Text('清空').fontSize(12).fontColor(Theme.TERTIARY)
          .onClick(() => {
            const p = this.prefs;
            if (p !== null) {
              p.clearSearchHistory().then(() => { this.history = []; }).catch(() => {});
            }
          })
      }.width('100%')
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(this.history, (kw: string) => {
          Text(kw).fontSize(13).fontColor(Theme.INK)
            .padding({ left: 12, right: 12, top: 7, bottom: 7 })
            .margin(3).borderRadius(14).backgroundColor(Theme.PANEL)
            .onClick(() => { this.useHistory(kw); })
        }, (kw: string) => kw)
      }.width('100%')
    }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  resultCard(g: SearchGroup) {
    Row({ space: 10 }) {
      Row({ space: 12 }) {
        Stack() {
          PosterImage({ url: g.items[0].pic, proxy: this.posterProxy(g.items[0].pic),
            cookie: this.session.api !== null ? this.session.api.currentCookie() : '',
            posterHeight: 90 })
        }.width(64).height(90)
        Column({ space: 5 }) {
          Text(g.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text([g.items[0].typeName, g.items[0].year, g.items[0].remarks]
            .filter((v: string) => v !== '').join(' · '))
            .fontSize(12).fontColor(Theme.SECONDARY)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${g.items.length > 1 ? `${g.items.length} 个源` : this.sourceLabel(g.items[0])}` +
            ` · ${this.healthLabel(g.items[0].sourceUrl)}`)
            .fontSize(11).fontColor(Theme.TERTIARY).maxLines(1)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .layoutWeight(1)
      .onClick(() => { this.openGroup(g); })

      if (g.items.length > 1) {
        // 多源时给一个明确的入口，不靠长按 discover
        Text('换源').fontSize(12).fontColor(Theme.ACCENT)
          .padding({ left: 10, right: 10, top: 7, bottom: 7 })
          .borderRadius(12).backgroundColor(Theme.TINT)
          .onClick(() => { this.showPicker(g); })
      } else {
        Text('›').fontSize(24).fontColor(Theme.ACCENT)
          .onClick(() => { this.openGroup(g); })
      }
    }
    .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
  }

  @Builder
  pickerSheet() {
    Column() {
      Blank()
      Column({ space: 8 }) {
        Row() {
          Text(`《${this.pickerTitle}》`).fontSize(16).fontWeight(FontWeight.Bold)
            .fontColor(Theme.INK).layoutWeight(1)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text('选择采集站').fontSize(12).fontColor(Theme.SECONDARY)
        }.width('100%').padding({ bottom: 4 })
        List({ space: 6 }) {
          ForEach(this.pickerItems, (item: SearchItem, idx: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Text(`${idx + 1}`).fontSize(12).fontColor(Theme.TERTIARY).width(18)
                Column({ space: 3 }) {
                  Text(this.sourceLabel(item)).fontSize(15).fontColor(Theme.INK)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.healthLabel(item.sourceUrl)).fontSize(11).fontColor(Theme.SECONDARY)
                }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                Text('›').fontSize(20).fontColor(Theme.ACCENT)
              }
              .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .borderRadius(12).backgroundColor(Theme.BG)
              .onClick(() => { this.goDetail(item); })
            }
          }, (item: SearchItem) => `${item.sourceUrl}|${item.vodId}`)
        }
        .width('100%').height(320).scrollBar(BarState.Off)
        Button('取消').fontSize(15).height(44).width('100%').borderRadius(22)
          .backgroundColor(Theme.BG).fontColor(Theme.INK)
          .onClick(() => { this.pickerTitle = ''; this.pickerItems = []; })
      }
      .width('100%').padding(16)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor(Theme.PANEL)
      .hitTestBehavior(HitTestMode.Block)
    }
    .width('100%').height('100%')
    .justifyContent(FlexAlign.End)
    .backgroundColor('#66000000')
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 10 }) {
          Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
            .width(26).height(26).textAlign(TextAlign.Center)
            .borderRadius(8).backgroundColor(Theme.ACCENT)
          Text('时光影院').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          Blank()
          Button(this.origin === 'children' ? '‹ 儿童乐园' : '‹ 返回').fontSize(13).height(34).borderRadius(17)
            .backgroundColor(this.origin === 'children' ? Theme.KID_TINT : Theme.PANEL)
            .fontColor(this.origin === 'children' ? Theme.KID_ACCENT_DEEP : Theme.INK)
            .onClick(() => { router.back(); })
        }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

        if (this.origin !== '') {
          Text(this.origin === 'children'
            ? '儿童乐园 · 从下面挑一个能播的片源，播放时间会记入今天的儿童额度'
            : '换源 · 同一个片名换个片源再试，进度会从上次的位置继续')
            .fontSize(11).fontColor(Theme.SECONDARY)
            .width('100%').padding({ left: 16, right: 16, bottom: 8 })
        }

        Row({ space: 10 }) {
          TextInput({ placeholder: '搜索片名，也支持拼音首字母', text: this.keyword })
            .fontSize(15).height(46).borderRadius(14).layoutWeight(1)
            .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
            .placeholderColor(Theme.SECONDARY)
            .onChange((v: string) => {
              this.keyword = v;
              this.refreshSuggestions();
            })
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

        if (this.suggestions.length > 0) {
          this.suggestionBar()
        } else if (this.keyword.trim() === '' && this.history.length > 0 && this.groups.length === 0) {
          this.historyBar()
        }

        if (this.groups.length === 0 && !this.searching && this.statusMsg === '没有结果') {
          Column({ space: 6 }) {
            Text('没有找到相关影片，换个关键词试试').fontSize(14).fontColor(Theme.SECONDARY)
            if (this.searchSourceCount() !== '') {
              Text(this.searchSourceCount()).fontSize(12).fontColor(Theme.TERTIARY)
            }
          }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
        } else if (this.groups.length === 0 && this.keyword.trim() === '' && this.history.length === 0) {
          Column({ space: 6 }) {
            Text('搜片名，或者打拼音首字母').fontSize(14).fontColor(Theme.SECONDARY)
            Text('例如「cjqc」可以找到《超级汽车》').fontSize(12).fontColor(Theme.TERTIARY)
          }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
        } else {
          List({ space: 9 }) {
            LazyForEach(this.source, (g: SearchGroup) => {
              ListItem() {
                this.resultCard(g)
              }
            }, (g: SearchGroup) => g.title)
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

      if (this.pickerTitle !== '') {
        this.pickerSheet()
      }
    }
    .width('100%').height('100%')
  }
}
