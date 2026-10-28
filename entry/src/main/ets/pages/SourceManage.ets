import { RouteParams } from './RouteParams';
/**
 * 片源管理页 —— 点播源 / 直播源两块：
 *   · 点播源：启用停用开关、自定义添加、删除、测速（走服务端 /api/source/test）、订阅导入
 *   · 直播源：M3U 订阅地址增删、切换当前使用的源
 * 与 Android 版 Prefs.kt 的「不同服务端分别保存」策略一致。
 */

import { router } from '@kit.ArkUI';
import { SourceConfig } from '../api/Models';
import { Api, BUILT_IN_LIVE_SOURCES, liveSourceLabel, parseLiveFromExport, parseSourceList } from '../api/Api';
import { Prefs } from '../store/Prefs';
import { Session } from '../store/Session';
import { Theme } from '../common/Theme';

@Entry
@Component
struct SourceManage {
  @State tab: number = 0;              // 0=点播源 1=直播源
  @State sources: SourceConfig[] = [];
  @State liveList: string[] = [];
  @State liveSelected: number = 0;
  @State testing: string = '';         // 正在测速的源 url
  @State testResult: Map<string, string> = new Map();
  @State testingAll: boolean = false;
  @State failedCount: number = 0;
  private failedUrls: Set<string> = new Set();
  @State importing: boolean = false;
  @State msg: string = '';
  @State showAddDialog: boolean = false;
  @State addName: string = '';
  @State addUrl: string = '';
  @State showSubDialog: boolean = false;
  @State subUrl: string = '';
  @State showLiveDialog: boolean = false;
  @State liveUrl: string = '';

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;

  aboutToAppear(): void {
    Prefs.get(getContext(this)).then(async (p: Prefs) => {
      this.prefs = p;
      await this.reload();
    });
  }

  private async reload(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.sources = await this.prefs.getSources(this.session.serverUrl);
    if (this.sources.length === 0) {
      // 首次进入：把 Session 内存里的合并结果落盘
      this.sources = this.session.sources;
      await this.prefs.setSources(this.session.serverUrl, this.sources);
    }
    this.liveList = await this.prefs.getLiveSources(this.session.serverUrl);
    if (this.liveList.length === 0) {
      this.liveList = BUILT_IN_LIVE_SOURCES;
      this.liveSelected = 0;
      await this.prefs.setLiveSources(this.session.serverUrl, this.liveList, 0);
    } else {
      this.liveSelected = await this.prefs.getSelectedLiveIndex(this.session.serverUrl);
    }
  }

  private async persistSources(): Promise<void> {
    if (this.prefs !== null) {
      await this.prefs.setSources(this.session.serverUrl, this.sources);
      this.session.sources = this.sources;
    }
  }

  private async toggleSource(src: SourceConfig): Promise<void> {
    const out: SourceConfig[] = [];
    for (const s of this.sources) {
      if (s.url === src.url) {
        out.push({ name: s.name, url: s.url, detail: s.detail, isAdult: s.isAdult, enabled: !s.enabled });
      } else {
        out.push(s);
      }
    }
    this.sources = out;
    await this.persistSources();
  }

  private async removeSource(src: SourceConfig): Promise<void> {
    this.sources = this.sources.filter((s: SourceConfig) => s.url !== src.url);
    await this.persistSources();
  }

  private async addCustomSource(): Promise<void> {
    const url = this.addUrl.trim();
    if (url === '' || !url.startsWith('http')) {
      this.msg = '地址要以 http(s):// 开头';
      return;
    }
    if (this.sources.some((s: SourceConfig) => s.url === url)) {
      this.msg = '该源已存在';
      return;
    }
    const name = this.addName.trim() !== '' ? this.addName.trim() : url.split('//')[1] ?? url;
    const sc: SourceConfig = { name: name, url: url, detail: '', isAdult: false, enabled: true };
    this.sources = this.sources.concat([sc]);
    await this.persistSources();
    this.addName = '';
    this.addUrl = '';
    this.showAddDialog = false;
    this.msg = `已添加 ${name}`;
  }

  private async testSource(src: SourceConfig): Promise<void> {
    const api = this.session.api;
    if (api === null) {
      return;
    }
    this.testing = src.url;
    try {
      const result = await api.testSource(src.url);
      this.testResult.set(src.url, result[0] ? `可用 · ${result[1]} 条` : `不可用`);
      this.msg = `${src.name} 测速完成`;
    } catch (e) {
      this.testResult.set(src.url, `测试失败`);
    } finally {
      this.testing = '';
      this.testResult = new Map(this.testResult);
    }
  }

  private async testAllSources(): Promise<void> {
    const api = this.session.api;
    if (api === null || this.testingAll || this.sources.length === 0) { return; }
    this.testingAll = true;
    this.failedUrls = new Set();
    this.failedCount = 0;
    this.testResult = new Map();
    const candidates = this.sources.slice();
    let next = 0;
    let completed = 0;
    let unknown = 0;
    const run = async (): Promise<void> => {
      while (next < candidates.length) {
        const src = candidates[next++];
        let result = '';
        if (this.session.directCms.shouldTryDirect(src)) {
          try {
            const list = await this.session.directCms.search(src, '');
            result = `直连可用 · ${list.length} 条`;
          } catch (e) { /* Ask the server before considering the source unavailable. */ }
        }
        if (result === '') {
          try {
            const tested = await api.testSource(src.url);
            if (tested[0]) { result = `服务端可用 · ${tested[1]} 条`; }
            else { result = '不可用'; this.failedUrls.add(src.url); }
          } catch (e) { result = '检测不确定'; unknown++; }
        }
        this.testResult.set(src.url, result);
        this.testResult = new Map(this.testResult);
        completed++;
        this.msg = `检测 ${completed}/${candidates.length} · 失败 ${this.failedUrls.size} · 不确定 ${unknown}`;
      }
    };
    try {
      await Promise.all([run(), run(), run(), run()]);
      this.failedCount = this.failedUrls.size;
    } finally { this.testingAll = false; }
  }

  private async disableFailedSources(): Promise<void> {
    if (this.testingAll || this.failedUrls.size === 0) { return; }
    let count = 0;
    this.sources = this.sources.map((src: SourceConfig): SourceConfig => {
      if (src.enabled && this.failedUrls.has(src.url)) {
        count++;
        return { name: src.name, url: src.url, detail: src.detail, isAdult: src.isAdult, enabled: false };
      }
      return src;
    });
    try {
      await this.persistSources();
      this.msg = `已停用 ${count} 个失败源；可随时手动启用`;
    } catch (e) { this.msg = `保存失败：${(e as Error).message}`; }
  }

  private async importSubscription(): Promise<void> {
    const url = this.subUrl.trim();
    const api = this.session.api;
    if (url === '' || api === null) {
      return;
    }
    this.importing = true;
    this.msg = '导入中…';
    try {
      const list = await api.importSourceList(url);
      if (list.length === 0) {
        this.msg = '订阅内容为空或不支持的格式';
      } else {
        const existing = new Set<string>(this.sources.map((s: SourceConfig) => s.url));
        const fresh: SourceConfig[] = [];
        for (const sc of list) {
          if (!existing.has(sc.url)) {
            fresh.push(sc);
            existing.add(sc.url);
          }
        }
        this.sources = this.sources.concat(fresh);
        await this.persistSources();
        this.msg = `导入完成：新增 ${fresh.length} / 共 ${list.length} 条`;
        this.subUrl = '';
        this.showSubDialog = false;
      }
    } catch (e) {
      this.msg = `导入失败：${(e as Error).message}`;
    } finally {
      this.importing = false;
    }
  }

  private async importFromScanResult(text: string): Promise<void> {
    // 与 Android 版一致：扫码内容可能是订阅链接或导出文件文本
    const trimmed = text.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      const api = this.session.api;
      if (api === null) {
        return;
      }
      this.importing = true;
      this.msg = '扫码导入中…';
      try {
        const list = await api.importSourceList(trimmed);
        const existing = new Set<string>(this.sources.map((s: SourceConfig) => s.url));
        const fresh: SourceConfig[] = list.filter((s: SourceConfig) => !existing.has(s.url));
        this.sources = this.sources.concat(fresh);
        await this.persistSources();
        // 导出文件里若带直播订阅也一并收下
        const lives = parseLiveFromExport(trimmed);
        this.msg = `扫码导入：新增 ${fresh.length} 条点播源` + (lives.length > 0 ? `，${lives.length} 条直播订阅` : '');
      } catch (e) {
        this.msg = `扫码导入失败：${(e as Error).message}`;
      } finally {
        this.importing = false;
      }
    } else if (trimmed.includes('sources') || trimmed.includes('sites')) {
      const list = parseSourceList(trimmed);
      const existing = new Set<string>(this.sources.map((s: SourceConfig) => s.url));
      const fresh: SourceConfig[] = list.filter((s: SourceConfig) => !existing.has(s.url));
      this.sources = this.sources.concat(fresh);
      await this.persistSources();
      this.msg = `文本解析导入：新增 ${fresh.length} 条`;
    } else {
      this.msg = '二维码内容无法识别为片源';
    }
  }

  private async addLiveSource(): Promise<void> {
    const url = this.liveUrl.trim();
    if (url === '' || !url.startsWith('http')) {
      this.msg = '直播订阅地址要以 http(s):// 开头';
      return;
    }
    if (!this.liveList.includes(url)) {
      this.liveList = this.liveList.concat([url]);
    }
    await this.selectLive(this.liveList.length - 1);
    this.liveUrl = '';
    this.showLiveDialog = false;
  }

  private async selectLive(idx: number): Promise<void> {
    this.liveSelected = idx;
    if (this.prefs !== null) {
      await this.prefs.setLiveSources(this.session.serverUrl, this.liveList, idx);
    }
    this.msg = `直播源已切换：${liveSourceLabel(this.liveList[idx])}`;
  }

  private async removeLive(idx: number): Promise<void> {
    if (this.liveList.length <= 1) {
      this.msg = '至少保留一个直播源';
      return;
    }
    this.liveList = this.liveList.filter((_: string, i: number) => i !== idx);
    if (this.liveSelected >= this.liveList.length) {
      this.liveSelected = this.liveList.length - 1;
    }
    if (this.prefs !== null) {
      await this.prefs.setLiveSources(this.session.serverUrl, this.liveList, this.liveSelected);
    }
  }

  @Builder
  addSourceDialog() {
    Column({ space: 12 }) {
      Text('添加自定义点播源').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
      TextInput({ placeholder: '名称（可留空）', text: this.addName })
        .fontSize(14).height(46).borderRadius(12)
        .backgroundColor(Theme.BG).fontColor(Theme.INK).placeholderColor(Theme.SECONDARY)
        .onChange((v: string) => { this.addName = v; })
      TextInput({ placeholder: '接口地址（标准苹果CMS）', text: this.addUrl })
        .fontSize(14).height(46).borderRadius(12)
        .backgroundColor(Theme.BG).fontColor(Theme.INK).placeholderColor(Theme.SECONDARY)
        .onChange((v: string) => { this.addUrl = v; })
      Row({ space: 10 }) {
        Button('取消').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.TINT).fontColor(Theme.INK).layoutWeight(1)
          .onClick(() => { this.showAddDialog = false; })
        Button('添加').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT).layoutWeight(1)
          .onClick(() => { this.addCustomSource(); })
      }.width('100%')
    }
    .padding(18).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL).width('86%')
    .border({ width: 1, color: Theme.BORDER })
  }

  @Builder
  subImportDialog() {
    Column({ space: 12 }) {
      Text('订阅导入').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
      Text('支持 LibreTV 订阅、网页版导出文件地址、TVBOX 配置')
        .fontSize(12).fontColor(Theme.SECONDARY)
      TextInput({ placeholder: '订阅地址', text: this.subUrl })
        .fontSize(14).height(46).borderRadius(12)
        .backgroundColor(Theme.BG).fontColor(Theme.INK).placeholderColor(Theme.SECONDARY)
        .onChange((v: string) => { this.subUrl = v; })
      Row({ space: 10 }) {
        Button('取消').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.TINT).fontColor(Theme.INK).layoutWeight(1)
          .onClick(() => { this.showSubDialog = false; })
        Button(this.importing ? '导入中…' : '导入').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT).layoutWeight(1)
          .enabled(!this.importing)
          .onClick(() => { this.importSubscription(); })
      }.width('100%')
    }
    .padding(18).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL).width('86%')
    .border({ width: 1, color: Theme.BORDER })
  }

  @Builder
  addLiveDialog() {
    Column({ space: 12 }) {
      Text('添加直播订阅（M3U）').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
      TextInput({ placeholder: 'M3U 播放单地址', text: this.liveUrl })
        .fontSize(14).height(46).borderRadius(12)
        .backgroundColor(Theme.BG).fontColor(Theme.INK).placeholderColor(Theme.SECONDARY)
        .onChange((v: string) => { this.liveUrl = v; })
      Row({ space: 10 }) {
        Button('取消').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.TINT).fontColor(Theme.INK).layoutWeight(1)
          .onClick(() => { this.showLiveDialog = false; })
        Button('添加').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT).layoutWeight(1)
          .onClick(() => { this.addLiveSource(); })
      }.width('100%')
    }
    .padding(18).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL).width('86%')
    .border({ width: 1, color: Theme.BORDER })
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 10 }) {
          Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
            .width(26).height(26).textAlign(TextAlign.Center)
            .borderRadius(8).backgroundColor(Theme.ACCENT)
          Text('片源管理').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          Blank()
          Button('扫码导入').fontSize(13).height(34).borderRadius(17)
            .backgroundColor(Theme.PANEL).fontColor(Theme.ACCENT)
            .onClick(() => {
              router.pushUrl({
                url: 'pages/Scan',
                params: { mode: 'source' } as RouteParams
              });
            })
          Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
            .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
            .onClick(() => { router.back(); })
        }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 10 })

        Row({ space: 8 }) {
          Button('点播源').fontSize(13).height(36).borderRadius(18).layoutWeight(1)
            .backgroundColor(this.tab === 0 ? Theme.ACCENT : Theme.PANEL)
            .fontColor(this.tab === 0 ? Theme.ON_ACCENT : Theme.SECONDARY)
            .onClick(() => { this.tab = 0; })
          Button('直播源').fontSize(13).height(36).borderRadius(18).layoutWeight(1)
            .backgroundColor(this.tab === 1 ? Theme.ACCENT : Theme.PANEL)
            .fontColor(this.tab === 1 ? Theme.ON_ACCENT : Theme.SECONDARY)
            .onClick(() => { this.tab = 1; })
        }
        .width('100%').padding({ left: 16, right: 16, bottom: 8 })

        if (this.msg !== '') {
          Text(this.msg).fontSize(12).fontColor(Theme.SECONDARY)
            .width('100%').padding({ left: 16, right: 16, bottom: 8 })
            .maxLines(2)
        }

        if (this.tab === 0) {
          Row({ space: 8 }) {
            Button('＋ 添加源').fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .onClick(() => { this.showAddDialog = true; })
            Button('订阅导入').fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .onClick(() => { this.showSubDialog = true; })
          }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

          Row({ space: 8 }) {
            Button(this.testingAll ? '检测中…' : '检测全部').fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
              .enabled(!this.testingAll && this.testing === '' && this.sources.length > 0)
              .onClick(() => { this.testAllSources(); })
            Button(`停用失败源 (${this.failedCount})`).fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .enabled(!this.testingAll && this.failedCount > 0)
              .onClick(() => { this.disableFailedSources(); })
          }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

          List({ space: 7 }) {
            ForEach(this.sources, (src: SourceConfig) => {
              ListItem() {
                Row({ space: 8 }) {
                  Toggle({ type: ToggleType.Checkbox, isOn: src.enabled })
                    .selectedColor(Theme.ACCENT)
                    .onChange(() => { this.toggleSource(src); })
                  Column({ space: 3 }) {
                    Text(src.name).fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(src.enabled ? Theme.INK : Theme.TERTIARY)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(src.url).fontSize(10).fontColor(Theme.TERTIARY)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    if (this.testResult.has(src.url)) {
                      Text(this.testResult.get(src.url) ?? '')
                        .fontSize(10).fontColor(this.testResult.get(src.url) === '不可用' ? Theme.DANGER :
                          (this.testResult.get(src.url) === '检测不确定' ? '#B4761A' : Theme.ACCENT))
                    }
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)

                  if (this.testing === src.url) {
                    LoadingProgress().width(20).height(20).color(Theme.ACCENT)
                  } else {
                    Text('测速').fontSize(12).fontColor(Theme.ACCENT).padding(6)
                      .onClick(() => { if (!this.testingAll) { this.testSource(src); } })
                  }
                  Text('删').fontSize(12).fontColor(Theme.DANGER).padding(6)
                    .onClick(() => { this.removeSource(src); })
                }
                .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
                .border({ width: 1, color: Theme.BORDER })
              }
            }, (src: SourceConfig) => src.url + src.enabled.toString())
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
          .scrollBar(BarState.Off)
        } else {
          Row() {
            Button('＋ 添加直播订阅').fontSize(13).height(38).borderRadius(12)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .onClick(() => { this.showLiveDialog = true; })
          }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

          List({ space: 7 }) {
            ForEach(this.liveList, (url: string, idx: number) => {
              ListItem() {
                Row({ space: 10 }) {
                  Radio({ value: idx.toString(), group: 'live' })
                    .checked(this.liveSelected === idx)
                    .onChange(() => { this.selectLive(idx); })
                    .radioStyle({ checkedBackgroundColor: Theme.ACCENT })
                  Column({ space: 3 }) {
                    Text(liveSourceLabel(url)).fontSize(14).fontWeight(FontWeight.Medium)
                      .fontColor(this.liveSelected === idx ? Theme.INK : Theme.SECONDARY)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(url).fontSize(10).fontColor(Theme.TERTIARY)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('删').fontSize(12).fontColor(Theme.DANGER).padding(6)
                    .onClick(() => { this.removeLive(idx); })
                }
                .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 10 })
                .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
                .border({ width: 1, color: Theme.BORDER })
                .onClick(() => { this.selectLive(idx); })
              }
            }, (url: string) => url)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
          .scrollBar(BarState.Off)
        }
      }
      .width('100%').height('100%')
      .backgroundColor(Theme.BG)

      if (this.showAddDialog) {
        this.addSourceDialog()
      }
      if (this.showSubDialog) {
        this.subImportDialog()
      }
      if (this.showLiveDialog) {
        this.addLiveDialog()
      }
    }
    .width('100%').height('100%')
  }
}
