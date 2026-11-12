/**
 * 内存监控（维护工具）—— 实时看本应用占了多少内存。
 *
 * 数据全部来自 @ohos.hidebug（API 12+，读 /proc 节点，不需要系统权限）：
 *   · PSS：按比例分摊共享库后的实际物理占用，是判断「应用到底吃多少」的主指标
 *   · RSS / 私有内存：VSS 太大没有参考价值，私有内存（脏+净）能看出独占部分
 *   · Native 堆：C 侧分配（解码器、图片位图都在这里）
 *   · ArkTS 虚拟机堆：JS 侧对象
 *   · 系统侧：总内存与可用内存，PSS 占比一眼看出这台机器上压力大不大
 *
 * 进页面自动每秒刷新，离开自动停；同时记录本页观察到的 PSS 峰值。
 */

import { hidebug } from '@kit.PerformanceAnalysisKit';
import { router } from '@kit.ArkUI';
import { Session } from '../store/Session';
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

/** 毫秒 -> hh:mm:ss */
function uptimeLabel(ms: number): string {
  const totalSec = Math.floor(ms / 1000);
  const h = Math.floor(totalSec / 3600);
  const m = Math.floor((totalSec % 3600) / 60);
  const s = totalSec % 60;
  const pad = (v: number): string => v < 10 ? `0${v}` : `${v}`;
  return `${pad(h)}:${pad(m)}:${pad(s)}`;
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
  @State pssPercent: number = 0;
  @State rows: MetricRow[] = [];
  @State autoRefresh: boolean = true;
  @State updatedLabel: string = '';
  @State uptime: string = '00:00:00';

  private timer: number = -1;
  private peakPssKb: number = 0;
  private tick: number = 0;
  private session: Session = Session.getInstance();

  aboutToAppear(): void {
    this.refresh();
    this.startTimer();
  }

  aboutToDisappear(): void {
    this.stopTimer();
  }

  private startTimer(): void {
    if (this.timer >= 0) {
      return;
    }
    // hidebug 读 /proc 有跨进程开销，1 秒足够「实时」，也不至于卡帧
    this.timer = setInterval(() => {
      if (this.autoRefresh) {
        this.refresh();
      }
    }, 1000);
  }

  private stopTimer(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private refresh(): void {
    this.tick++;
    const rows: MetricRow[] = [];
    let pssKb = 0;
    let totalKb = 0;

    // ---- 应用进程（NativeMemInfo 一次拿全，比逐项函数少读几次节点）----
    try {
      const info = hidebug.getAppNativeMemInfo();
      pssKb = Number(info.pss);
      this.pssMb = kbToMb(pssKb);
      this.rssMb = kbToMb(Number(info.rss));
      this.vssMb = kbToMb(Number(info.vss));
      // 独占内存 = 私有脏 + 私有净；共享库分摊的那部分不算
      const privateKb = Number(info.privateDirty) + Number(info.privateClean);
      this.privateMb = kbToMb(privateKb);
      rows.push({ label: 'PSS（实际物理占用）', value: this.pssMb,
        hint: '含按比例分摊的共享库，判断压力主要看它' });
      rows.push({ label: '私有内存', value: this.privateMb,
        hint: 'Private_Dirty + Private_Clean，进程独占部分' });
      rows.push({ label: 'RSS', value: this.rssMb,
        hint: '物理内存（共享库整份计入，通常大于 PSS）' });
      rows.push({ label: 'VSS', value: this.vssMb,
        hint: '虚拟地址空间，数值大不代表真占用' });
    } catch (e) {
      this.pssMb = '不可用';
    }

    // ---- Native 堆（单位是字节）----
    try {
      const heapTotal = Number(hidebug.getNativeHeapSize());
      const heapUsed = Number(hidebug.getNativeHeapAllocatedSize());
      this.nativeHeap = bytesToMb(heapTotal);
      this.nativeUsed = bytesToMb(heapUsed);
      rows.push({ label: 'Native 堆', value: `${bytesToMb(heapUsed)} / ${bytesToMb(heapTotal)}`,
        hint: 'C 侧分配：解码器、图片位图等' });
    } catch (e) {
      this.nativeHeap = '不可用';
    }

    // ---- ArkTS 虚拟机堆（单位 KB）----
    try {
      const vm = hidebug.getAppVMMemoryInfo();
      this.vmHeap = kbToMb(Number(vm.totalHeap));
      this.vmUsed = kbToMb(Number(vm.heapUsed));
      rows.push({ label: 'ArkTS 虚拟机堆', value: `${kbToMb(Number(vm.heapUsed))} / ${kbToMb(Number(vm.totalHeap))}`,
        hint: 'JS/TS 对象' });
    } catch (e) {
      this.vmHeap = '不可用';
    }

    // ---- 系统侧 ----
    try {
      const sys = hidebug.getSystemMemInfo();
      totalKb = Number(sys.totalMem);
      this.systemTotal = kbToMb(totalKb);
      this.systemAvail = kbToMb(Number(sys.availableMem));
      if (totalKb > 0 && pssKb > 0) {
        this.pssPercent = Math.round(pssKb * 100 / totalKb);
      }
      rows.push({ label: '系统总内存', value: this.systemTotal,
        hint: `可用 ${this.systemAvail} · 本应用 PSS 占总内存 ${this.pssPercent}%` });
    } catch (e) {
      this.systemTotal = '不可用';
    }

    // ---- CPU：跨进程开销大，隔一秒采一次 ----
    if (this.tick % 2 === 0) {
      try {
        const usage = hidebug.getCpuUsage();
        this.cpuPercent = `${(usage * 100).toFixed(1)}%`;
        rows.push({ label: 'CPU 占用', value: this.cpuPercent, hint: '进程瞬时 CPU 使用率' });
      } catch (e) {
        this.cpuPercent = '不可用';
      }
    } else if (this.cpuPercent !== '—') {
      rows.push({ label: 'CPU 占用', value: this.cpuPercent, hint: '进程瞬时 CPU 使用率' });
    }

    if (pssKb > this.peakPssKb) {
      this.peakPssKb = pssKb;
      this.peakPssMb = kbToMb(pssKb);
    }
    this.uptime = uptimeLabel(Date.now() - this.session.startedAt);
    rows.push({ label: '本次观察峰值 PSS', value: this.peakPssMb,
      hint: '从进入本页开始记录，最大值' });
    this.rows = rows;
    this.updatedLabel = new Date().toLocaleTimeString();
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
        Text(this.autoRefresh ? '每秒自动刷新' : '已暂停').fontSize(12).fontColor(Theme.SECONDARY)
          .layoutWeight(1)
        Button('刷新').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
          .onClick(() => { this.refresh(); })
      }.width('100%').padding({ left: 16, right: 16, bottom: 10 })

      // 两张大卡：一眼看到「现在占多少」和「跑了多久」
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text('▦').fontSize(13).fontColor(Theme.ACCENT)
            Text('内存占用').fontSize(12).fontColor(Theme.SECONDARY)
          }
          Text(this.pssMb).fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          Text(`峰值 ${this.peakPssMb} · 占系统内存 ${this.pssPercent}%`)
            .fontSize(10).fontColor(Theme.TERTIARY)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .padding(14).borderRadius(16).backgroundColor(Theme.PANEL)
        .border({ width: 1, color: Theme.BORDER })

        Column({ space: 4 }) {
          Row({ space: 6 }) {
            Text('◷').fontSize(13).fontColor(Theme.ACCENT)
            Text('运行时间').fontSize(12).fontColor(Theme.SECONDARY)
          }
          Text(this.uptime).fontSize(26).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          Text('本次启动至今').fontSize(10).fontColor(Theme.TERTIARY)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .padding(14).borderRadius(16).backgroundColor(Theme.PANEL)
        .border({ width: 1, color: Theme.BORDER })
      }.width('100%').padding({ left: 16, right: 16, bottom: 10 })

      if (this.pssPercent > 0) {
        Row({ space: 10 }) {
          Progress({ value: this.pssPercent, total: 100 })
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

      Text(`更新于 ${this.updatedLabel} · 数据来自系统 /proc 节点，仅供观察，不代表用户可释放的量`)
        .fontSize(10).fontColor(Theme.TERTIARY)
        .width('100%').textAlign(TextAlign.Center)
        .padding({ left: 16, right: 16, bottom: 14 })
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG)
  }
}
