/**
 * 儿童乐园（对齐 Android v1.3.0–v1.5.2 的儿童专区，手机布局）。
 *
 *   · 三个年龄分区（启蒙时光 / 探索世界 / 欢乐冒险），每个分区横向浏览
 *   · 顶部是今日剩余时间；用完仍可浏览，继续播放要家长加时
 *   · 家长入口走乘法题验证，验证后可改每日额度、仅今天加时、移出手动加入的作品
 *   · 封面先用内置核验清单，没命中交给海报组件的片源兜底
 */

import { RouteParams } from './RouteParams';
import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { ChildrenCatalog, ChildrenSection } from '../api/ChildrenCatalog';
import { ChildrenArtwork } from '../api/ChildrenArtwork';
import { ChildrenQuota, normalizeSeries } from '../store/ChildrenQuota';
import { Prefs } from '../store/Prefs';
import { Session } from '../store/Session';
import { SearchItem } from '../api/Models';
import { PosterImage, retryPosterCache } from '../components/PosterImage';
import { ParentPanel } from '../components/ParentPanel';
import { Theme } from '../common/Theme';

interface KidCard {
  title: string;
  cover: string;
  /** 该片名是否有核验过的封面（没有时显示插画底） */
  hasArt: boolean;
  retryToken: number;
}

interface KidSection {
  age: string;
  title: string;
  cards: KidCard[];
  source: KidCardSource;
}

/**
 * 分区数据源：给 LazyForEach 用。
 * 100 部动画如果一次性全部挂载，每个卡片都会立刻发起一次封面请求，
 * 首屏既卡又慢；改用懒加载后只挂当前可见的几张，滑到哪加载到哪。
 */
class KidCardSource implements IDataSource {
  private cards: KidCard[] = [];
  private listeners: DataChangeListener[] = [];

  setCards(cards: KidCard[]): void {
    this.cards = cards;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.cards.length;
  }

  getData(index: number): KidCard {
    return this.cards[index];
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
struct Children {
  @State sections: KidSection[] = [];
  @State remainingLabel: string = '今日剩余 15 分钟';
  @State usedPercent: number = 0;
  @State exhausted: boolean = false;
  @State dailyMinutes: number = 15;
  @State showParent: boolean = false;
  @State coverPickerTitle: string = '';
  @State coverCandidates: SearchItem[] = [];
  @State coverLoading: boolean = false;
  @State coverMessage: string = '';
  private coverGeneration: number = 0;
  private suppressClickUntil: number = 0;

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;
  private quota: ChildrenQuota | null = null;

  aboutToAppear(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    Prefs.get(ctx).then(async (p: Prefs) => {
      this.prefs = p;
      const quota = await ChildrenQuota.get(p);
      this.quota = quota;
      this.applyQuota();
      // 封面清单解析一次即可，之后每张卡直接查表
      const list: KidSection[] = [];
      for (const section of ChildrenCatalog.sections()) {
        const cards: KidCard[] = [];
        for (const title of section.titles) {
          const cover = p.getRaw(`kidCover:${title}`, '') || ChildrenArtwork.firstUrl(ctx, title);
          cards.push({ title: title, cover: cover, hasArt: cover !== '', retryToken: 0 });
        }
        const source = new KidCardSource();
        source.setCards(cards);
        list.push({ age: section.age, title: section.title, cards: cards, source: source });
      }
      this.sections = list;
    }).catch(() => {});
  }

  onPageShow(): void {
    this.applyQuota();
  }

  private applyQuota(): void {
    const quota = this.quota;
    if (quota === null) {
      return;
    }
    this.remainingLabel = quota.label();
    this.usedPercent = quota.percent();
    this.exhausted = quota.isExhausted();
    this.dailyMinutes = quota.dailyMinutes();
  }

  /** 豆瓣封面有防盗链，走服务端代理；其他图床直连 */
  private proxyOf(url: string): string {
    const api = this.session.api;
    if (api === null || url === '') {
      return '';
    }
    if (url.includes('doubanio.com') || url.includes('douban.com')) {
      return api.imageUrl(url);
    }
    return '';
  }

  private cookie(): string {
    const api = this.session.api;
    return api !== null ? api.currentCookie() : '';
  }

  private openTitle(title: string): void {
    if (Date.now() < this.suppressClickUntil) { return; }
    const params: RouteParams = { 'keyword': title, 'fromChildren': '1' } as RouteParams;
    router.pushUrl({ url: 'pages/Search', params: params }).catch(() => {});
  }

  private updateCover(title: string, url: string): void {
    for (const section of this.sections) {
      const cards = section.cards.map((card: KidCard): KidCard => card.title === title ?
        { title: card.title, cover: url, hasArt: url !== '', retryToken: card.retryToken + 1 } : card);
      section.cards = cards;
      section.source.setCards(cards);
    }
  }

  private async saveCover(title: string, url: string): Promise<void> {
    if (this.prefs === null) { return; }
    try {
      await this.prefs.putRaw(`kidCover:${title}`, url);
      this.updateCover(title, url);
    } catch (e) { promptAction.showToast({ message: '封面保存失败，请重试' }); }
  }

  private async findCovers(title: string): Promise<void> {
    const generation = ++this.coverGeneration;
    this.coverPickerTitle = title;
    this.coverCandidates = [];
    this.coverLoading = true;
    this.coverMessage = '';
    const api = this.session.api;
    if (api === null) { this.coverLoading = false; this.coverMessage = '请先连接服务端'; return; }
    try {
      const result = await api.search(title, this.session.enabledSources());
      if (generation !== this.coverGeneration) { return; }
      const seen: Set<string> = new Set();
      this.coverCandidates = result.items.filter((item: SearchItem) => {
        if (item.pic === '' || seen.has(item.pic)) { return false; }
        seen.add(item.pic);
        return true;
      }).slice(0, 30);
      if (this.coverCandidates.length === 0) { this.coverMessage = '没有找到可用封面'; }
    } catch (e) {
      if (generation === this.coverGeneration) { this.coverMessage = '搜索封面失败，请稍后重试'; }
    } finally { if (generation === this.coverGeneration) { this.coverLoading = false; } }
  }

  private async coverMenu(card: KidCard): Promise<void> {
    this.suppressClickUntil = Date.now() + 1000;
    try {
      const choice = await promptAction.showActionMenu({ title: `《${card.title}》封面`, buttons: [
        { text: '从搜索结果选封面', color: Theme.INK },
        { text: '换一张封面', color: Theme.INK },
        { text: '重试封面加载', color: Theme.INK }
      ] });
      if (choice.index === 0) { this.findCovers(card.title); }
      if (choice.index === 1) {
        const urls = ChildrenArtwork.urls(getContext(this) as common.UIAbilityContext, card.title);
        if (urls.length === 0) { this.findCovers(card.title); return; }
        const next = urls[(urls.indexOf(card.cover) + 1) % urls.length];
        if (next === card.cover) { this.findCovers(card.title); return; }
        this.saveCover(card.title, next);
      }
      if (choice.index === 2) { retryPosterCache(); this.updateCover(card.title, card.cover); }
    } catch (e) { /* Menu dismissed. */ }
  }

  @Builder
  kidCard(card: KidCard) {
    Column({ space: 6 }) {
      Stack() {
        if (card.cover !== '') {
          PosterImage({ url: card.cover, proxy: this.proxyOf(card.cover), cookie: this.cookie(),
            posterHeight: 168, retryToken: card.retryToken })
        } else {
          // 没有核验封面：用片名首字 + 浅绿底做插画兜底，不留“暂无封面”的空白
          Column() {
            Text(card.title.substring(0, 1))
              .fontSize(34).fontWeight(FontWeight.Bold).fontColor(Theme.KID_ACCENT_DEEP)
          }
          .width('100%').height(168).justifyContent(FlexAlign.Center)
          .borderRadius(13).backgroundColor(Theme.KID_TINT)
        }
      }.width('100%').height(168)

      Text(card.title).fontSize(13).fontColor(Theme.KID_INK).maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
    }
    .width(112)
    .gesture(LongPressGesture({ repeat: false }).onAction(() => { this.coverMenu(card); }))
    .onClick(() => { this.openTitle(card.title); })
  }

  @Builder
  sectionRow(section: KidSection) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Text(section.title).fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.KID_INK)
        Text(section.age).fontSize(11).fontColor(Theme.KID_ACCENT_DEEP)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(9).backgroundColor(Theme.KID_TINT)
        Blank()
      }.width('100%')

      List({ space: 12 }) {
        LazyForEach(section.source, (card: KidCard) => {
          ListItem() {
            this.kidCard(card)
          }
        }, (card: KidCard) => card.title)
      }
      .listDirection(Axis.Horizontal)
      .cachedCount(4)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(212)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 10 }) {
          Text('‹').fontSize(22).fontColor(Theme.KID_INK).padding({ left: 4, right: 8 })
            .onClick(() => { router.back(); })
          Text('儿童乐园').fontSize(19).fontWeight(FontWeight.Bold).fontColor(Theme.KID_INK)
          Blank()
          Text(this.remainingLabel).fontSize(11)
            .fontColor(this.exhausted ? Theme.DANGER : Theme.KID_ACCENT_DEEP)
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .borderRadius(11).backgroundColor(Theme.KID_TINT)
            .onClick(() => { this.showParent = true; })
        }.width('100%').padding({ left: 16, right: 16, top: 10, bottom: 6 })

        Scroll() {
          Column({ space: 18 }) {
            // 额度卡
            Column({ space: 10 }) {
              Row() {
                Text(this.remainingLabel).fontSize(16).fontWeight(FontWeight.Bold)
                  .fontColor(this.exhausted ? Theme.DANGER : Theme.KID_INK).layoutWeight(1)
                Text(`每日 ${this.dailyMinutes} 分钟`).fontSize(11).fontColor(Theme.KID_SECONDARY)
              }.width('100%')
              Progress({ value: this.usedPercent, total: 100 }).width('100%').height(8)
                .color(this.exhausted ? Theme.DANGER : Theme.KID_BAR_USED)
                .backgroundColor(Theme.KID_TINT)
              Row() {
                Text(this.exhausted
                  ? '今天的时间用完了，明天恢复；家长可以临时加时'
                  : '只统计正在播放的时间，浏览和暂停不计时')
                  .fontSize(11).fontColor(Theme.KID_SECONDARY).layoutWeight(1).maxLines(2)
                Button('家长设置').fontSize(12).height(34).borderRadius(17)
                  .backgroundColor(Theme.KID_ACCENT).fontColor(Theme.ON_ACCENT)
                  .onClick(() => { this.showParent = true; })
              }.width('100%')
            }
            .width('100%').padding(16).borderRadius(18).backgroundColor('#FFFFFF')
            .border({ width: 1, color: Theme.KID_BORDER })

            if (this.sections.length === 0) {
              Text('正在准备内容…').fontSize(13).fontColor(Theme.KID_SECONDARY).width('100%')
            } else {
              ForEach(this.sections, (section: KidSection) => {
                this.sectionRow(section)
              }, (section: KidSection) => section.title)
            }

            Text('清单是人工挑过的适龄动画，点进去按片名搜索全部分片源；年龄标签只是建议。')
              .fontSize(11).fontColor(Theme.KID_SECONDARY).width('100%').margin({ bottom: 24 })
          }
          .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 20 })
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Off)
      }
      .width('100%').height('100%')
      .backgroundColor(Theme.KID_BG)

      if (this.showParent) {
        // 遮罩与面板做成兄弟节点：点遮罩关闭，点面板不会冒泡到遮罩。
        // 面板必须用 Default —— Block 会把子节点一起屏蔽，家长键盘就点不动了。
        Stack({ alignContent: Alignment.Bottom }) {
          Column()
            .width('100%').height('100%')
            .backgroundColor('#66000000')
            .onClick(() => { this.showParent = false; })
          Column() {
            ParentPanel({
              quotaRef: this.quota,
              onClose: () => { this.showParent = false; },
              onChanged: () => { this.applyQuota(); }
            })
          }
          .width('100%')
          .padding(16)
          .hitTestBehavior(HitTestMode.Default)
        }
        .width('100%').height('100%')
      }
      if (this.coverPickerTitle !== '') {
        Stack({ alignContent: Alignment.Center }) {
          Column().width('100%').height('100%').backgroundColor('#66000000')
            .onClick(() => { this.coverGeneration++; this.coverPickerTitle = ''; })
          Column({ space: 12 }) {
            Row() {
              Text(`选择《${this.coverPickerTitle}》封面`).fontSize(17).fontWeight(FontWeight.Bold)
                .fontColor(Theme.KID_INK).layoutWeight(1).maxLines(2)
              Text('关闭').fontSize(14).fontColor(Theme.ACCENT).padding(8)
                .onClick(() => { this.coverGeneration++; this.coverPickerTitle = ''; })
            }.width('100%')
            if (this.coverLoading) { Text('正在搜索封面…').fontColor(Theme.KID_SECONDARY) }
            if (this.coverMessage !== '') { Text(this.coverMessage).fontColor(Theme.KID_SECONDARY) }
            List({ space: 8 }) {
              ForEach(this.coverCandidates, (item: SearchItem) => {
                ListItem() {
                  Row({ space: 12 }) {
                    PosterImage({ url: item.pic, proxy: this.proxyOf(item.pic), cookie: this.cookie(), posterHeight: 90 })
                      .width(60).height(90)
                    Column({ space: 4 }) {
                      Text(item.name).fontSize(14).fontColor(Theme.KID_INK).maxLines(2)
                      Text(item.sourceName).fontSize(12).fontColor(Theme.KID_SECONDARY).maxLines(1)
                    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  }.width('100%').onClick(() => {
                    const title = this.coverPickerTitle;
                    this.coverGeneration++;
                    this.coverPickerTitle = '';
                    this.saveCover(title, item.pic);
                  })
                }
              }, (item: SearchItem) => item.pic)
            }.width('100%').layoutWeight(1).scrollBar(BarState.Auto)
          }.width('90%').height('70%').padding(16).borderRadius(18).backgroundColor(Theme.PANEL)
        }.width('100%').height('100%')
      }
    }
    .width('100%').height('100%')
  }
}
