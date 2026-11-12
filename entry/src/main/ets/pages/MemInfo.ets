/** 应用内存采样：进程指标在后台采集，当前 VM 堆在界面线程读取。 */

import { hidebug } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { MemorySample, sampleMemory } from '../common/MemorySample';
import { Theme } from '../common/Theme';

interface MetricRow {
  label: string;
  value: string;
  hint: string;
}

/** 字节 -> MB 字符串 */
function bytesToMb(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/** KB -> MB 字符串 */
function kbToMb(kb: number): string {
  return `${(kb / 1024).toFixed(1)} MB`;
}

@Entry
@Component
struct MemInfoPage {
  @State pssMb: string = '—';
  @State rssMb: string = '—';
  @State privateMb: string = '—';
  @State vssMb: string = '—';
  @State nativeHeap: string = '—';
  @State nativeUsed: string = '—';
  @State vmHeap: string = '—';
  @State vmUsed: string = '—';
  @State systemTotal: string = '—';
  @State systemAvail: string = '—';
  @State cpuPercent: string = '—';
  @State peakPssMb: string = '—';
  @State pssPercent: number = -1;
  @State rows: MetricRow[] = [];
  @State autoRefresh: boolean = true;
  @State updatedLabel: string = '';

  private timer: number = -1;
  private peakPssKb: number = 0;
  private sampling: boolean = false;
  private active: boolean = false;
  private generation: number = 0;

  aboutToAppear(): void {
    this.active = true;
    this.refresh();
    this.startTimer();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.generation++;
    this.stopTimer();
  }

  private startTimer(): void {
    if (this.timer >= 0) {
      return;
    }
    // 采集未结束时跳过本轮，避免积压。
    this.timer = setInterval(() => {
      if (this.autoRefresh) {
        this.refresh();
      }
    }, 2000);
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async refresh(): Promise<void> {
    if (this.sampling) { return; }
    this.sampling = true;
    const generation = this.generation;
    // VM 信息必须在此线程采样：放到 taskpool 会读到后台线程自己的 VM。
    let vmTotal = -1;
    let vmUsed = -1;
    try {
      const vm = hidebug.getAppVMMemoryInfo();
      vmTotal = Number(vm.totalHeap);
      vmUsed = Number(vm.heapUsed);
    } catch (e) { /* 显示不可用 */ }
    try {
      const sample = await taskpool.execute(sampleMemory) as MemorySample;
      if (!this.active || generation !== this.generation) { return; }
      this.applySample(sample, vmTotal, vmUsed);
    } catch (e) {
      if (!this.active || generation !== this.generation) { return; }
      const failed: MemorySample = { pss: -1, rss: -1, vss: -1, privateKb: -1,
        nativeTotal: -1, nativeUsed: -1, systemTotal: -1, systemAvailable: -1, sampledAt: Date.now() };
      this.applySample(failed, vmTotal, vmUsed);
    } finally { this.sampling = false; }
  }

  private applySample(sample: MemorySample, vmTotal: number, vmUsed: number): void {
    const rows: MetricRow[] = [];
    const kb = (value: number): string => isFinite(value) && value >= 0 ? kbToMb(value) : '不可用';
    const bytes = (value: number): string => isFinite(value) && value >= 0 ? bytesToMb(value) : '不可用';
    this.pssMb = kb(sample.pss);
    this.rssMb = kb(sample.rss);
    this.privateMb = kb(sample.privateKb);
    this.vssMb = kb(sample.vss);
    this.nativeHeap = bytes(sample.nativeTotal);
    this.nativeUsed = bytes(sample.nativeUsed);
    this.vmHeap = kb(vmTotal);
    this.vmUsed = kb(vmUsed);
    this.systemTotal = kb(sample.systemTotal);
    this.systemAvail = kb(sample.systemAvailable);
    this.pssPercent = sample.pss >= 0 && sample.systemTotal > 0 &&
      isFinite(sample.pss) && isFinite(sample.systemTotal) ? sample.pss * 100 / sample.systemTotal : -1;
    rows.push({ label: 'PSS（含 SwapPSS）', value: this.pssMb,
      hint: '共享内存按比例分摊，含换出部分；适合观察应用占用趋势' });
    rows.push({ label: '私有内存', value: this.privateMb, hint: '私有干净页与脏页，不含共享部分' });
    rows.push({ label: 'RSS', value: this.rssMb, hint: '驻留物理内存，共享页按整份计入' });
    rows.push({ label: 'VSS', value: this.vssMb, hint: '虚拟地址空间，不等于物理内存占用' });
    rows.push({ label: 'Native 堆', value: `${this.nativeUsed} / ${this.nativeHeap}`,
      hint: '分配器已用 / 持有总量，不涵盖全部图形和媒体内存' });
    rows.push({ label: '当前界面 VM 堆', value: `${this.vmUsed} / ${this.vmHeap}`,
      hint: '当前 VM 已用 / 堆总量，不代表所有 VM 的总和' });
    rows.push({ label: '系统内存', value: this.systemTotal, hint: `可用 ${this.systemAvail}` });
    if (isFinite(sample.pss) && sample.pss >= 0 && sample.pss > this.peakPssKb) {
      this.peakPssKb = sample.pss;
      this.peakPssMb = kbToMb(sample.pss);
    }
    rows.push({ label: '本页采样峰值 PSS', value: this.peakPssMb,
      hint: '仅统计本页采样，可能错过短暂峰值' });
    this.rows = rows;
    this.updatedLabel = new Date(sample.sampledAt).toLocaleTimeString();
  }

  @Builder
  statRow(item: MetricRow) {
    Column({ space: 3 }) {
      Row({ space: 8 }) {
        Text(item.label).fontSize(13).fontColor(Theme.INK).layoutWeight(1)
        Text(item.value).fontSize(14).fontWeight(FontWeight.Bold).fontColor(Theme.ACCENT)
      }.width('100%')
      Text(item.hint).fontSize(10).fontColor(Theme.TERTIARY).width('100%')
    }
    .width('100%').padding({ left: 14, right: 14, top: 9, bottom: 9 })
    .borderRadius(12).backgroundColor(Theme.PANEL)
    .border({ width: 1, color: Theme.BORDER })
  }

  build() {
    Column() {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Text('内存监控').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Blank()
        Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Row({ space: 10 }) {
        Toggle({ type: ToggleType.Switch, isOn: this.autoRefresh })
          .selectedColor(Theme.ACCENT)
          .width(40).height(22)
          .onChange((on: boolean) => { this.autoRefresh = on; })
        Text(this.autoRefresh ? '每 2 秒自动刷新' : '已暂停').fontSize(12).fontColor(Theme.SECONDARY)
          .layoutWeight(1)
        Button('刷新').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
          .onClick(() => { this.refresh(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 10 })

      Column({ space: 4 }) {
        Text('应用内存 · PSS（含 SwapPSS）').fontSize(12).fontColor(Theme.SECONDARY)
        Text(this.pssMb).fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Text(this.pssPercent >= 0 ? `本页采样峰值 ${this.peakPssMb} · 占系统总内存 ${this.pssPercent.toFixed(1)}%`
          : `本页采样峰值 ${this.peakPssMb} · 系统占比不可用`)
          .fontSize(10).fontColor(Theme.TERTIARY)
      }.alignItems(HorizontalAlign.Start).width('100%').padding(14).borderRadius(16)
        .backgroundColor(Theme.PANEL).border({ width: 1, color: Theme.BORDER })
        .margin({ left: 16, right: 16, bottom: 10 })

      if (this.pssPercent >= 0) {
        Row({ space: 10 }) {
          Progress({ value: Math.min(100, this.pssPercent), total: 100 })
            .color(Theme.ACCENT).backgroundColor(Theme.TINT)
            .layoutWeight(1).height(10)
          Text(`系统总内存 ${this.systemTotal} · 可用 ${this.systemAvail}`)
            .fontSize(11).fontColor(Theme.SECONDARY)
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      }

      List({ space: 7 }) {
        ForEach(this.rows, (item: MetricRow) => {
          ListItem() {
            this.statRow(item)
          }
        }, (item: MetricRow) => item.label + item.value)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 8 })
      .scrollBar(BarState.Off)

      Text(`更新于 ${this.updatedLabel} · 进程指标为后台采样，VM 堆为当前界面线程；仅供观察`)
        .fontSize(10).fontColor(Theme.TERTIARY)
        .width('100%').textAlign(TextAlign.Center)
        .padding({ left: 16, right: 16, bottom: 14 })
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG)
  }
}
