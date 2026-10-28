import { RouteParams } from './RouteParams';
/**
 * 首页 —— 服务端连接（MVP）+ 豆瓣推荐 + 最近观看。
 * 连接成功后显示主页；未连接显示连接表单。
 */

import { router, window, promptAction, display } from '@kit.ArkUI';
import { common, bundleManager } from '@kit.AbilityKit';
import { Api } from '../api/Api';
import { DoubanItem } from '../api/Models';
import { Prefs, WatchEntry, UpdateState } from '../store/Prefs';
import { Session } from '../store/Session';
import { Credentials } from '../store/Credentials';
import { DEFAULT_SERVER_URL } from '../store/DefaultServer';
import { checkUpdate, isNewerVersion, releasesPageUrl, ReleaseInfo } from '../api/UpdateChecker';
import { PosterImage } from '../components/PosterImage';
import { HomeIcon, iconFillPath } from '../components/HomeIcon';
import { UpdateDialog } from '../components/UpdateDialog';
import { Theme } from '../common/Theme';

interface Preset {
  name: string;
  url: string;
}

interface QuickEntry {
  label: string;
  action: () => void;
}

const PRESETS: Preset[] = [
  { name: 'tvworker', url: 'https://tv.20350720.xyz' },
  { name: 'tvoracle', url: 'https://tvoracle.20350720.xyz' }
];

@Entry
@Component
struct Index {
  @State connected: boolean = true;
  @State connecting: boolean = false;
  @State urlText: string = '';
  @State pwdText: string = '';
  @State statusMsg: string = '';
  @State errorMsg: string = '';
  @State doubanList: DoubanItem[] = [];
  @State recent: WatchEntry[] = [];
  @State knownServers: string[] = [];
  @State favoriteCount: number = 0;
  @State showSettings: boolean = false;
  @State recommendType: string = 'tv';
  /** 榜单：'' 混合 / 最新 / 热门 / 高分（对齐 Android 版「榜单」切换） */
  @State recommendTag: string = '';
  @State recommendError: string = '';
  @State recommendLoading: boolean = false;

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;
  private retryTimer: number = -1;
  private retryCount: number = 0;
  private connectionAttempt: number = 0;
  private disposed: boolean = false;
  private homeWindow: window.Window | null = null;
  /** 当前安装版本，用于和远端 tag 比较 */
  private currentVersion: string = '';
  private updateChecking: boolean = false;
  /** 入口格子尺寸：按设计稿比例（104×116，间隙 13）随屏宽换算 */
  private tileHeight: number = 65;
  private tileIconSize: number = 15;
  private tileFontSize: number = 13;

  @State updateTag: string = '';
  @State updateNotes: string = '';
  @State updateReleaseUrl: string = '';
  @State updateDownloadUrl: string = '';
  @State updateSeen: boolean = true;
  @State showUpdateDialog: boolean = false;

  aboutToAppear(): void {
    this.disposed = false;
    this.computeTileMetrics();
    try {
      this.currentVersion = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (e) {
      this.currentVersion = '';
    }
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.homeWindow = win;
      if (this.disposed) { return; }
      win.setSpecificSystemBarEnabled('navigationIndicator', false).catch(() => {});
    }).catch(() => {});
    try {
      Prefs.get(getContext(this)).then(async (p: Prefs) => {
        const initAttempt = this.connectionAttempt;
        this.prefs = p;
        this.loadUpdateState();
        // 服务端地址和"连接过列表"互不依赖，并行读省一点启动时间
        const pair = await Promise.all([p.getServerUrl(), p.getServers()]);
        const stored = pair[0];
        this.knownServers = pair[1];
        const saved = stored !== '' ? stored : DEFAULT_SERVER_URL;
        if (this.disposed || initAttempt !== this.connectionAttempt) { return; }
        if (saved !== '') {
          this.urlText = saved;
          this.session.restoreCached(saved, '', []);
          this.refreshHome(false);
          const cached = await Promise.all([p.getCookie(saved), p.getSources(saved)]);
          if (this.disposed || initAttempt !== this.connectionAttempt || this.urlText !== saved) { return; }
          this.session.restoreCached(saved, cached[0], cached[1]);
          this.tryConnect(true);
        } else {
          this.connected = false;
        }
      }).catch((e: Object) => {
        this.connected = false;
        this.errorMsg = `初始化失败：${(e as Error).message}`;
      });
    } catch (e) {
      // 同步异常也要兜住，避免整页白屏
      this.errorMsg = `页面初始化异常：${(e as Error).message}`;
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
    if (this.homeWindow !== null) {
      this.homeWindow.setSpecificSystemBarEnabled('navigationIndicator', true).catch(() => {});
    }
    this.stopRetry();
    this.session.invalidateConnection();
  }

  private stopRetry(): void {
    if (this.retryTimer >= 0) { clearTimeout(this.retryTimer); this.retryTimer = -1; }
  }

  private scheduleRetry(): void {
    if (this.disposed || !this.connected) { return; }
    const delays: number[] = [2000, 5000, 15000, 30000, 60000];
    const delay = delays[Math.min(this.retryCount, delays.length - 1)];
    this.retryCount++;
    this.stopRetry();
    this.statusMsg = '服务器暂未连接，正在后台重试';
    this.retryTimer = setTimeout(() => { this.retryTimer = -1; this.tryConnect(true); }, delay);
  }

  private openServerSettings(): void {
    this.stopRetry();
    this.connectionAttempt++;
    this.session.invalidateConnection();
    this.connecting = false;
    this.connected = false;
    this.showSettings = false;
    this.pwdText = '';
  }

  onPageShow(): void {
    this.disposed = false;
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.homeWindow = win;
      if (!this.disposed) { win.setSpecificSystemBarEnabled('navigationIndicator', false).catch(() => {}); }
    }).catch(() => {});
    const params = router.getParams() as Record<string, string> | undefined;
    if (params !== undefined && params['openServerSettings'] === '1') {
      this.openServerSettings();
      return;
    }
    if (this.connected || this.session.isLogged()) {
      this.connected = true;
      this.loadRecent();
      if (this.prefs !== null) {
        this.prefs.getFavorites().then((items: WatchEntry[]) => { this.favoriteCount = items.length; }).catch(() => {});
      }
    }
  }

  private async tryConnect(silent: boolean): Promise<void> {
    this.stopRetry();
    const attempt = ++this.connectionAttempt;
    const raw = this.urlText.trim();
    if (raw === '') {
      if (!silent) {
        this.errorMsg = '请输入服务端地址';
      }
      return;
    }
    let normalized = raw.replace(/\/+$/, '');
    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'https://' + normalized;
    }
    this.connecting = true;
    this.errorMsg = '';
    this.statusMsg = silent ? '' : '连接中…';
    try {
      const savedCookie = this.prefs !== null ? await this.prefs.getCookie(normalized) : '';
      let password = this.pwdText;
      const isDefault = normalized.toLowerCase() === DEFAULT_SERVER_URL.toLowerCase();
      // 首次登录必须手输密码；成功后会存进系统凭据库，之后这里自动取回，不用再输
      if (password === '') {
        try { password = await Credentials.load(normalized); } catch (e) { /* Existing cookie can still be used. */ }
      }
      if (attempt !== this.connectionAttempt || this.disposed) { return; }
      const status = await this.session.connect(normalized, password, savedCookie, isDefault && savedCookie === '');
      if (attempt !== this.connectionAttempt || this.disposed) { return; }
      if (this.prefs !== null) {
        await this.prefs.setServerUrl(this.session.serverUrl);
        await this.prefs.setCookie(this.session.serverUrl, (this.session.api as Api).currentCookie());
        const savedSources = await this.prefs.getSources(this.session.serverUrl);
        if (savedSources.length > 0) {
          this.session.sources = savedSources;
        } else {
          await this.prefs.setSources(this.session.serverUrl, this.session.sources);
        }
      }
      let saveFailed = false;
      if (this.pwdText !== '') {
        try { await Credentials.save(normalized, this.pwdText); } catch (e) { saveFailed = true; }
      }
      if (attempt !== this.connectionAttempt || this.disposed) { return; }
      this.pwdText = '';
      this.retryCount = 0;
      this.connected = true;
      this.statusMsg = saveFailed ? '密码安全保存失败，会话失效后需要重新输入' : '';
      this.refreshHome();
    } catch (e) {
      if (attempt !== this.connectionAttempt || this.disposed) { return; }
      const err = e as Error;
      if (err.message === 'NEED_PASSWORD' || (silent && err.message === 'HTTP 401')) {
        this.statusMsg = '该服务端需要访问密码';
      } else if (!silent) {
        this.errorMsg = err.message;
      } else {
        this.scheduleRetry();
      }
    } finally {
      if (attempt === this.connectionAttempt) { this.connecting = false; }
    }
  }

  private refreshHome(refreshRecommendations: boolean = true): void {
    this.loadRecent();
    if (this.prefs !== null) {
      this.prefs.getFavorites().then((items: WatchEntry[]) => { this.favoriteCount = items.length; }).catch(() => {});
    }
    this.loadDouban(refreshRecommendations);
  }

  private loadRecent(): void {
    if (this.prefs === null) {
      return;
    }
    this.prefs.getHistory().then((list: WatchEntry[]) => {
      this.recent = list.slice(0, 12);
    });
  }

  private async loadDouban(refresh: boolean = true): Promise<void> {
    const api = this.session.api;
    if (api === null) { return; }
    const type = this.recommendType;
    const tag = this.recommendTag;
    const cacheKey = `${type}|${tag}`;
    const serverUrl = this.session.serverUrl;
    if (this.prefs !== null) {
      try {
        const cached = await this.prefs.getRecommendations(serverUrl, cacheKey);
        if (type !== this.recommendType || tag !== this.recommendTag || serverUrl !== this.session.serverUrl) { return; }
        if (cached.length > 0) { this.doubanList = cached; }
      } catch (e) {
        // Cache failures do not block the network refresh.
      }
    }
    if (!refresh) { return; }
    this.recommendLoading = true;
    this.recommendError = '';
    api.douban(type, tag, 0, 24).then((list: DoubanItem[]) => {
      if (type !== this.recommendType || tag !== this.recommendTag) { return; }
      if (list.length > 0) { this.doubanList = list; }
      this.recommendLoading = false;
      if (list.length > 0 && this.prefs !== null) {
        this.prefs.setRecommendations(serverUrl, cacheKey, list).catch(() => {});
      }
      if (list.length === 0 && this.doubanList.length === 0) { this.recommendError = '暂无推荐，点击重试'; }
    }).catch(() => {
      if (type !== this.recommendType || tag !== this.recommendTag) { return; }
      this.recommendLoading = false;
      if (this.doubanList.length === 0) { this.recommendError = '推荐加载失败，点击重试'; }
    });
  }

  /** 入口格子按设计稿比例换算：5 格 + 4 个 7vp 间隙，左右各 20vp 页边距，宽高比 0.9 */
  private computeTileMetrics(): void {
    try {
      const screenWidth: number = px2vp(display.getDefaultDisplaySync().width);
      const tileWidth: number = (screenWidth - 40 - 4 * 7) / 5;
      this.tileHeight = Math.round(tileWidth / 0.9);
      this.tileIconSize = Math.round(this.tileHeight * 0.23);
      this.tileFontSize = Math.round(this.tileHeight * 0.20);
    } catch (e) {
      // 取不到屏宽就用 360vp 的默认值
      this.tileHeight = 65;
      this.tileIconSize = 15;
      this.tileFontSize = 13;
    }
  }

  /** 切分类：电影 / 剧集 / 综艺（与 Android 首页入口一致） */
  private setMediaType(type: string): void {
    if (this.recommendType === type) { return; }
    this.recommendType = type;
    this.doubanList = [];
    this.recommendError = '';
    this.loadDouban();
  }

  private mediaTypeLabel(): string {
    if (this.recommendType === 'movie') { return '电影'; }
    if (this.recommendType === 'show') { return '综艺'; }
    return '剧集';
  }

  private tagLabel(): string {
    return this.recommendTag === '' ? '混合' : this.recommendTag;
  }

  /** 榜单四态循环：混合 → 最新 → 热门 → 高分 */
  private cycleTag(): void {
    const order: string[] = ['', '最新', '热门', '高分'];
    const idx = order.indexOf(this.recommendTag);
    this.recommendTag = order[(idx < 0 ? 0 : idx + 1) % order.length];
    this.doubanList = [];
    this.recommendError = '';
    this.loadDouban();
  }

  /* ------------------------------------------------------------ 检查更新 */

  /** 读取上次检查结果；超过 6 小时才重新请求 GitHub（与 Android 版一致） */
  private async loadUpdateState(): Promise<void> {
    if (this.prefs === null) { return; }
    const state = await this.prefs.getUpdateState();
    this.applyUpdateState(state);
    if (Date.now() - state.checkedAt > 6 * 3600 * 1000) {
      this.runUpdateCheck(true);
    }
  }

  private applyUpdateState(state: UpdateState): void {
    if (isNewerVersion(state.tag, this.currentVersion)) {
      this.updateTag = state.tag;
      this.updateNotes = state.notes;
      this.updateReleaseUrl = state.releaseUrl;
      this.updateDownloadUrl = state.downloadUrl;
      this.updateSeen = state.seenTag === state.tag;
    } else {
      this.updateTag = '';
      this.updateSeen = true;
    }
  }

  /** silent=true 用于启动时的后台检查，不弹提示 */
  private async runUpdateCheck(silent: boolean): Promise<void> {
    if (this.updateChecking) { return; }
    this.updateChecking = true;
    const result = await checkUpdate();
    this.updateChecking = false;
    if (this.prefs === null) { return; }
    const prev = await this.prefs.getUpdateState();
    let state: UpdateState;
    if (result.ok && result.release !== undefined) {
      const rel: ReleaseInfo = result.release;
      const newer = isNewerVersion(rel.tag, this.currentVersion);
      state = {
        tag: newer ? rel.tag : '',
        notes: newer ? rel.notes : '',
        downloadUrl: newer ? rel.downloadUrl : '',
        releaseUrl: newer ? rel.releaseUrl : '',
        seenTag: prev.seenTag,
        checkedAt: Date.now()
      };
      await this.prefs.setUpdateState(state);
      this.applyUpdateState(state);
      if (!silent) {
        promptAction.showToast({ message: newer ? `发现新版本 ${rel.tag}` : `已是最新版本 v${this.currentVersion}` });
        if (newer) { this.showUpdateDialog = true; }
      }
    } else {
      // 失败也算作"已检查"，避免每次进首页都重试；已知的新版本提示不抹掉
      state = {
        tag: prev.tag, notes: prev.notes, downloadUrl: prev.downloadUrl,
        releaseUrl: prev.releaseUrl, seenTag: prev.seenTag, checkedAt: Date.now()
      };
      await this.prefs.setUpdateState(state);
      if (!silent) {
        promptAction.showToast({
          message: result.message !== undefined ? result.message : '检查更新失败'
        });
      }
    }
  }

  private openUpdateDialog(): void {
    this.showUpdateDialog = true;
    this.updateSeen = true;
    if (this.prefs !== null && this.updateTag !== '') {
      this.prefs.getUpdateState().then((prev: UpdateState) => {
        const state: UpdateState = {
          tag: prev.tag, notes: prev.notes, downloadUrl: prev.downloadUrl,
          releaseUrl: prev.releaseUrl, seenTag: this.updateTag, checkedAt: prev.checkedAt
        };
        if (this.prefs !== null) { this.prefs.setUpdateState(state).catch(() => {}); }
      }).catch(() => {});
    }
  }

  /** HAP 无法由应用自行安装，这里跳 GitHub 发布页让用户下载 */
  private openReleasePage(): void {
    const url = this.updateReleaseUrl !== '' ? this.updateReleaseUrl : releasesPageUrl();
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.startAbility({ action: 'ohos.want.action.viewData', uri: url }).catch(() => {
        promptAction.showToast({ message: '无法打开 GitHub 发布页' });
      });
    } catch (e) {
      promptAction.showToast({ message: '无法打开 GitHub 发布页' });
    }
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

  private goSearch(): void {
    router.pushUrl({ url: 'pages/Search' });
  }

  private goHistory(): void {
    router.pushUrl({ url: 'pages/History' });
  }

  private goLive(): void {
    router.pushUrl({ url: 'pages/Live' });
  }

  private goFavorites(): void {
    router.pushUrl({ url: 'pages/Favorites' });
  }

  private goSourceManage(): void {
    router.pushUrl({ url: 'pages/SourceManage' });
  }

  private goNetDiag(): void {
    router.pushUrl({ url: 'pages/NetDiag' });
  }

  private goScanServer(): void {
    router.pushUrl({ url: 'pages/Scan', params: { mode: 'server' } as RouteParams });
  }

  @Builder
  navTile(kind: string, label: string, selected: boolean, action: () => void) {
    Column({ space: 6 }) {
      HomeIcon({ kind: kind, iconSize: this.tileIconSize, tint: selected ? Theme.ON_ACCENT : Theme.INK })
      Text(label).fontSize(this.tileFontSize).fontColor(selected ? Theme.ON_ACCENT : Theme.INK).maxLines(1)
    }
    .layoutWeight(1).height(this.tileHeight).justifyContent(FlexAlign.Center)
    .borderRadius(Theme.RADIUS_TILE)
    .backgroundColor(selected ? Theme.TILE_ACTIVE : Theme.PANEL)
    .onClick(action)
  }

  /** 顶部品牌字标：蓝色圆角方块 + 白色播放三角 + 文字（对齐设计稿） */
  @Builder
  brandRow() {
    Row({ space: 0 }) {
      Stack() {
        Column().width(28).height(28).borderRadius(9).backgroundColor('#5E83AD')
        Path()
          .width(28).height(28)
          .commands(iconFillPath('movie', 28 * vp2px(1)))
          .fill(Theme.ON_ACCENT)
          .antiAlias(true)
      }.width(28).height(28)
      Text('时光影院').fontSize(23).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        .padding({ left: 10, right: 12 })
      Blank()
      if (this.updateTag !== '') {
        Text(this.updateSeen ? `新版本 ${this.updateTag}` : `● 新版本 ${this.updateTag}`)
          .fontSize(12).fontColor(Theme.ACCENT)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(15).backgroundColor(Theme.TINT)
          .onClick(() => { this.openUpdateDialog(); })
      }
    }.width('100%').alignItems(VerticalAlign.Center)
  }

  /** 更新弹窗：显示新版本说明，应用内下载（带进度），完成后交给其他应用处理 */
  @Builder
  updateDialog() {
    UpdateDialog({
      newTag: this.updateTag,
      currentVersion: this.currentVersion,
      notes: this.updateNotes,
      downloadUrl: this.updateDownloadUrl,
      onClosed: () => { this.showUpdateDialog = false; }
    })
  }

  @Builder
  connectForm() {
    Column({ space: 18 }) {
      Column({ space: 8 }) {
        Text('时光影院')
          .fontSize(30).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Text('连接你的 LibreTV 服务端')
          .fontSize(14).fontColor(Theme.SECONDARY)
      }.width('100%').alignItems(HorizontalAlign.Start)

      Column({ space: 12 }) {
        TextInput({ placeholder: '服务端地址（如 https://tv.example.com）', text: this.urlText })
          .fontSize(15).height(48).borderRadius(14)
          .backgroundColor(Theme.BG).fontColor(Theme.INK)
          .placeholderColor(Theme.SECONDARY)
          .onChange((v: string) => { this.urlText = v; })

        TextInput({ placeholder: '访问密码（可选）', text: this.pwdText })
          .type(InputType.Password).fontSize(15).height(48).borderRadius(14)
          .backgroundColor(Theme.BG).fontColor(Theme.INK)
          .placeholderColor(Theme.SECONDARY)
          .onChange((v: string) => { this.pwdText = v; })

        Row({ space: 8 }) {
          ForEach(PRESETS, (p: Preset) => {
            Text(p.name)
              .fontSize(13).fontColor(Theme.ACCENT)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(16).backgroundColor(Theme.TINT)
              .onClick(() => { this.urlText = p.url; this.pwdText = ''; })
          }, (p: Preset) => p.name)
        }.width('100%')

        Button(this.connecting ? '连接中…' : '连接')
          .width('100%').height(48).borderRadius(14)
          .fontSize(16).fontWeight(FontWeight.Medium)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
          .enabled(!this.connecting)
          .onClick(() => { this.tryConnect(false); })

        if (this.statusMsg !== '') {
          Text(this.statusMsg).fontSize(12).fontColor(Theme.SECONDARY)
        }
        if (this.errorMsg !== '') {
          Text(this.errorMsg).fontSize(12).fontColor(Theme.DANGER)
        }
        if (this.knownServers.length > 0) {
          Text(`连接过：${this.knownServers.join('、')}`)
            .fontSize(11).fontColor(Theme.TERTIARY).maxLines(2)
        }
      }.width('100%').padding(18).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL)
    }
    .width('100%')
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  homeView() {
    Scroll() {
      Column({ space: 18 }) {
        this.brandRow()

        // 入口格子：一行五个（点播 / 直播 / 搜索 / 追剧 / 设置），与设计稿一致
        Row({ space: 7 }) {
          this.navTile('tv', '点播', this.recommendType === 'tv', () => { this.setMediaType('tv'); })
          this.navTile('live', '直播', false, () => { this.goLive(); })
          this.navTile('search', '搜索', false, () => { this.goSearch(); })
          this.navTile('fav', '追剧', false, () => { this.goFavorites(); })
          this.navTile('setup', '设置', false, () => { router.pushUrl({ url: 'pages/Settings' }); })
        }.width('100%')

        if (this.statusMsg !== '') {
          Text(this.statusMsg === '服务器暂未连接，正在后台重试' ? this.statusMsg : `${this.statusMsg} · 点击重新连接`).fontSize(12).fontColor('#9A5A15')
            .width('100%').padding(10).borderRadius(10).backgroundColor('#FFF3D9')
            .onClick(() => { if (this.statusMsg !== '服务器暂未连接，正在后台重试') { this.openServerSettings(); } })
        }

        if (this.recent.length > 0) {
          Row() {
            Text('最近观看').fontSize(21).fontWeight(FontWeight.Bold).fontColor(Theme.INK).layoutWeight(1)
            Button('全部记录').fontSize(13).height(34).borderRadius(17)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .onClick(() => { this.goHistory(); })
          }.width('100%')
          Row() {
            PosterImage({ url: this.recent[0].cover,
              proxy: this.session.api !== null ? this.session.api.imageUrl(this.recent[0].cover) : '',
              cookie: this.session.api !== null ? this.session.api.currentCookie() : '', posterHeight: 176 }).width(118)
            Column({ space: 8 }) {
              Text('继续观看').fontSize(12).fontWeight(FontWeight.Bold).fontColor(Theme.ACCENT)
              Text(this.recent[0].title).fontSize(19).fontWeight(FontWeight.Bold).fontColor(Theme.INK).maxLines(2)
              Text(`第 ${this.recent[0].episodeIndex + 1}/${this.recent[0].episodeCount} 集`)
                .fontSize(12).fontColor(Theme.SECONDARY)
              Progress({ value: this.recent[0].durationMs > 0 ? this.recent[0].positionMs / this.recent[0].durationMs * 100 : 0, total: 100 })
                .width('100%').height(4).color(Theme.ACCENT)
              Text('▶ 继续播放').fontSize(13).fontWeight(FontWeight.Bold).fontColor(Theme.ACCENT)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1).padding(16)
          }
          .width('100%').height(176).borderRadius(18).clip(true)
          .backgroundColor(Theme.PANEL)
          .border({ width: 1, color: Theme.BORDER })
          .onClick(() => {
            const e = this.recent[0];
            router.pushUrl({ url: 'pages/Detail', params: { sourceUrl: e.sourceUrl, vodId: e.vodId, resumeKey: e.key } as RouteParams });
          })
        }

        Row({ space: 8 }) {
          Text('最新热门推荐').fontSize(21).fontWeight(FontWeight.Bold).fontColor(Theme.INK).layoutWeight(1)
          Button(this.mediaTypeLabel()).fontSize(12).height(32).borderRadius(16)
            .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
            .onClick(() => {
              const types: string[] = ['tv', 'movie', 'show'];
              const idx = types.indexOf(this.recommendType);
              this.setMediaType(types[(idx < 0 ? 0 : idx + 1) % types.length]);
            })
          Button(`榜单：${this.tagLabel()}`).fontSize(12).height(32).borderRadius(16)
            .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
            .onClick(() => { this.cycleTag(); })
        }.width('100%')
        if (this.recommendLoading) {
          Text('正在加载推荐…').fontSize(13).fontColor(Theme.SECONDARY).width('100%')
        } else if (this.recommendError !== '') {
          Text(this.recommendError).fontSize(13).fontColor(Theme.ACCENT).width('100%')
            .onClick(() => { this.loadDouban(); })
        }
        GridRow({ columns: 2, gutter: { x: 12, y: 20 } }) {
          ForEach(this.doubanList, (d: DoubanItem) => {
            GridCol() {
              Column({ space: 5 }) {
                PosterImage({ url: d.cover, proxy: this.session.api !== null ? this.session.api.imageUrl(d.cover) : '',
                  cookie: this.session.api !== null ? this.session.api.currentCookie() : '', posterHeight: 240 })
                Text(d.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
                Text(d.rating !== '' ? `★ ${d.rating} · 热播` : '热门').fontSize(12).fontColor(Theme.SECONDARY).width('100%')
              }.width('100%').padding({ bottom: 12 })
                .onClick(() => { router.pushUrl({ url: 'pages/Search', params: { keyword: d.title } as RouteParams }); })
            }
          }, (d: DoubanItem) => d.title + d.cover)
        }.width('100%')
      }
      .width('100%').padding({ left: 20, right: 20, top: 14, bottom: 30 })
      .alignItems(HorizontalAlign.Start)
      .constraintSize({ minHeight: '100%' })
    }.width('100%').height('100%').scrollBar(BarState.Off).backgroundColor(Theme.BG)
  }

  build() {
    Stack() {
      Column()
        .width('100%').height('100%')
        .backgroundColor(Theme.BG)

      if (this.connected) {
        this.homeView()
      } else {
        this.connectForm()
      }

      if (this.showUpdateDialog) {
        this.updateDialog()
      }
    }
    .width('100%').height('100%')
  }
}
