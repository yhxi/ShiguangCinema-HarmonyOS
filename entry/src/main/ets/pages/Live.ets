import { RouteParams } from './RouteParams';
/**
 * 直播页 —— IPTV 频道。
 *   · 直播源（M3U 订阅）来自服务端下发 / 内置两源 / 用户添加（片源管理里维护）
 *   · 频道列表按分组折叠，搜索过滤
 *   · 选台进入 Player 直播模式（无进度条、上一台/下一台）
 */

import { router } from '@kit.ArkUI';
import { Channel } from '../api/Models';
import { Api, BUILT_IN_LIVE_SOURCES, liveSourceLabel } from '../api/Api';
import { Prefs } from '../store/Prefs';
import { Theme } from '../common/Theme';
import { Session } from '../store/Session';

interface ChannelGroup {
  group: string;
  channels: Channel[];
}

@Entry
@Component
struct Live {
  @State groups: ChannelGroup[] = [];
  @State filtered: ChannelGroup[] = [];
  @State filterText: string = '';
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State sourceLabel: string = '';

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;
  private channels: Channel[] = [];

  aboutToAppear(): void {
    Prefs.get(getContext(this)).then(async (p: Prefs) => {
      this.prefs = p;
      await this.loadChannels();
    });
  }

  private async currentLiveUrl(): Promise<string> {
    if (this.prefs === null || this.session.serverUrl === '') {
      return BUILT_IN_LIVE_SOURCES[0];
    }
    let list = await this.prefs.getLiveSources(this.session.serverUrl);
    if (list.length === 0) {
      // 首次：内置两个源，默认用第一个（与 Android 版一致）
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
    const api = this.session.api;
    if (api === null) {
      this.errorMsg = '请先在首页连接服务端';
      return;
    }
    const url = await this.currentLiveUrl();
    this.sourceLabel = liveSourceLabel(url);
    this.loading = true;
    this.errorMsg = '';
    try {
      this.channels = await api.liveChannels(url);
      this.regroup();
    } catch (e) {
      this.errorMsg = `拉取频道失败：${(e as Error).message}`;
    } finally {
      this.loading = false;
    }
  }

  private regroup(): void {
    const kw = this.filterText.trim().toLowerCase();
    const byGroup: Map<string, Channel[]> = new Map();
    for (const ch of this.channels) {
      if (kw !== '' && !ch.name.toLowerCase().includes(kw) &&
        !ch.group.toLowerCase().includes(kw)) {
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
    byGroup.forEach((v: Channel[], k: string) => {
      groups.push({ group: k, channels: v });
    });
    groups.sort((a: ChannelGroup, b: ChannelGroup) => {
      if (a.channels.length !== b.channels.length) {
        return b.channels.length - a.channels.length;
      }
      return a.group.localeCompare(b.group);
    });
    this.filtered = groups;
  }

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
    router.pushUrl({
      url: 'pages/Player',
      params: {
        'episodes': JSON.stringify(all.map((c: Channel) => c.url)),
        'index': idx.toString(),
        'title': channel.name,
        'cover': channel.logo,
        'sourceUrl': 'live',
        'vodId': 'live',
        'resumeMs': '0',
        'isLive': '1'
      } as RouteParams
    });
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Column({ space: 2 }) {
          Text('直播').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          if (this.sourceLabel !== '') {
            Text(this.sourceLabel).fontSize(10).fontColor(Theme.TERTIARY).maxLines(1)
          }
        }.alignItems(HorizontalAlign.Start)
        Blank()
        Button('换源').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.ACCENT)
          .onClick(() => { router.pushUrl({ url: 'pages/SourceManage' }); })
        Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      TextInput({ placeholder: '过滤频道 / 分组…' })
        .fontSize(15).height(44).borderRadius(14)
        .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
        .placeholderColor(Theme.SECONDARY)
        .margin({ left: 16, right: 16, bottom: 8 })
        .onChange((v: string) => {
          this.filterText = v;
          this.regroup();
        })

      if (this.loading) {
        Column({ space: 10 }) {
          LoadingProgress().width(36).height(36).color(Theme.ACCENT)
          Text('拉取频道列表中…').fontSize(13).fontColor(Theme.SECONDARY)
        }.layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
      } else if (this.errorMsg !== '') {
        Column({ space: 14 }) {
          Text(this.errorMsg).fontSize(14).fontColor(Theme.DANGER).textAlign(TextAlign.Center)
          Button('重试').fontSize(15).height(42).borderRadius(21)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.loadChannels(); })
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
                    }
                    .padding({ left: 10, right: 12, top: 8, bottom: 8 })
                    .margin(3)
                    .borderRadius(10).backgroundColor(Theme.TINT)
                    .constraintSize({ maxWidth: '46%' })
                    .onClick(() => { this.playAt(ch); })
                  }, (ch: Channel) => ch.url)
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
  }
}
