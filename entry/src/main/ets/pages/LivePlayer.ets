/**
 * 独立全屏直播播放器（对齐 Android v1.3.16 起独立的 LivePlayerActivity）。
 *
 * 为什么和点播播放页分开：
 *   · 直播没有进度、续播、片头片尾、倍速、自动连播这一整套东西
 *   · 直播不写入点播历史（Android 明确约定），分开才能不误写
 *   · 换台是最高频操作，需要独立的上一台 / 下一台 / 选频道入口
 *
 * 换台顺序与服务端列表一致（央视编号 → 地方台 → 其他，均由 LivePlaylist 排好）。
 * 同名频道（去掉 高清/4K 后缀后同名）视作同一台的备用线路，主线路失败时自动依次尝试。
 */

import { RouteParams } from './RouteParams';
import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { router, window, promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fitVideoFrame } from './VideoLayout';
import { Prefs } from '../store/Prefs';
import { LiveLocal } from '../store/LiveLocal';
import { liveChannelKey, parseChannelHeaders, stepLiveChannel } from '../api/LivePlaylist';
import { Theme } from '../common/Theme';

@Entry
@Component
struct LivePlayer {
  @State index: number = 0;
  @State title: string = '';
  @State playing: boolean = false;
  @State showControls: boolean = true;
  @State showList: boolean = false;
  @State filterText: string = '';
  @State errorMsg: string = '';
  @State loadMessage: string = '正在连接频道…';
  @State volumeLevel: number = 1;
  @State favoriteKeys: string[] = [];
  @State frameWidth: number = 0;
  @State frameHeight: number = 0;

  private urls: string[] = [];
  private names: string[] = [];
  private headerTexts: string[] = [];
  private player: media.AVPlayer | null = null;
  private xcController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private surfaceReady: boolean = false;
  private prefs: Prefs | null = null;
  private disposed: boolean = false;
  private generation: number = 0;
  private hideTimer: number = -1;
  private triedLines: Set<number> = new Set();
  private videoWidth: number = 16;
  private videoHeight: number = 9;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private liveWindow: window.Window | null = null;
  private previousOrientation: window.Orientation = window.Orientation.UNSPECIFIED;
  private previousKeepScreenOn: boolean = false;

  aboutToAppear(): void {
    this.enterWindow();
    const params = router.getParams() as Record<string, string> | undefined;
    if (params === undefined || params['channelUrls'] === undefined) {
      this.errorMsg = '缺少频道参数';
      return;
    }
    this.parseList(params['channelUrls'], params['channelNames'], params['channelHeaders']);
    const start = parseInt(params['channelIndex'] ?? '0', 10);
    this.index = isNaN(start) || start < 0 || start >= this.urls.length ? 0 : start;
    this.title = this.names.length > this.index ? this.names[this.index] : '直播';
    Prefs.get(getContext(this)).then((p: Prefs) => {
      this.prefs = p;
      this.favoriteKeys = Array.from(LiveLocal.favorites(p));
    }).catch(() => {});
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.generation++;
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); }
    this.releasePlayer();
    this.restoreWindow();
  }

  onBackPress(): boolean {
    if (this.showList) { this.showList = false; return true; }
    return false;
  }

  private parseList(urlsJson: string, namesJson: string | undefined, headersJson: string | undefined): void {
    try {
      const urls = JSON.parse(urlsJson) as Object[];
      if (Array.isArray(urls)) {
        for (const u of urls) {
          if (typeof u === 'string') { this.urls.push(u as string); }
        }
      }
    } catch (e) {
      this.errorMsg = '频道列表参数无效';
      return;
    }
    try {
      const names = JSON.parse(namesJson ?? '[]') as Object[];
      if (Array.isArray(names)) {
        for (const n of names) {
          this.names.push(typeof n === 'string' ? (n as string) : '');
        }
      }
    } catch (e) {
      this.names = [];
    }
    try {
      const headers = JSON.parse(headersJson ?? '[]') as Object[];
      if (Array.isArray(headers)) {
        for (const h of headers) {
          this.headerTexts.push(typeof h === 'string' ? (h as string) : '');
        }
      }
    } catch (e) {
      this.headerTexts = [];
    }
  }

  private async enterWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      if (this.disposed) { return; }
      this.liveWindow = win;
      this.previousOrientation = win.getPreferredOrientation();
      this.previousKeepScreenOn = win.getWindowProperties().isKeepScreenOn;
      await win.setSpecificSystemBarEnabled('navigationIndicator', false);
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
      await win.setWindowKeepScreenOn(true);
    } catch (e) {
      hilog.warn(0, 'ShiguangCinema', 'live window setup failed: %{public}s', (e as Error).message);
    }
  }

  private restoreWindow(): void {
    const win = this.liveWindow;
    if (win === null) { return; }
    win.setPreferredOrientation(this.previousOrientation).catch(() => {});
    win.setWindowKeepScreenOn(this.previousKeepScreenOn).catch(() => {});
    win.setSpecificSystemBarEnabled('navigationIndicator', true).catch(() => {});
  }

  private async onSurfaceReady(): Promise<void> {
    try {
      const sid = this.xcController.getXComponentSurfaceId();
      if (sid === '') { throw new Error('视频窗口尚未创建'); }
      this.surfaceId = sid;
      this.surfaceReady = true;
      await this.setupPlayer();
    } catch (e) {
      this.loadMessage = '';
      this.errorMsg = `视频窗口初始化失败：${(e as Error).message}`;
    }
  }

  private releasePlayer(): void {
    const p = this.player;
    this.player = null;
    if (p !== null) { p.release().catch(() => {}); }
  }

  private async setupPlayer(): Promise<void> {
    if (this.disposed || !this.surfaceReady || this.urls.length === 0) {
      return;
    }
    const generation = ++this.generation;
    this.loadMessage = '正在连接频道…';
    this.errorMsg = '';
    this.playing = false;
    this.triedLines.add(this.index);
    const old = this.player;
    this.player = null;
    if (old !== null) { await old.release().catch(() => {}); }
    if (this.disposed || generation !== this.generation) { return; }
    try {
      const p = await media.createAVPlayer();
      if (this.disposed || generation !== this.generation) { await p.release().catch(() => {}); return; }
      this.player = p;
      this.bindEvents(p, generation);
      const url = this.urls[this.index];
      const headerText = this.index < this.headerTexts.length ? this.headerTexts[this.index] : '';
      const headers = parseChannelHeaders(headerText);
      if (Object.keys(headers).length > 0) {
        const source = media.createMediaSourceWithUrl(url, headers);
        await p.setMediaSource(source);
      } else {
        p.url = url;
      }
    } catch (e) {
      if (this.disposed || generation !== this.generation) { return; }
      this.handleFailure((e as Error).message);
    }
  }

  private bindEvents(p: media.AVPlayer, generation: number): void {
    p.on('stateChange', (state: string) => {
      if (this.disposed || generation !== this.generation) { return; }
      if (state === 'initialized') {
        this.loadMessage = '正在缓冲…';
        p.surfaceId = this.surfaceId;
        p.prepare().catch((e: Error) => {
          if (this.disposed || generation !== this.generation) { return; }
          this.handleFailure(e.message);
        });
      } else if (state === 'prepared') {
        if (p.width > 0 && p.height > 0) {
          this.videoWidth = p.width;
          this.videoHeight = p.height;
          this.updateFrame();
        }
        p.setVolume(this.volumeLevel);
        p.play().catch((e: Error) => {
          if (this.disposed || generation !== this.generation) { return; }
          this.handleFailure(e.message);
        });
      } else if (state === 'playing') {
        this.playing = true;
        this.loadMessage = '';
        this.errorMsg = '';
        this.triedLines.clear();
        this.triedLines.add(this.index);
        this.scheduleHide();
      } else if (state === 'paused' || state === 'stopped' || state === 'completed') {
        this.playing = false;
      }
    });
    p.on('startRenderFrame', () => {
      if (this.disposed || generation !== this.generation) { return; }
      this.loadMessage = '';
    });
    p.on('videoSizeChange', (width: number, height: number) => {
      if (this.disposed || generation !== this.generation || width <= 0 || height <= 0) { return; }
      this.videoWidth = width;
      this.videoHeight = height;
      this.updateFrame();
    });
    p.on('error', (err: BusinessError) => {
      if (this.disposed || generation !== this.generation) { return; }
      hilog.warn(0, 'ShiguangCinema', 'live error %{public}d', err.code);
      this.playing = false;
      this.handleFailure(`播放错误 ${err.code}`);
    });
  }

  /** 主线路失败：先找同名的其他线路，全部试过才报错 */
  private handleFailure(reason: string): void {
    this.loadMessage = '';
    if (this.switchToBackupLine()) { return; }
    this.errorMsg = `${reason}。该频道暂无可用线路，可换个频道或返回重试。`;
  }

  private switchToBackupLine(): boolean {
    if (this.urls.length <= 1) { return false; }
    const key = liveChannelKey(this.names.length > this.index ? this.names[this.index] : '');
    if (key === '') { return false; }
    for (let step = 1; step < this.urls.length; step++) {
      const candidate = stepLiveChannel(this.index, step, this.urls.length);
      if (this.triedLines.has(candidate)) { continue; }
      const name = candidate < this.names.length ? this.names[candidate] : '';
      if (liveChannelKey(name) !== key) { continue; }
      this.index = candidate;
      this.title = name;
      this.setupPlayer();
      return true;
    }
    return false;
  }

  private updateFrame(): void {
    const frame = fitVideoFrame(this.viewportWidth, this.viewportHeight, this.videoWidth, this.videoHeight, false);
    this.frameWidth = frame.width;
    this.frameHeight = frame.height;
  }

  private switchChannel(delta: number): void {
    if (this.urls.length === 0) { return; }
    const next = stepLiveChannel(this.index, delta, this.urls.length);
    if (next < 0 || next === this.index) { return; }
    this.selectChannel(next);
  }

  private selectChannel(next: number): void {
    this.triedLines.clear();
    this.index = next;
    this.title = next < this.names.length ? this.names[next] : `频道 ${next + 1}`;
    this.showList = false;
    this.setupPlayer();
  }

  private togglePlay(): void {
    const p = this.player;
    if (p === null) { return; }
    if (this.playing) {
      p.pause().catch(() => {});
    } else {
      p.play().catch(() => { this.notify('无法继续播放，试试换台或重试'); });
    }
  }

  private changeVolume(delta: number): void {
    this.volumeLevel = Math.max(0, Math.min(1, this.volumeLevel + delta));
    const p = this.player;
    if (p !== null) {
      try { p.setVolume(this.volumeLevel); } catch (e) { /* 音量可能被系统接管 */ }
    }
    this.notify(`音量 ${Math.round(this.volumeLevel * 100)}%`);
  }

  private notify(message: string): void {
    promptAction.showToast({ message: message, duration: 1400 });
  }

  private scheduleHide(): void {
    if (this.hideTimer >= 0) { clearTimeout(this.hideTimer); }
    this.showControls = true;
    this.hideTimer = setTimeout(() => { this.showControls = false; }, 4000);
  }

  private favoriteKey(): string {
    return liveChannelKey(this.names.length > this.index ? this.names[this.index] : this.title);
  }

  private isFavorite(): boolean {
    return this.favoriteKeys.includes(this.favoriteKey());
  }

  private toggleFavorite(): void {
    const p = this.prefs;
    if (p === null) { return; }
    const key = this.favoriteKey();
    LiveLocal.toggleFavorite(p, key).then((added: boolean) => {
      this.favoriteKeys = Array.from(LiveLocal.favorites(p));
      this.notify(added ? '已收藏该频道，列表里会优先显示' : '已取消收藏');
    }).catch(() => {});
  }

  private filteredChannels(): number[] {
    const kw = this.filterText.trim().toLowerCase();
    const out: number[] = [];
    for (let i = 0; i < this.urls.length; i++) {
      const name = i < this.names.length ? this.names[i] : `频道 ${i + 1}`;
      if (kw === '' || name.toLowerCase().includes(kw)) {
        out.push(i);
      }
    }
    return out;
  }

  @Builder
  controlButton(label: string, action: () => void) {
    Text(label).fontSize(13).fontColor('#FFFFFF').height(40).layoutWeight(1).textAlign(TextAlign.Center)
      .onClick(action)
  }

  build() {
    Stack() {
      XComponent({ id: 'live-video', type: 'surface', controller: this.xcController })
        .onLoad(() => { this.onSurfaceReady(); })
        .width(this.frameWidth > 0 ? this.frameWidth : '100%')
        .height(this.frameHeight > 0 ? this.frameHeight : '100%')

      Column()
        .width('100%').height('100%')
        .onClick(() => {
          if (this.showControls) { this.showControls = false; }
          else { this.scheduleHide(); }
        })

      if (this.loadMessage !== '' && this.errorMsg === '') {
        Column({ space: 10 }) {
          LoadingProgress().width(34).height(34).color('#FFFFFF')
          Text(this.loadMessage).fontSize(14).fontColor('#FFFFFF')
        }.padding(16).backgroundColor('#CC16161C').borderRadius(10).hitTestBehavior(HitTestMode.None)
      }
      if (this.errorMsg !== '') {
        Column({ space: 14 }) {
          Text(this.errorMsg).fontSize(14).fontColor('#FF8A8A').textAlign(TextAlign.Center).maxLines(3)
          Row({ space: 12 }) {
            Button('重试').fontSize(14).height(40).borderRadius(20)
              .backgroundColor(Theme.ACCENT).fontColor('#FFFFFF')
              .onClick(() => { this.triedLines.clear(); this.setupPlayer(); })
            Button('选频道').fontSize(14).height(40).borderRadius(20)
              .backgroundColor('#3A3A42').fontColor('#FFFFFF')
              .onClick(() => { this.showList = true; })
          }
        }.padding(18).backgroundColor('#CC16161C').borderRadius(12).width('86%')
      }

      if (this.showControls) {
        Column() {
          Row({ space: 10 }) {
            Text('<').fontSize(22).fontColor('#FFFFFF').padding(10)
              .onClick(() => { router.back(); })
            Text(this.title).fontSize(15).fontColor('#FFFFFF').layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text('LIVE').fontSize(10).fontColor('#FF5A5A')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4).border({ width: 1, color: '#FF5A5A' })
            Text(this.isFavorite() ? '★' : '☆').fontSize(20)
              .fontColor(this.isFavorite() ? '#FFD166' : '#FFFFFF').padding(8)
              .onClick(() => { this.toggleFavorite(); })
          }.width('100%').padding({ left: 6, top: 6, right: 12 })

          Blank()

          Row({ space: 8 }) {
            Text(this.names.length > this.index ? `${this.index + 1}/${this.urls.length}` : '')
              .fontSize(11).fontColor('#D7E5DF').padding({ left: 8 })
            this.controlButton('音量 -', () => { this.changeVolume(-0.1); })
            this.controlButton('上一台', () => { this.switchChannel(-1); })
            this.controlButton(this.playing ? '暂停' : '播放', () => { this.togglePlay(); })
            this.controlButton('选频道', () => { this.showList = true; })
            this.controlButton('下一台', () => { this.switchChannel(1); })
            this.controlButton('音量 +', () => { this.changeVolume(0.1); })
          }.width('100%').padding({ left: 8, right: 8, bottom: 10 })
        }
        .width('100%').height('100%')
        .linearGradient({ angle: 180, colors: [['#88000000', 0], ['#00000000', 0.3], ['#00000000', 0.7], ['#88000000', 1]] })
        .hitTestBehavior(HitTestMode.Transparent)
      }

      if (this.showList) {
        Column({ space: 10 }) {
          Row() {
            Text('选择频道').fontSize(17).fontColor('#FFFFFF').layoutWeight(1)
            Text('关闭').fontSize(14).fontColor('#FFFFFF').padding(6)
              .onClick(() => { this.showList = false; this.scheduleHide(); })
          }.width('100%')
          TextInput({ placeholder: '搜索频道…', text: this.filterText })
            .fontSize(14).height(40).borderRadius(12).backgroundColor('#2A2A31')
            .fontColor('#FFFFFF').placeholderColor('#9AA5A0')
            .onChange((v: string) => { this.filterText = v; })
          List({ space: 4 }) {
            ForEach(this.filteredChannels(), (i: number) => {
              ListItem() {
                Row() {
                  Text(i < this.names.length ? this.names[i] : `频道 ${i + 1}`)
                    .fontSize(14).fontColor(i === this.index ? '#FFFFFF' : '#D6DED9').layoutWeight(1)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  if (this.favoriteKeys.includes(liveChannelKey(i < this.names.length ? this.names[i] : ''))) {
                    Text('★').fontSize(14).fontColor('#FFD166')
                  }
                }
                .width('100%').padding(12).borderRadius(8)
                .backgroundColor(i === this.index ? Theme.ACCENT : '#2A2A31')
                .onClick(() => { this.selectChannel(i); })
              }
            }, (i: number) => i.toString())
          }.layoutWeight(1).width('100%')
        }.width('82%').height('78%').padding(16).borderRadius(16).backgroundColor('#EE202025')
      }
    }
    .width('100%').height('100%')
    .backgroundColor('#000000')
    .onAreaChange((_old: Area, area: Area) => {
      this.viewportWidth = parseFloat(area.width.toString());
      this.viewportHeight = parseFloat(area.height.toString());
      this.updateFrame();
    })
  }
}
