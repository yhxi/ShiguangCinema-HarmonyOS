import { router } from '@kit.ArkUI';
import { Prefs, PlaybackSettings } from '../store/Prefs';
import { Theme } from '../common/Theme';

@Entry
@Component
struct PlaybackSettingsPage {
  @State seekStepSeconds: number = 10;
  @State autoNext: boolean = true;
  @State rememberProgress: boolean = true;
  @State resumeThresholdSeconds: number = 5;
  @State speedIndex: number = 1;
  @State cropVideo: boolean = false;
  @State backgroundPlayback: boolean = false;
  @State choices: string = '';
  @State errorMsg: string = '';
  private prefs: Prefs | null = null;

  aboutToAppear(): void {
    Prefs.get(getContext(this)).then((prefs: Prefs) => {
      this.prefs = prefs;
      prefs.getPlaybackSettings().then((settings: PlaybackSettings) => {
        this.seekStepSeconds = settings.seekStepSeconds;
        this.autoNext = settings.autoNext;
        this.rememberProgress = settings.rememberProgress;
        this.resumeThresholdSeconds = settings.resumeThresholdSeconds;
        this.speedIndex = settings.speedIndex;
        this.cropVideo = settings.cropVideo;
        this.backgroundPlayback = settings.backgroundPlayback;
      }).catch(() => { this.errorMsg = '读取播放设置失败'; });
    }).catch(() => { this.errorMsg = '读取播放设置失败'; });
  }

  private async save(): Promise<void> {
    if (this.prefs === null) { return; }
    const settings: PlaybackSettings = {
      speedIndex: this.speedIndex, autoNext: this.autoNext, cropVideo: this.cropVideo,
      seekStepSeconds: this.seekStepSeconds, rememberProgress: this.rememberProgress,
      resumeThresholdSeconds: this.resumeThresholdSeconds,
      backgroundPlayback: this.backgroundPlayback
    };
    try { await this.prefs.setPlaybackSettings(settings); this.errorMsg = ''; }
    catch (e) { this.errorMsg = '保存失败，请重试'; }
  }

  private choiceValues(): number[] {
    return this.choices === 'step' ? [5, 10, 15, 30, 60] : [0, 5, 10, 30, 60, 120];
  }

  private choose(value: number): void {
    if (this.choices === 'step') { this.seekStepSeconds = value; }
    else { this.resumeThresholdSeconds = value; }
    this.choices = '';
    this.save();
  }

  @Builder
  settingRow(title: string, value: string, action: () => void) {
    Row({ space: 10 }) {
      Text(title).fontSize(15).fontColor(Theme.INK).layoutWeight(1)
      Text(value).fontSize(14).fontColor(Theme.SECONDARY)
      Text('›').fontSize(22).fontColor(Theme.ACCENT)
    }.width('100%').height(58).padding({ left: 16, right: 14 }).borderRadius(Theme.RADIUS_ROW)
      .backgroundColor(Theme.PANEL)
      .border({ width: 1, color: Theme.BORDER })
      .onClick(action)
  }

  @Builder
  fixedRow(title: string, value: string) {
    Row({ space: 10 }) {
      Text(title).fontSize(15).fontColor(Theme.INK).layoutWeight(1)
      Text(value).fontSize(13).fontColor(Theme.TERTIARY)
    }.width('100%').height(58).padding({ left: 16, right: 14 }).borderRadius(Theme.RADIUS_ROW)
      .backgroundColor(Theme.PANEL)
      .border({ width: 1, color: Theme.BORDER })
  }

  build() {
    Stack() {
      Scroll() {
        Column({ space: 9 }) {
          Row({ space: 10 }) {
            Text('▶').fontSize(13).fontColor(Theme.ON_ACCENT)
              .width(28).height(28).textAlign(TextAlign.Center)
              .borderRadius(9).backgroundColor(Theme.ACCENT)
            Text('时光影院').fontSize(23).fontWeight(FontWeight.Bold).fontColor(Theme.INK).layoutWeight(1)
            Button('‹ 返回主页').fontSize(14).height(36).borderRadius(18)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .onClick(() => { router.back({ url: 'pages/Index' }); })
          }.width('100%').padding({ top: 12, bottom: 10 })
          Text('播放设置').fontSize(27).fontWeight(FontWeight.Bold).fontColor(Theme.INK).width('100%')
          Text('点击设置项进行调整；片头片尾位置可在播放页“更多”中设置。')
            .fontSize(15).fontColor(Theme.SECONDARY).width('100%').padding({ bottom: 10 })
          if (this.errorMsg !== '') {
            Text(this.errorMsg).fontColor(Theme.DANGER).fontSize(12).width('100%')
          }
          this.settingRow('快进 / 快退步长', `${this.seekStepSeconds} 秒`, () => { this.choices = 'step'; })
          this.settingRow('自动连播下一集', this.autoNext ? '开' : '关', () => { this.autoNext = !this.autoNext; this.save(); })
          this.settingRow('记住播放进度', this.rememberProgress ? '开' : '关', () => { this.rememberProgress = !this.rememberProgress; this.save(); })
          this.settingRow('续播起始位置', this.resumeThresholdSeconds === 0 ? '始终续播' : `超过 ${this.resumeThresholdSeconds} 秒`, () => { this.choices = 'resume'; })
          this.settingRow('画面比例', this.cropVideo ? '裁切铺满' : '保持原比例', () => { this.cropVideo = !this.cropVideo; this.save(); })
          this.fixedRow('解码方式', '系统自动')
          this.fixedRow('播放缓存', '由系统管理')
          this.settingRow('后台播放', this.backgroundPlayback ? '开' : '关', () => { this.choices = 'background'; })
        }.width('100%').padding({ left: 16, right: 16, bottom: 24 }).alignItems(HorizontalAlign.Start)
      }.width('100%').height('100%').backgroundColor(Theme.BG).scrollBar(BarState.Off)
      if (this.choices !== '') {
        Column({ space: 8 }) {
          Text(this.choices === 'step' ? '快进 / 快退步长' : (this.choices === 'resume' ? '续播起始位置' : '后台播放'))
            .fontSize(17).fontWeight(FontWeight.Bold).fontColor(Theme.INK).width('100%')
            .padding({ bottom: 4 })
          if (this.choices === 'background') {
            Text(`${this.backgroundPlayback ? '◉' : '◯'}　开：退出后继续播放`).fontSize(15).fontColor(Theme.INK)
              .width('100%').padding(12).borderRadius(10).backgroundColor(Theme.BG)
              .onClick(() => { this.backgroundPlayback = true; this.choices = ''; this.save(); })
            Text(`${!this.backgroundPlayback ? '◉' : '◯'}　关：退出即停止并释放`).fontSize(15).fontColor(Theme.INK)
              .width('100%').padding(12).borderRadius(10).backgroundColor(Theme.BG)
              .onClick(() => { this.backgroundPlayback = false; this.choices = ''; this.save(); })
          } else {
            ForEach(this.choiceValues(), (value: number) => {
              Text(value === 0 ? '始终续播' : `${value} 秒`).fontSize(15).fontColor(Theme.INK)
                .width('100%').padding(12).borderRadius(10).backgroundColor(Theme.BG)
                .onClick(() => { this.choose(value); })
            }, (value: number) => value.toString())
          }
          Button('取消').width('100%').height(44).borderRadius(12)
            .backgroundColor(Theme.TINT).fontColor(Theme.INK)
            .onClick(() => { this.choices = ''; })
        }.width('82%').padding(20).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL)
          .border({ width: 1, color: Theme.BORDER })
      }
    }.width('100%').height('100%')
  }
}
