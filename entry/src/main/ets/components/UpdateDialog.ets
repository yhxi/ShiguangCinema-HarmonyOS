/**
 * 更新弹窗：显示新版本说明，应用内下载（带百分比进度），完成后"打开"。
 * 首页和设置页共用。HAP 无法由应用自行安装，下载后交给用户选择的应用处理
 * （未签名包先签名再安装）。
 */

import { common, wantConstant } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { downloadUpdateFile, findDownloadedUpdate, UpdatePackage } from '../api/UpdateDownloader';
import { releasesPageUrl } from '../api/UpdateChecker';
import { Theme } from '../common/Theme';

@Component
export struct UpdateDialog {
  @Prop @Watch('restoreDownload') newTag: string = '';
  @Prop currentVersion: string = '';
  @Prop notes: string = '';
  @Prop downloadUrl: string = '';
  @Prop downloadSize: number = 0;
  @Prop downloadDigest: string = '';
  @Prop releaseUrl: string = '';
  onClosed: () => void = () => {};

  /** 0 待下载 1 下载中 2 已完成 3 失败 */
  @State phase: number = 0;
  @State pct: number = 0;
  @State localPath: string = '';
  @State failMsg: string = '';

  @State checkingCache: boolean = true;
  private requestId: number = 0;

  aboutToAppear(): void { this.restoreDownload(); }
  aboutToDisappear(): void { this.requestId++; }

  private packageInfo(): UpdatePackage {
    return { tag: this.newTag, url: this.downloadUrl, size: this.downloadSize, digest: this.downloadDigest };
  }

  private async restoreDownload(): Promise<void> {
    const id = ++this.requestId;
    this.checkingCache = true;
    this.phase = 0;
    this.localPath = '';
    const ctx = getContext(this) as common.UIAbilityContext;
    const path = await findDownloadedUpdate(ctx, this.packageInfo());
    if (id !== this.requestId) { return; }
    this.checkingCache = false;
    if (path !== '') {
      this.localPath = path;
      this.pct = 100;
      this.phase = 2;
    }
  }

  private async startDownload(): Promise<void> {
    if (this.checkingCache || this.phase === 1 || this.downloadUrl === '') { return; }
    const id = ++this.requestId;
    this.phase = 1;
    this.pct = 0;
    const ctx = getContext(this) as common.UIAbilityContext;
    const result = await downloadUpdateFile(ctx, this.packageInfo(), (pct: number) => {
      if (id === this.requestId) { this.pct = pct; }
    });
    if (id !== this.requestId) { return; }
    if (result.ok) {
      this.localPath = result.path;
      this.pct = 100;
      this.phase = 2;
    } else {
      this.failMsg = result.message ?? '下载失败';
      this.phase = 3;
    }
  }

  private async openFile(): Promise<void> {
    if (this.localPath === '') { return; }
    const ctx = getContext(this) as common.UIAbilityContext;
    const id = this.requestId;
    const path = await findDownloadedUpdate(ctx, this.packageInfo());
    if (id !== this.requestId) { return; }
    if (path === '') {
      this.localPath = '';
      this.failMsg = '安装包已失效，请重新下载';
      this.phase = 3;
      return;
    }
    try {
      await ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri: fileUri.getUriFromPath(path),
        type: 'application/octet-stream',
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      });
    } catch (e) {
      promptAction.showToast({ message: '没有能打开这个文件的应用，请先安装 HAP 签名或安装工具' });
    }
  }

  private openReleasePage(): void {
    const ctx = getContext(this) as common.UIAbilityContext;
    const base = releasesPageUrl();
    const url = this.releaseUrl.startsWith(base + '/') ? this.releaseUrl : base;
    ctx.startAbility({ action: 'ohos.want.action.viewData', uri: url }).catch(() => {
      promptAction.showToast({ message: '无法打开 GitHub 发布页' });
    });
  }

  build() {
    Column({ space: 12 }) {
      Text(`新版本 ${this.newTag}`).fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor(Theme.INK).width('100%')
      Text(`当前 v${this.currentVersion}`).fontSize(13).fontColor(Theme.SECONDARY).width('100%')

      Scroll() {
        Text(this.notes !== '' ? this.notes : '（这个版本没有提供更新说明）')
          .fontSize(13).fontColor(Theme.BODY).lineHeight(21).width('100%')
      }
      .constraintSize({ maxHeight: 200 }).width('100%').scrollBar(BarState.Off)
      .padding(12).borderRadius(12).backgroundColor(Theme.BG)

      if (this.checkingCache) {
        Text('正在检查已下载的更新包…').fontSize(13).fontColor(Theme.SECONDARY).width('100%')
      } else if (this.phase === 0 && this.downloadUrl === '') {
        Text('此版本暂未上传 HAP 附件。').fontSize(13).fontColor(Theme.SECONDARY).width('100%')
      } else if (this.phase === 0) {
        Text('将下载到应用目录，完成后可直接交给其他应用签名 / 安装。')
          .fontSize(11).fontColor(Theme.TERTIARY).width('100%').lineHeight(17)
      } else if (this.phase === 1) {
        Row({ space: 10 }) {
          Progress({ value: this.pct, total: 100 })
            .width('100%').height(6).color(Theme.ACCENT).layoutWeight(1)
          Text(`${this.pct}%`).fontSize(13).fontColor(Theme.ACCENT)
        }.width('100%')
      } else if (this.phase === 2) {
        Text(`下载完成（${this.pct}%）`).fontSize(13).fontColor(Theme.ACCENT).width('100%')
        Text('点击「打开」交给其他应用处理。')
          .fontSize(11).fontColor(Theme.TERTIARY).width('100%')
      } else {
        Text(this.failMsg).fontSize(12).fontColor(Theme.DANGER).width('100%')
      }

      Row({ space: 10 }) {
        Button('稍后').fontSize(15).height(44).borderRadius(12).layoutWeight(1)
          .backgroundColor(Theme.TINT).fontColor(Theme.INK)
          .onClick(() => { this.onClosed(); })
        if (!this.checkingCache && this.phase !== 2 && this.downloadUrl === '') {
          Button('查看发布页').fontSize(15).height(44).borderRadius(12).layoutWeight(1)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.openReleasePage(); })
        } else if (!this.checkingCache && (this.phase === 0 || this.phase === 3)) {
          Button(this.phase === 3 ? '重试' : '下载').fontSize(15).height(44).borderRadius(12).layoutWeight(1)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.startDownload(); })
        } else if (this.phase === 2) {
          Button('打开').fontSize(15).height(44).borderRadius(12).layoutWeight(1)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.openFile(); })
        } else {
          Text(this.checkingCache ? '正在检查…' : '正在下载…').fontSize(14).fontColor(Theme.SECONDARY)
            .layoutWeight(1).textAlign(TextAlign.Center)
        }
      }.width('100%')
    }
    .width('86%').padding(20).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL)
    .border({ width: 1, color: Theme.BORDER })
  }
}
