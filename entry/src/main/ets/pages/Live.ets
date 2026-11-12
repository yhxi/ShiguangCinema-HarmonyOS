/**
 * 直播页（对齐 Android v1.3.16 / v1.3.17 / v1.5.2）。
 *
 *   · 频道来源优先用本地导入的列表（应用内部保存），没有才用服务端 / 内置订阅
 *   · 导入支持系统文件选择器选 M3U / TXT，也支持直接粘贴文本或 HTTP 订阅地址
 *   · 排序统一：央视编号 → 地方台 → 其他；收藏的频道单独置顶
 *   · 点频道进入独立的全屏直播播放器（不分集、不写点播历史）
 */

import { RouteParams } from './RouteParams';
import { router, promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Channel } from '../api/Models';
import { Api, BUILT_IN_LIVE_SOURCES, liveSourceLabel } from '../api/Api';
import { Prefs } from '../store/Prefs';
import { LiveLocal } from '../store/LiveLocal';
import { liveChannelKey, sortedLiveChannels } from '../api/LivePlaylist';
import { Theme } from '../common/Theme';
import { Session } from '../store/Session';

interface ChannelGroup {
  group: string;
  channels: Channel[];
}

const MAX_IMPORT_BYTES = 4 * 1024 * 1024;

@Entry
@Component
struct Live {
  @State groups: ChannelGroup[] = [];
  @State filtered: ChannelGroup[] = [];
  @State filterText: string = '';
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State sourceLabel: string = '';
  @State usingLocal: boolean = false;
  @State channelCount: number = 0;
  @State importReport: string = '';
  @State showPaste: boolean = false;
  @State pasteText: string = '';
  @State favoriteCount: number = 0;

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;
  private channels: Channel[] = [];
  private favorites: Set<string> = new Set();

  aboutToAppear(): void {
    Prefs.get(getContext(this)).then(async (p: Prefs) => {
      this.prefs = p;
      this.favorites = LiveLocal.favorites(p);
      this.favoriteCount = this.favorites.size;
      await this.loadChannels();
    }).catch(() => {});
  }

  private async currentLiveUrl(): Promise<string> {
    if (this.prefs === null || this.session.serverUrl === '') {
      return BUILT_IN_LIVE_SOURCES[0];
    }
    let list = await this.prefs.getLiveSources(this.session.serverUrl);
    if (list.length === 0) {
      list = BUILT_IN_LIVE_SOURCES;
      await this.prefs.setLiveSources(this.session.serverUrl, list, 0);
    }
    let idx = await this.prefs.getSelectedLiveIndex(this.session.serverUrl);
    if (idx < 0 || idx >= list.length) {
      idx = 0;
    }
    return list[idx];
  }

  private async loadChannels(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    const local = LiveLocal.load(this.prefs);
    if (local.length > 0) {
      this.channels = local;
      this.usingLocal = true;
      this.sourceLabel = `本地导入 · ${local.length} 个频道`;
      this.regroup();
      return;
    }
    this.usingLocal = false;
    const api = this.session.api;
    if (api === null) {
      this.errorMsg = '请先在首页连接服务端，或导入本地频道列表';
      return;
    }
    const url = await this.currentLiveUrl();
    this.sourceLabel = liveSourceLabel(url);
    this.loading = true;
    this.errorMsg = '';
    try {
      const list = await api.liveChannels(url);
      this.channels = sortedLiveChannels(list);
      this.regroup();
    } catch (e) {
      this.errorMsg = `拉取频道失败：${(e as Error).message}。也可以直接导入本地列表。`;
    } finally {
      this.loading = false;
    }
  }

  /** 收藏的频道单独成组置顶，其余按原分组顺序 */
  private regroup(): void {
    const kw = this.filterText.trim().toLowerCase();
    const favChannels: Channel[] = [];
    const byGroup: Map<string, Channel[]> = new Map();
    for (const ch of this.channels) {
      if (kw !== '' && !ch.name.toLowerCase().includes(kw) && !ch.group.toLowerCase().includes(kw)) {
        continue;
      }
      if (this.favorites.has(liveChannelKey(ch.name))) {
        favChannels.push(ch);
        continue;
      }
      let list = byGroup.get(ch.group);
      if (list === undefined) {
        list = [];
        byGroup.set(ch.group, list);
      }
      list.push(ch);
    }
    const groups: ChannelGroup[] = [];
    if (favChannels.length > 0) {
      groups.push({ group: '★ 收藏', channels: favChannels });
    }
    byGroup.forEach((v: Channel[], k: string) => {
      groups.push({ group: k, channels: v });
    });
    groups.sort((a: ChannelGroup, b: ChannelGroup) => {
      if (a.group.startsWith('★')) { return -1; }
      if (b.group.startsWith('★')) { return 1; }
      if (a.channels.length !== b.channels.length) {
        return b.channels.length - a.channels.length;
      }
      return a.group.localeCompare(b.group);
    });
    this.filtered = groups;
    this.channelCount = this.channels.length;
  }

  /** 传给播放器的完整频道表（顺序与页面一致，保证上下台连续） */
  private flatten(): Channel[] {
    const out: Channel[] = [];
    for (const g of this.filtered) {
      for (const ch of g.channels) {
        out.push(ch);
      }
    }
    return out;
  }

  private playAt(channel: Channel): void {
    const all = this.flatten();
    let idx = 0;
    for (let i = 0; i < all.length; i++) {
      if (all[i].url === channel.url && all[i].name === channel.name) {
        idx = i;
        break;
      }
    }
    this.startPlayer(all, idx);
  }

  private startPlayer(all: Channel[], index: number): void {
    if (all.length === 0) {
      promptAction.showToast({ message: '没有可播放的频道' });
      return;
    }
    const params: RouteParams = {
      'channelUrls': JSON.stringify(all.map((c: Channel) => c.url)),
      'channelNames': JSON.stringify(all.map((c: Channel) => c.name)),
      'channelHeaders': JSON.stringify(all.map((c: Channel) => c.headers !== undefined ? c.headers : '')),
      'channelIndex': index.toString()
    } as RouteParams;
    router.pushUrl({ url: 'pages/LivePlayer', params: params }).catch(() => {
      promptAction.showToast({ message: '无法打开直播播放器' });
    });
  }

  /** 选文件导入：读 4MB 以内，先按 UTF-8，出现替换字符再按 GB18030 重试 */
  private async importFromFile(): Promise<void> {
    try {
      const documentPicker = new picker.DocumentViewPicker(getContext(this));
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.m3u', '.m3u8', '.txt'];
      const uris = await documentPicker.select(options);
      if (uris === undefined || uris.length === 0) {
        return;
      }
      const file = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
      try {
        const stat = fs.statSync(file.fd);
        if (stat.size > MAX_IMPORT_BYTES) {
          promptAction.showToast({ message: '文件超过 4MB，请先精简频道列表' });
          return;
        }
        const buffer = new ArrayBuffer(stat.size);
        fs.readSync(file.fd, buffer);
        const bytes = new Uint8Array(buffer);
        let text = util.TextDecoder.create('utf-8').decodeToString(bytes);
        if (text.includes('\uFFFD')) {
          try {
            text = util.TextDecoder.create('gb18030').decodeToString(bytes);
          } catch (e) {
            // 解码器不支持 GB18030 时保留 UTF-8 结果
          }
        }
        await this.applyImport(text);
      } finally {
        fs.closeSync(file);
      }
    } catch (e) {
      promptAction.showToast({ message: `导入失败：${(e as Error).message}` });
    }
  }

  private async applyImport(text: string): Promise<void> {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    const report = await LiveLocal.importText(p, text);
    if (report.channels.length === 0) {
      this.importReport = '没有解析到可用频道，请确认文件是 M3U 或「频道名,地址」格式';
      this.showPaste = true;
      return;
    }
    let msg = `已导入 ${report.channels.length} 个频道`;
    if (report.skipped > 0) { msg += `，跳过 ${report.skipped} 行`; }
    if (report.unsupportedDirectives > 0) { msg += `，${report.unsupportedDirectives} 条不支持的指令已忽略`; }
    this.importReport = msg;
    promptAction.showToast({ message: msg, duration: 2600 });
    await this.loadChannels();
  }

  private async importFromText(): Promise<void> {
    const text = this.pasteText.trim();
    if (text === '') {
      return;
    }
    this.showPaste = false;
    this.pasteText = '';
    await this.applyImport(text);
  }

  private playFirstChannel(): void {
    const all = this.flatten();
    if (all.length === 0) {
      return;
    }
    this.startPlayer(all, 0);
  }

  private toggleFavorite(ch: Channel): void {
    const p = this.prefs;
    if (p === null) {
      return;
    }
    LiveLocal.toggleFavorite(p, liveChannelKey(ch.name)).then((added: boolean) => {
      this.favorites = LiveLocal.favorites(p);
      this.favoriteCount = this.favorites.size;
      this.regroup();
      promptAction.showToast({ message: added ? `已收藏 ${ch.name}` : `已取消收藏 ${ch.name}` });
    }).catch(() => {});
  }

  build() {
    Stack() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Column({ space: 2 }) {
          Text('电视直播').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          if (this.sourceLabel !== '') {
            Text(this.sourceLabel).fontSize(10).fontColor(Theme.TERTIARY).maxLines(1)
          }
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Text('‹ 返回').fontSize(13).fontColor(Theme.INK).padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Row({ space: 8 }) {
        Button('导入列表').fontSize(12).height(34).borderRadius(17)
          .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
          .onClick(() => { this.importFromFile(); })
        Button('粘贴导入').fontSize(12).height(34).borderRadius(17)
          .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
          .onClick(() => { this.showPaste = true; })
        Button('换源').fontSize(12).height(34).borderRadius(17)
          .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
          .onClick(() => { router.pushUrl({ url: 'pages/SourceManage' }); })
        Blank()
        if (this.channelCount > 0) {
          Button('立即播放 CCTV1').fontSize(12).height(34).borderRadius(17)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.playFirstChannel(); })
        }
      }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

      TextInput({ placeholder: '过滤频道 / 分组…', text: this.filterText })
        .fontSize(15).height(44).borderRadius(14)
        .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
        .placeholderColor(Theme.SECONDARY)
        .margin({ left: 16, right: 16, bottom: 8 })
        .onChange((v: string) => {
          this.filterText = v;
          this.regroup();
        })

      if (this.importReport !== '') {
        Text(this.importReport).fontSize(11).fontColor(Theme.SECONDARY)
          .width('100%').padding({ left: 16, right: 16, bottom: 6 })
      }

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color(Theme.ACCENT)
          Text('拉取频道列表中…').fontSize(13).fontColor(Theme.SECONDARY)
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
      } else if (this.errorMsg !== '' && this.channels.length === 0) {
        Column({ space: 14 }) {
          Text(this.errorMsg).fontSize(14).fontColor(Theme.DANGER).textAlign(TextAlign.Center)
          Row({ space: 10 }) {
            Button('重试').fontSize(15).height(42).borderRadius(21)
              .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
              .onClick(() => { this.errorMsg = ''; this.loadChannels(); })
            Button('导入列表').fontSize(15).height(42).borderRadius(21)
              .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
              .onClick(() => { this.importFromFile(); })
          }
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%').padding(24)
      } else {
        List({ space: 10 }) {
          ForEach(this.filtered, (g: ChannelGroup) => {
            ListItem() {
              Column({ space: 8 }) {
                Text(`${g.group} · ${g.channels.length}`)
                  .fontSize(14).fontWeight(FontWeight.Bold).fontColor(Theme.ACCENT)
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(g.channels, (ch: Channel) => {
                    Row({ space: 6 }) {
                      if (ch.logo !== '') {
                        Image(ch.logo).width(24).height(24).borderRadius(4)
                          .objectFit(ImageFit.Contain)
                      }
                      Text(ch.name).fontSize(13).fontColor(Theme.INK)
                        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      if (this.favorites.has(liveChannelKey(ch.name))) {
                        Text('★').fontSize(10).fontColor('#D8A21B')
                      }
                    }
                    .padding({ left: 10, right: 12, top: 8, bottom: 8 })
                    .margin(3)
                    .borderRadius(10).backgroundColor(Theme.TINT)
                    .constraintSize({ maxWidth: '46%' })
                    .onClick(() => { this.playAt(ch); })
                    .gesture(LongPressGesture().onAction(() => { this.toggleFavorite(ch); }))
                  }, (ch: Channel) => ch.url + ch.name)
                }.width('100%')
              }
              .padding(14).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL)
              .width('100%')
            }
          }, (g: ChannelGroup) => g.group + g.channels.length.toString())
        }
        .layoutWeight(1)
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 16 })
        .scrollBar(BarState.Off)
      }
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG)

    if (this.showPaste) {
      Column() {
        Blank()
        // 浮层自己吃掉点击，避免点面板空白就把面板关掉
        Column() { this.pasteSheet() }
          .width('100%').borderRadius(20)
          .backgroundColor(Theme.PANEL)
          .hitTestBehavior(HitTestMode.Block)
      }
      .width('100%').height('100%')
      .justifyContent(FlexAlign.End)
      .backgroundColor('#66000000')
    }
    }
    .width('100%').height('100%')
  }

  @Builder
  pasteSheet() {
    Column({ space: 12 }) {
      Text('粘贴频道列表').fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.INK).width('100%')
      Text('支持 M3U 内容、HTTP/HTTPS 订阅地址，或每行「频道名,地址」的文本。')
        .fontSize(12).fontColor(Theme.SECONDARY).width('100%')
      TextArea({ placeholder: '#EXTM3U … 或 频道名,http://example.com/live.m3u8', text: this.pasteText })
        .fontSize(13).height(220).borderRadius(12).backgroundColor(Theme.BG)
        .fontColor(Theme.INK).placeholderColor(Theme.SECONDARY)
        .onChange((v: string) => { this.pasteText = v; })
      Row({ space: 10 }) {
        Button('取消').fontSize(15).height(44).layoutWeight(1).borderRadius(22)
          .backgroundColor(Theme.BG).fontColor(Theme.INK)
          .onClick(() => { this.showPaste = false; })
        Button('导入').fontSize(15).height(44).layoutWeight(1).borderRadius(22)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
          .onClick(() => { this.importFromText(); })
      }.width('100%')
      if (this.importReport !== '') {
        Text(this.importReport).fontSize(11).fontColor(Theme.SECONDARY).width('100%')
      }
    }.width('100%').padding(18)
  }
}
