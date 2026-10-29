import { pasteboard } from '@kit.BasicServicesKit';
import { promptAction, router, window } from '@kit.ArkUI';
import { bundleManager, common } from '@kit.AbilityKit';
import { clearPosterCache } from '../components/PosterImage';
import { Session } from '../store/Session';
import { Prefs, UpdateState } from '../store/Prefs';
import { checkUpdate, isNewerVersion, releasesPageUrl, ReleaseInfo } from '../api/UpdateChecker';
import { UpdateDialog } from '../components/UpdateDialog';
import { Theme } from '../common/Theme';

interface SettingsItem {
  icon: string;
  title: string;
  subtitle: string;
  action: () => void;
}

@Entry
@Component
struct SettingsPage {
  @State pointSourceCount: number = 0;
  @State liveSourceCount: number = 0;
  @State connected: boolean = false;
  @State serverName: string = '';
  @State versionLabel: string = '';
  @State showUpdateDialog: boolean = false;
  @State newTag: string = '';
  @State newNotes: string = '';
  @State newDownloadUrl: string = '';

  private session: Session = Session.getInstance();
  private settingsWindow: window.Window | null = null;
  private prefs: Prefs | null = null;
  private updateChecking: boolean = false;

  aboutToAppear(): void {
    // 版本号直接读包信息，避免以后升级时忘了改这里的硬编码
    try {
      this.versionLabel = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (e) {
      this.versionLabel = '';
    }
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.settingsWindow = win;
      win.setSpecificSystemBarEnabled('navigationIndicator', false).catch(() => {});
    }).catch(() => {});
    this.connected = this.session.isLogged();
    this.pointSourceCount = this.session.sources.length;
    this.serverName = this.session.serverUrl.replace(/^https?:\/\//, '').split('/')[0];
    Prefs.get(getContext(this)).then((prefs: Prefs) => {
      this.prefs = prefs;
      prefs.getLiveSources(this.session.serverUrl).then((sources: string[]) => {
        this.liveSourceCount = sources.length > 0 ? sources.length : (this.session.appStatus?.defaultLiveSources.length ?? 0);
      }).catch(() => {});
    }).catch(() => {});
  }

  /** 切后台再回前台后系统可能恢复导航指示条，这里补一次隐藏 */
  onPageShow(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      this.settingsWindow = win;
      win.setSpecificSystemBarEnabled('navigationIndicator', false).catch(() => {});
    }).catch(() => {});
  }

  aboutToDisappear(): void {
    this.settingsWindow?.setSpecificSystemBarEnabled('navigationIndicator', true).catch(() => {});
  }

  private switchServer(): void {
    router.back({ url: 'pages/Index', params: { openServerSettings: '1' } });
  }

  private clearCache(): void {
    clearPosterCache();
    promptAction.showToast({ message: '图片缓存已清理' });
  }

  private showUpdateInfo(): void {
    this.checkForUpdates();
  }

  /** 手动检查更新：不受首页 6 小时节流限制 */
  private async checkForUpdates(): Promise<void> {
    if (this.updateChecking) {
      promptAction.showToast({ message: '正在检查更新…' });
      return;
    }
    this.updateChecking = true;
    promptAction.showToast({ message: '正在检查更新…' });
    const result = await checkUpdate();
    this.updateChecking = false;
    if (!result.ok || result.release === undefined) {
      promptAction.showToast({ message: result.message !== undefined ? result.message : '检查更新失败' });
      return;
    }
    const rel: ReleaseInfo = result.release;
    const newer = isNewerVersion(rel.tag, this.versionLabel);
    // 顺手把状态写回，首页的更新胶囊能立刻同步
    if (this.prefs !== null) {
      const prev: UpdateState = await this.prefs.getUpdateState();
      const state: UpdateState = {
        tag: newer ? rel.tag : '',
        notes: newer ? rel.notes : '',
        downloadUrl: newer ? rel.downloadUrl : '',
        releaseUrl: newer ? rel.releaseUrl : '',
        seenTag: prev.seenTag,
        checkedAt: Date.now()
      };
      await this.prefs.setUpdateState(state);
    }
    if (!newer) {
      promptAction.showToast({ message: `已是最新版本 v${this.versionLabel}` });
      return;
    }
    // 应用内下载：交给更新弹窗走进度条，完成后可交给其他应用签名 / 安装
    this.newTag = rel.tag;
    this.newNotes = rel.notes;
    this.newDownloadUrl = rel.downloadUrl;
    this.showUpdateDialog = true;
  }

  /** HAP 不能由应用自行安装，打开 GitHub 发布页让用户下载 */
  private openReleasePage(url: string): void {
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      ctx.startAbility({ action: 'ohos.want.action.viewData', uri: url }).catch(() => {
        promptAction.showToast({ message: '无法打开 GitHub 发布页' });
      });
    } catch (e) {
      promptAction.showToast({ message: '无法打开 GitHub 发布页' });
    }
  }

  private async showCrashInfo(): Promise<void> {
    if (this.prefs === null) { promptAction.showToast({ message: '存储尚未就绪' }); return; }
    const log = await this.prefs.getCrashLog();
    if (log === '') { promptAction.showToast({ message: '暂无崩溃记录' }); return; }
    const result = await promptAction.showDialog({
      title: '最近一次异常', message: log,
      buttons: [{ text: '关闭', color: Theme.INK }, { text: '复制', color: Theme.ACCENT }]
    });
    if (result.index === 1) {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, log));
      promptAction.showToast({ message: '已复制' });
    }
  }

  @Builder
  card(item: SettingsItem) {
    Row({ space: 14 }) {
      Text(item.icon).fontSize(22).fontColor(Theme.ACCENT).width(44).height(44)
        .textAlign(TextAlign.Center).borderRadius(12).backgroundColor(Theme.TINT)
      Column({ space: 3 }) {
        Text(item.title).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK).width('100%')
        Text(item.subtitle).fontSize(12).fontColor(Theme.SECONDARY).width('100%')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('›').fontSize(27).fontColor(Theme.ACCENT)
    }.width('100%').height(72).padding({ left: 16, right: 14 }).borderRadius(Theme.RADIUS_CARD)
      .backgroundColor(Theme.PANEL)
      .border({ width: 1, color: Theme.BORDER })
      .onClick(item.action)
  }

  build() {
    Stack() {
    Scroll() {
      Column({ space: 12 }) {
        Row() {
          Row({ space: 10 }) {
            Text('▶').fontSize(13).fontColor(Theme.ON_ACCENT)
              .width(28).height(28).textAlign(TextAlign.Center)
              .borderRadius(9).backgroundColor(Theme.ACCENT)
            Text('时光影院').fontSize(23).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          }.layoutWeight(1)
          Button('‹ 返回主页').fontSize(14).height(36).borderRadius(18)
            .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
            .onClick(() => { router.back({ url: 'pages/Index' }); })
        }.width('100%').padding({ top: 12, bottom: 8 })

        Text('设置').fontSize(27).fontWeight(FontWeight.Bold).fontColor(Theme.INK).width('100%')
        Text('让观影体验保持顺手、稳定。').fontSize(15).fontColor(Theme.SECONDARY).width('100%')
          .padding({ bottom: 8 })

        Column({ space: 4 }) {
          Text(this.connected ? '●  服务端已连接' : '●  服务端未连接').fontSize(13)
            .fontWeight(FontWeight.Bold).fontColor(Theme.ON_ACCENT_SOFT)
          Text(this.serverName !== '' ? this.serverName : '点击连接服务端').fontSize(17)
            .fontWeight(FontWeight.Bold).fontColor(Theme.ON_ACCENT)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ top: 4, bottom: 3 })
          Text(`${this.pointSourceCount} 个片源  ·  点击切换服务端`).fontSize(13)
            .fontColor(Theme.ON_ACCENT_MUTED)
        }.width('100%').padding({ left: 20, right: 20, top: 17, bottom: 17 })
          .borderRadius(20).alignItems(HorizontalAlign.Start)
          .linearGradient({ angle: 135, colors: [[Theme.ACCENT_START, 0.0], [Theme.ACCENT_DEEP, 1.0]] })
          .onClick(() => { this.switchServer(); })

        Text('观影设置').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          .width('100%').padding({ top: 22, bottom: 10 })
        this.card({ icon: '+', title: '片源管理',
          subtitle: `点播源 ${this.pointSourceCount} 个 · 直播源 ${this.liveSourceCount} 个 · 管理`,
          action: () => { router.pushUrl({ url: 'pages/SourceManage' }); } })
        this.card({ icon: '▷', title: '播放设置', subtitle: '续播、画质、缓冲与跳过片头片尾',
          action: () => { router.pushUrl({ url: 'pages/PlaybackSettings' }); } })
        this.card({ icon: '☼', title: '切换服务端', subtitle: '选择预设服务端，输入密码连接',
          action: () => { this.switchServer(); } })

        Text('维护工具').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          .width('100%').padding({ top: 22, bottom: 10 })
        this.card({ icon: '◷', title: '清理缓存', subtitle: '管理本地缓存占用', action: () => { this.clearCache(); } })
        this.card({ icon: '⌕', title: '网络诊断', subtitle: '检测连接和片源响应',
          action: () => { router.pushUrl({ url: 'pages/NetDiag' }); } })
        this.card({ icon: '↻', title: '检查更新', subtitle: '立即检查 GitHub 上的最新版本', action: () => { this.showUpdateInfo(); } })
        this.card({ icon: '◷', title: '崩溃日志', subtitle: '查看错误记录并复制排查', action: () => { this.showCrashInfo(); } })

        Text(this.versionLabel !== '' ? `时光影院 v${this.versionLabel}` : '时光影院')
          .fontSize(13).fontColor(Theme.SECONDARY).width('100%')
          .textAlign(TextAlign.Center).padding({ top: 22, bottom: 14 })
      }.width('100%').padding({ left: 18, right: 18, bottom: 18 }).alignItems(HorizontalAlign.Start)
    }.width('100%').height('100%').backgroundColor(Theme.BG).scrollBar(BarState.Off)

    if (this.showUpdateDialog) {
      UpdateDialog({
        newTag: this.newTag,
        currentVersion: this.versionLabel,
        notes: this.newNotes,
        downloadUrl: this.newDownloadUrl,
        onClosed: () => { this.showUpdateDialog = false; }
      })
    }
    }
  }
}
