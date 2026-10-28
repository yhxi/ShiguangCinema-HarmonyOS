/**
 * 更新弹窗：显示新版本说明，应用内下载（带百分比进度），完成后"打开"。
 * 首页和设置页共用。HAP 无法由应用自行安装，下载后交给用户选择的应用处理
 * （未签名包先签名再安装）。
 */

import { common, wantConstant } from '@kit.AbilityKit';
import { fileUri } from '@kit.CoreFileKit';
import { promptAction } from '@kit.ArkUI';
import { downloadUpdateFile } from '../api/UpdateDownloader';
import { Theme } from '../common/Theme';

@Component
export struct UpdateDialog {
  @Prop newTag: string = '';
  @Prop currentVersion: string = '';
  @Prop notes: string = '';
  @Prop downloadUrl: string = '';
  onClosed: () => void = () => {};

  /** 0 待下载 1 下载中 2 已完成 3 失败 */
  @State phase: number = 0;
  @State pct: number = 0;
  @State localPath: string = '';
  @State failMsg: string = '';

  private startDownload(): void {
    if (this.phase === 1 || this.downloadUrl === '') { return; }
    this.phase = 1;
    this.pct = 0;
    const ctx = getContext(this) as common.UIAbilityContext;
    downloadUpdateFile(ctx, this.downloadUrl,
      `ShiguangCinema-HarmonyOS-${this.newTag}-unsigned.hap`,
      (pct: number) => { this.pct = pct; })
      .then((result) => {
        if (result.ok) {
          this.localPath = result.path;
          this.phase = 2;
        } else {
          this.failMsg = result.message !== undefined ? result.message : '下载失败';
          this.phase = 3;
        }
      })
      .catch((e: Object) => {
        this.failMsg = (e as Error).message;
        this.phase = 3;
      });
  }

  /** 用系统能力把沙箱里的 HAP 交给别的应用处理（签名 / 安装） */
  private openFile(): void {
    if (this.localPath === '') { return; }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const uri = fileUri.getUriFromPath(this.localPath);
      ctx.startAbility({
        action: 'ohos.want.action.viewData',
        uri: uri,
        type: 'application/octet-stream',
        flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
      }).catch(() => {
        promptAction.showToast({ message: '没有能打开这个文件的应用' });
      });
    } catch (e) {
      promptAction.showToast({ message: '打开失败' });
    }
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

      if (this.phase === 0) {
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
        if (this.phase === 0 || this.phase === 3) {
          Button(this.phase === 3 ? '重试' : '下载').fontSize(15).height(44).borderRadius(12).layoutWeight(1)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.startDownload(); })
        } else if (this.phase === 2) {
          Button('打开').fontSize(15).height(44).borderRadius(12).layoutWeight(1)
            .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
            .onClick(() => { this.openFile(); })
        } else {
          Text('正在下载…').fontSize(14).fontColor(Theme.SECONDARY)
            .layoutWeight(1).textAlign(TextAlign.Center)
        }
      }.width('100%')
    }
    .width('86%').padding(20).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL)
    .border({ width: 1, color: Theme.BORDER })
  }
}
