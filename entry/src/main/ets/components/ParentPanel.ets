/**
 * 家长验证 + 额度设置面板（对齐 Android v1.3.0/v1.3.1/v1.3.15）。
 *
 * 为什么是乘法题而不是 PIN：小孩看得见家长输 PIN，也会试出来；一道「叁 × 柒」的
 * 大写数字乘法既能挡住学龄前儿童，又不需要家长记密码。
 *
 * 数字面板是自绘的（0–9 / 删除 / 确认），不弹系统输入法，触屏操作一致。
 */

import { ChildrenQuota, makeParentChallenge, parseParentAnswer, ParentChallenge } from '../store/ChildrenQuota';
import { Theme } from '../common/Theme';

const KEYPAD: string[] = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '删除', '0', '确认'];

@Component
export struct ParentPanel {
  quotaRef: ChildrenQuota | null = null;
  onClose: () => void = () => {};
  /** 额度/受管理作品发生变化后通知宿主刷新 */
  onChanged: () => void = () => {};

  /** challenge 验证 / settings 设置 / limit 改每日额度 / bonus 今天加时 */
  /** 宿主传进来的实例可能为 null（非 @State 字段首帧尚未赋值），这里兜到单例 */
  private quota: ChildrenQuota | null = null;
  @State stage: string = 'challenge';
  @State challenge: ParentChallenge = makeParentChallenge();
  @State input: string = '';
  @State errorMsg: string = '';
  @State hintMsg: string = '';
  @State tracked: string[] = [];
  @State limitMinutes: number = 15;
  @State remainingLabel: string = '';
  @State usedPercent: number = 0;

  aboutToAppear(): void {
    this.quota = this.quotaRef !== null ? this.quotaRef : ChildrenQuota.peek();
    if (this.quota === null) {
      this.errorMsg = '额度还没准备好，请稍后重试';
    }
    this.refresh();
  }

  private refresh(): void {
    const quota = this.quota;
    if (quota === null) {
      return;
    }
    this.limitMinutes = quota.dailyMinutes();
    this.remainingLabel = quota.label();
    this.usedPercent = quota.percent();
    this.tracked = quota.trackedTitles();
  }

  private press(key: string): void {
    if (key === '删除') {
      this.input = this.input.length > 0 ? this.input.substring(0, this.input.length - 1) : '';
      return;
    }
    if (key !== '确认') {
      if (this.input.length < 4) {
        this.input += key;
      }
      return;
    }
    this.submit();
  }

  private submit(): void {
    const quota = this.quota;
    if (quota === null) {
      return;
    }
    if (this.stage === 'challenge') {
      if (parseParentAnswer(this.input) === this.challenge.answer) {
        this.stage = 'settings';
        this.input = '';
        this.errorMsg = '';
        this.refresh();
      } else {
        this.errorMsg = '答案不对，换一道题再试';
        this.challenge = makeParentChallenge();
        this.input = '';
      }
      return;
    }
    const minutes = parseParentAnswer(this.input);
    if (minutes < 1 || minutes > 240) {
      this.errorMsg = '请输入 1–240 之间的分钟数';
      this.input = '';
      return;
    }
    if (this.stage === 'limit') {
      quota.setDailyMinutes(minutes).then(() => {
        this.stage = 'settings';
        this.input = '';
        this.errorMsg = '';
        this.hintMsg = `每日额度已改为 ${minutes} 分钟`;
        this.refresh();
        this.onChanged();
      }).catch(() => { this.errorMsg = '保存失败，请重试'; });
      return;
    }
    if (this.stage === 'bonus') {
      quota.addBonusMinutes(minutes).then(() => {
        this.stage = 'settings';
        this.input = '';
        this.errorMsg = '';
        this.hintMsg = `今天已加 ${minutes} 分钟`;
        this.refresh();
        this.onChanged();
      }).catch(() => { this.errorMsg = '保存失败，请重试'; });
    }
  }

  private removeTracked(title: string): void {
    const quota = this.quota;
    if (quota === null) {
      return;
    }
    quota.unmark(title).then((removed: boolean) => {
      this.hintMsg = removed ? `已移出《${title}》` : '该作品不在手动加入列表里';
      this.refresh();
      this.onChanged();
    }).catch(() => {});
  }

  private titleText(): string {
    if (this.stage === 'challenge') { return '家长验证'; }
    if (this.stage === 'limit') { return '设置每日额度'; }
    if (this.stage === 'bonus') { return '仅为今天加时'; }
    return '儿童时间管理';
  }

  @Builder
  keypad() {
    Column({ space: 10 }) {
      Text(this.input === '' ? '—' : this.input)
        .fontSize(30).fontWeight(FontWeight.Bold).fontColor(Theme.KID_INK)
        .width('100%').height(52).textAlign(TextAlign.Center)
        .borderRadius(12).backgroundColor(Theme.KID_TINT)
      GridRow({ columns: 3, gutter: { x: 10, y: 10 } }) {
        ForEach(KEYPAD, (key: string) => {
          GridCol() {
            Text(key)
              .fontSize(key === '确认' || key === '删除' ? 15 : 20)
              .fontWeight(key === '确认' ? FontWeight.Bold : FontWeight.Normal)
              .fontColor(key === '确认' ? Theme.ON_ACCENT : Theme.KID_INK)
              .width('100%').height(50).textAlign(TextAlign.Center)
              .borderRadius(12)
              .backgroundColor(key === '确认' ? Theme.KID_ACCENT : '#FFFFFF')
              .border({ width: 1, color: Theme.KID_BORDER })
              .onClick(() => { this.press(key); })
          }
        }, (key: string) => key)
      }.width('100%')
    }.width('100%')
  }

  @Builder
  settingsView() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Row() {
          Text(this.remainingLabel).fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.KID_INK).layoutWeight(1)
          Text(`每日 ${this.limitMinutes} 分钟`).fontSize(12).fontColor(Theme.KID_SECONDARY)
        }.width('100%')
        Progress({ value: this.usedPercent, total: 100 }).width('100%').height(8)
          .color(Theme.KID_BAR_USED).backgroundColor(Theme.KID_TINT)
      }
      .width('100%').padding(14).borderRadius(14).backgroundColor('#FFFFFF')
      .border({ width: 1, color: Theme.KID_BORDER })

      Row({ space: 10 }) {
        Button('改每日额度').fontSize(14).height(42).layoutWeight(1).borderRadius(12)
          .backgroundColor(Theme.KID_TINT).fontColor(Theme.KID_ACCENT_DEEP)
          .onClick(() => { this.stage = 'limit'; this.input = this.limitMinutes.toString(); this.errorMsg = ''; })
        Button('仅今天加时').fontSize(14).height(42).layoutWeight(1).borderRadius(12)
          .backgroundColor(Theme.KID_ACCENT).fontColor(Theme.ON_ACCENT)
          .onClick(() => { this.stage = 'bonus'; this.input = '15'; this.errorMsg = ''; })
      }.width('100%')

      Text(`手动加入的作品（${this.tracked.length}）`).fontSize(13).fontColor(Theme.KID_SECONDARY)
        .width('100%').margin({ top: 4 })
      if (this.tracked.length === 0) {
        Text('还没有手动加入的作品。内置儿童清单里的动画已自动计时。')
          .fontSize(12).fontColor(Theme.KID_SECONDARY).width('100%')
      } else {
        Column({ space: 6 }) {
          ForEach(this.tracked, (title: string) => {
            Row() {
              Text(title).fontSize(14).fontColor(Theme.KID_INK).layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('移出').fontSize(12).fontColor(Theme.DANGER).padding(6)
                .onClick(() => { this.removeTracked(title); })
            }.width('100%').padding({ left: 12, right: 8, top: 8, bottom: 8 })
            .borderRadius(10).backgroundColor(Theme.KID_TINT)
          }, (title: string) => title)
        }.width('100%')
      }
      Text('内置清单自动识别，不能移除；手动加入的作品可在这里移出。').fontSize(11)
        .fontColor(Theme.KID_SECONDARY).width('100%')
    }.width('100%')
  }

  build() {
    Column({ space: 14 }) {
      Row() {
        Text(this.titleText()).fontSize(18).fontWeight(FontWeight.Bold).fontColor(Theme.KID_INK).layoutWeight(1)
        Text('关闭').fontSize(14).fontColor(Theme.KID_SECONDARY).padding(6)
          .onClick(() => { this.onClose(); })
      }.width('100%')

      if (this.stage === 'challenge') {
        Text(this.challenge.question).fontSize(24).fontWeight(FontWeight.Bold)
          .fontColor(Theme.KID_ACCENT_DEEP).width('100%').textAlign(TextAlign.Center)
        Text('请家长完成这道题').fontSize(12).fontColor(Theme.KID_SECONDARY).width('100%')
          .textAlign(TextAlign.Center)
        this.keypad()
      } else if (this.stage === 'limit' || this.stage === 'bonus') {
        Text(this.stage === 'limit' ? '每天可以看多少分钟？' : '今天额外加多少分钟？')
          .fontSize(14).fontColor(Theme.KID_SECONDARY).width('100%')
        this.keypad()
      } else {
        this.settingsView()
        // 设置阶段不给键盘，避免误触
      }

      if (this.errorMsg !== '') {
        Text(this.errorMsg).fontSize(12).fontColor(Theme.DANGER).width('100%')
      }
      if (this.hintMsg !== '') {
        Text(this.hintMsg).fontSize(12).fontColor(Theme.KID_ACCENT_DEEP).width('100%')
      }
      if (this.stage === 'limit' || this.stage === 'bonus') {
        Text('返回').fontSize(13).fontColor(Theme.KID_SECONDARY).width('100%').textAlign(TextAlign.Center)
          .onClick(() => { this.stage = 'settings'; this.input = ''; this.errorMsg = ''; })
      }
    }
    .width('100%').padding(18).borderRadius(20)
    .backgroundColor(Theme.KID_BG)
    .border({ width: 1, color: Theme.KID_BORDER })
  }
}
