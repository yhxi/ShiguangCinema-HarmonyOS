import { RouteParams } from './RouteParams';
/**
 * 片源管理页 —— 点播源 / 直播源两块。
 *
 * 21 个内置源 + 用户自定义源之后，原来的「一个平面列表 + 逐个测速」已经不好用：
 *   · 分不清哪些是内置、哪些是自己加的
 *   · 想找某个源只能一路往下翻
 *   · 测速结果只在内存里，退出就没了，下次进来还得再测一遍
 *   · 批量操作只能「停用失败源」，不能按筛选结果批量启停
 *
 * 现在改为：
 *   · 顶部统计（共 / 启用 / 可用 / 停用）+ 搜索 + 筛选（启用、停用、可用、不可用、内置、自定义）
 *   · 检测全部并发 6 路，带进度；结果（可用性、条目数、延迟、时间）写入本地
 *   · 重开页面先用上次结果标记状态，并显示「3 小时前检测」
 *   · 批量：启用全部 / 停用全部（作用于当前筛选结果）、停用失败源、恢复内置源
 *   · 列表默认可用优先，可切回原顺序
 */

import { promptAction, router } from '@kit.ArkUI';
import { SourceConfig, builtInSources } from '../api/Models';
import { BUILT_IN_LIVE_SOURCES, liveSourceLabel } from '../api/Api';
import { Prefs } from '../store/Prefs';
import { Session } from '../store/Session';
import { HealthRecord, SourceHealth } from '../store/SourceHealth';
import { parseSourceLines } from '../common/SourceText';
import { Theme } from '../common/Theme';

const TEST_CONCURRENCY = 6;

interface FilterChip {
  key: string;
  label: string;
}

const CHIPS: FilterChip[] = [
  { key: 'all', label: '全部' },
  { key: 'on', label: '已启用' },
  { key: 'off', label: '已停用' },
  { key: 'ok', label: '可用' },
  { key: 'bad', label: '不可用' },
  { key: 'builtin', label: '内置' },
  { key: 'custom', label: '自定义' }
];

@Entry
@Component
struct SourceManage {
  @State tab: number = 0;              // 0=点播源 1=直播源
  @State sources: SourceConfig[] = [];
  @State liveList: string[] = [];
  @State liveSelected: number = 0;
  @State testing: string = '';
  /** url -> 健康记录；改动时整体替换以便触发刷新 */
  @State health: Map<string, HealthRecord> = new Map();
  @State testingAll: boolean = false;
  @State progressDone: number = 0;
  @State progressTotal: number = 0;
  @State query: string = '';
  @State filter: string = 'all';
  @State sortByHealth: boolean = true;
  @State importing: boolean = false;
  @State msg: string = '';
  @State showAddDialog: boolean = false;
  @State addName: string = '';
  @State addUrl: string = '';
  @State showSubDialog: boolean = false;
  @State subUrl: string = '';
  @State showLiveDialog: boolean = false;
  @State liveUrl: string = '';
  @State showImportDialog: boolean = false;
  @State importText: string = '';

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;
  private builtInUrls: Set<string> = new Set();

  aboutToAppear(): void {
    for (const src of builtInSources()) {
      this.builtInUrls.add(src.url);
    }
    Prefs.get(getContext(this)).then(async (p: Prefs) => {
      this.prefs = p;
      this.health = SourceHealth.load(p);
      await this.reload();
    });
  }

  /** 从扫码页或 Live 页返回时刷新，避免导入完了列表还是旧的 */
  onPageShow(): void {
    if (this.prefs === null || this.testingAll) {
      return;
    }
    this.reload().catch(() => {});
  }

  private async reload(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    this.sources = await this.prefs.getSources(this.session.serverUrl);
    if (this.sources.length === 0) {
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

  private async persistHealth(): Promise<void> {
    if (this.prefs !== null) {
      await SourceHealth.save(this.prefs, this.health);
    }
  }

  private record(url: string, ok: boolean, count: number, ms: number, via: string): void {
    const next = new Map(this.health);
    const item: HealthRecord = { ok: ok, count: count, ms: ms, at: Date.now(), via: via };
    next.set(url, item);
    this.health = next;
  }

  // ------------------------------------------------------------ 列表与统计

  private isBuiltIn(url: string): boolean {
    return this.builtInUrls.has(url);
  }

  private matchesFilter(src: SourceConfig): boolean {
    const h = this.health.get(src.url);
    if (this.filter === 'on') { return src.enabled; }
    if (this.filter === 'off') { return !src.enabled; }
    if (this.filter === 'ok') { return h !== undefined && h.ok; }
    if (this.filter === 'bad') { return h !== undefined && !h.ok; }
    if (this.filter === 'builtin') { return this.isBuiltIn(src.url); }
    if (this.filter === 'custom') { return !this.isBuiltIn(src.url); }
    return true;
  }

  private matchesQuery(src: SourceConfig): boolean {
    const kw = this.query.trim().toLowerCase();
    if (kw === '') { return true; }
    return src.name.toLowerCase().includes(kw) || src.url.toLowerCase().includes(kw);
  }

  /** 当前筛选 + 搜索命中的源；批量操作与渲染都用这一份，保证看到什么就操作什么 */
  private visibleSources(): SourceConfig[] {
    const out: SourceConfig[] = [];
    for (const src of this.sources) {
      if (this.matchesFilter(src) && this.matchesQuery(src)) {
        out.push(src);
      }
    }
    if (!this.sortByHealth) {
      return out;
    }
    // 可用优先 → 未检测 → 不可用；同组内保持原顺序（Array.sort 在 JS 里已稳定）
    return out.sort((a: SourceConfig, b: SourceConfig): number => {
      return this.rank(a) - this.rank(b);
    });
  }

  private rank(src: SourceConfig): number {
    const h = this.health.get(src.url);
    const healthRank = h === undefined ? 1 : (h.ok ? 0 : 2);
    return healthRank * 2 + (src.enabled ? 0 : 1);
  }

  private enabledCount(): number {
    let n = 0;
    for (const src of this.sources) {
      if (src.enabled) { n++; }
    }
    return n;
  }

  private okCount(): number {
    let n = 0;
    for (const src of this.sources) {
      const h = this.health.get(src.url);
      if (h !== undefined && h.ok) { n++; }
    }
    return n;
  }

  private badCount(): number {
    let n = 0;
    for (const src of this.sources) {
      const h = this.health.get(src.url);
      if (h !== undefined && !h.ok) { n++; }
    }
    return n;
  }

  private statusLine(src: SourceConfig): string {
    const h = this.health.get(src.url);
    if (h === undefined) {
      return `未检测 · ${this.isBuiltIn(src.url) ? '内置' : '自定义'}`;
    }
    const head = h.ok ? `可用 · ${h.count} 条 · ${h.ms} ms` : '不可用';
    const via = h.via === 'direct' ? '直连' : '服务端';
    return `${head} · ${via} · ${SourceHealth.ageLabel(h)}`;
  }

  private statusColor(src: SourceConfig): string {
    const h = this.health.get(src.url);
    if (h === undefined) { return Theme.TERTIARY; }
    return h.ok ? Theme.ACCENT : Theme.DANGER;
  }

  // ------------------------------------------------------------ 单个操作

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

  /** 删除：内置源属于「可恢复」的资源，先确认再删，避免误触 */
  private async removeSource(src: SourceConfig): Promise<void> {
    const builtIn = this.isBuiltIn(src.url);
    const result = await promptAction.showDialog({
      title: builtIn ? '删除内置源？' : '删除这个源？',
      message: builtIn
        ? `《${src.name}》是内置源。删除后可以用「恢复内置源」一键加回来。`
        : `《${src.name}》将从列表移除，之后不再参与搜索。`,
      buttons: [{ text: '取消', color: Theme.INK }, { text: '删除', color: Theme.DANGER }]
    });
    if (result.index !== 1) {
      return;
    }
    this.sources = this.sources.filter((s: SourceConfig) => s.url !== src.url);
    await this.persistSources();
    this.msg = `已删除 ${src.name}`;
  }

  private async testSource(src: SourceConfig): Promise<void> {
    const api = this.session.api;
    if (api === null || this.testing !== '' || this.testingAll) {
      return;
    }
    this.testing = src.url;
    const started = Date.now();
    try {
      if (this.session.directCms.shouldTryDirect(src)) {
        try {
          const list = await this.session.directCms.search(src, '');
          this.record(src.url, true, list.length, Date.now() - started, 'direct');
          await this.persistHealth();
          this.msg = `${src.name} 直连可用 · ${list.length} 条 · ${Date.now() - started} ms`;
          return;
        } catch (e) {
          // 直连失败再问服务端，别急着判死
        }
      }
      const tested = await api.testSource(src.url);
      this.record(src.url, tested[0], tested[1], Date.now() - started, 'server');
      await this.persistHealth();
      this.msg = tested[0]
        ? `${src.name} 服务端可用 · ${tested[1]} 条 · ${Date.now() - started} ms`
        : `${src.name} 不可用`;
    } catch (e) {
      this.record(src.url, false, 0, Date.now() - started, 'server');
      await this.persistHealth();
      this.msg = `${src.name} 检测不确定（网络或服务端异常）`;
    } finally {
      this.testing = '';
    }
  }

  // ------------------------------------------------------------ 批量操作

  /** 检测全部：并发 6 路，带进度；中途退出页面不写坏数据（结果逐条落盘） */
  private async testAllSources(): Promise<void> {
    const api = this.session.api;
    if (api === null || this.testingAll || this.sources.length === 0) {
      return;
    }
    this.testingAll = true;
    const candidates = this.sources.slice();
    this.progressTotal = candidates.length;
    this.progressDone = 0;
    this.msg = `开始检测 ${candidates.length} 个源…`;
    let next = 0;
    let ok = 0;
    let bad = 0;
    const run = async (): Promise<void> => {
      while (next < candidates.length) {
        const src = candidates[next++];
        const started = Date.now();
        let done = false;
        if (this.session.directCms.shouldTryDirect(src)) {
          try {
            const list = await this.session.directCms.search(src, '');
            this.record(src.url, true, list.length, Date.now() - started, 'direct');
            done = true;
            ok++;
          } catch (e) {
            // 交给服务端兜底
          }
        }
        if (!done) {
          try {
            const tested = await api.testSource(src.url);
            this.record(src.url, tested[0], tested[1], Date.now() - started, 'server');
            if (tested[0]) { ok++; } else { bad++; }
          } catch (e) {
            this.record(src.url, false, 0, Date.now() - started, 'server');
            bad++;
          }
        }
        this.progressDone++;
        this.msg = `检测中 ${this.progressDone}/${this.progressTotal} · 可用 ${ok} · 不可用 ${bad}`;
        if (this.progressDone % 4 === 0) {
          await this.persistHealth();
        }
      }
    };
    try {
      const workers: Promise<void>[] = [];
      for (let i = 0; i < TEST_CONCURRENCY; i++) {
        workers.push(run());
      }
      await Promise.all(workers);
      await this.persistHealth();
      this.msg = `检测完成 · 可用 ${ok} · 不可用 ${bad} · 共 ${this.progressTotal}`;
    } finally {
      this.testingAll = false;
    }
  }

  /** 批量启停：作用于当前筛选结果，符合「看到什么就操作什么」 */
  private async setVisibleEnabled(enabled: boolean): Promise<void> {
    const target: Set<string> = new Set();
    for (const src of this.visibleSources()) {
      target.add(src.url);
    }
    if (target.size === 0) {
      this.msg = '当前筛选结果为空';
      return;
    }
    let changed = 0;
    this.sources = this.sources.map((src: SourceConfig): SourceConfig => {
      if (target.has(src.url) && src.enabled !== enabled) {
        changed++;
        return { name: src.name, url: src.url, detail: src.detail, isAdult: src.isAdult, enabled: enabled };
      }
      return src;
    });
    await this.persistSources();
    this.msg = `${enabled ? '已启用' : '已停用'} ${changed} 个源（当前筛选）`;
  }

  private async disableFailedSources(): Promise<void> {
    if (this.testingAll) {
      return;
    }
    let count = 0;
    this.sources = this.sources.map((src: SourceConfig): SourceConfig => {
      const h = this.health.get(src.url);
      if (src.enabled && h !== undefined && !h.ok) {
        count++;
        return { name: src.name, url: src.url, detail: src.detail, isAdult: src.isAdult, enabled: false };
      }
      return src;
    });
    if (count === 0) {
      this.msg = '没有已知不可用的启用源；先点「检测全部」';
      return;
    }
    await this.persistSources();
    this.msg = `已停用 ${count} 个不可用源；可随时手动启用`;
  }

  /** 按 URL 去重补回内置源，保留已有源的启停状态与自定义项 */
  private async restoreBuiltIn(): Promise<void> {
    const existing: Set<string> = new Set();
    for (const src of this.sources) {
      existing.add(src.url.replace(/\/+$/, ''));
    }
    const adding: SourceConfig[] = [];
    for (const src of builtInSources()) {
      const key = src.url.replace(/\/+$/, '');
      if (!existing.has(key)) {
        existing.add(key);
        adding.push(src);
      }
    }
    if (adding.length === 0) {
      this.msg = '内置源已经齐了';
      return;
    }
    this.sources = this.sources.concat(adding);
    await this.persistSources();
    this.msg = `已恢复 ${adding.length} 个内置源，共 ${this.sources.length} 个`;
  }

  /** 批量导入：支持「名称,网址」多行，或只贴一个网址 */
  private async importSources(): Promise<void> {
    const parsed = parseSourceLines(this.importText);
    if (parsed.length === 0) {
      this.msg = '没有识别到有效源；每行「名称,网址」，或直接贴一个网址';
      return;
    }
    const existing: Set<string> = new Set();
    for (const src of this.sources) {
      existing.add(src.url.replace(/\/+$/, ''));
    }
    const adding: SourceConfig[] = [];
    for (const p of parsed) {
      const key = p.url.replace(/\/+$/, '');
      if (!existing.has(key)) {
        existing.add(key);
        const sc: SourceConfig = { name: p.name, url: p.url, detail: '', isAdult: false, enabled: true };
        adding.push(sc);
      }
    }
    if (adding.length === 0) {
      this.msg = `识别到 ${parsed.length} 个源，但都已经存在`;
      return;
    }
    this.sources = this.sources.concat(adding);
    await this.persistSources();
    this.importText = '';
    this.showImportDialog = false;
    this.msg = `新增 ${adding.length} 个源（跳过重复 ${parsed.length - adding.length}），共 ${this.sources.length} 个`;
  }

  /** 一键删除全部点播源；内置源可随时用「恢复内置源」找回 */
  private async deleteAllSources(): Promise<void> {
    if (this.sources.length === 0) {
      this.msg = '没有可删除的源';
      return;
    }
    const result = await promptAction.showDialog({
      title: '删除全部片源',
      message: `将删除全部 ${this.sources.length} 个点播源（含内置源）。删除后可点「恢复内置源」找回内置源。`,
      buttons: [
        { text: '取消', color: Theme.INK },
        { text: '全部删除', color: Theme.DANGER }
      ]
    });
    if (result.index !== 1) {
      return;
    }
    const count = this.sources.length;
    this.sources = [];
    await this.persistSources();
    this.msg = `已删除全部 ${count} 个源；需要时点「恢复内置源」找回内置源`;
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

  // ------------------------------------------------------------ 直播源

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

  // ------------------------------------------------------------ 弹窗

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

  @Builder
  importSourceDialog() {
    Column({ space: 12 }) {
      Text('粘贴导入片源').fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
      Text('每行一个源，格式「名称,网址」；只贴网址也行，名称自动取域名。空行和 # 开头的注释会被忽略。')
        .fontSize(12).fontColor(Theme.SECONDARY)
      TextArea({ placeholder: '虎牙,https://www.huyaapi.com/api.php/provide/vod/from/hym3u8\n火狐,https://hhzyapi.com/api.php/provide/vod\nhttps://cj.lziapi.com/api.php/provide/vod',
        text: this.importText })
        .fontSize(13).height(190).borderRadius(12)
        .backgroundColor(Theme.BG).fontColor(Theme.INK).placeholderColor(Theme.SECONDARY)
        .onChange((v: string) => { this.importText = v; })
      Row({ space: 10 }) {
        Button('取消').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.TINT).fontColor(Theme.INK).layoutWeight(1)
          .onClick(() => { this.showImportDialog = false; })
        Button('导入').fontSize(14).height(42).borderRadius(12)
          .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT).layoutWeight(1)
          .onClick(() => { this.importSources(); })
      }.width('100%')
    }
    .padding(18).borderRadius(Theme.RADIUS_CARD).backgroundColor(Theme.PANEL).width('86%')
    .border({ width: 1, color: Theme.BORDER })
  }

  @Builder
  chip(key: string, label: string) {
    Text(label).fontSize(12).height(30).padding({ left: 11, right: 11 })
      .borderRadius(15)
      .fontColor(this.filter === key ? Theme.ON_ACCENT : Theme.TILE_ICON)
      .backgroundColor(this.filter === key ? Theme.ACCENT : Theme.TILE_SOFT)
      .textAlign(TextAlign.Center)
      .onClick(() => { this.filter = key; })
  }

  @Builder
  sourceRow(src: SourceConfig) {
    Column({ space: 5 }) {
      Row({ space: 6 }) {
        Text(src.name).fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(src.enabled ? Theme.INK : Theme.TERTIARY)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '44%' })
        Text(this.isBuiltIn(src.url) ? '内置' : '自定义').fontSize(9)
          .fontColor(this.isBuiltIn(src.url) ? Theme.ACCENT : '#7A6A2F')
          .padding({ left: 5, right: 5, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor(this.isBuiltIn(src.url) ? Theme.TINT : '#FBF3D9')
        if (this.session.directCms.shouldTryDirect(src)) {
          Text('直连').fontSize(9).fontColor(Theme.ON_ACCENT_SOFT)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .borderRadius(6).backgroundColor(Theme.TILE_ACTIVE)
        }
        Blank()
        if (this.testing === src.url) {
          LoadingProgress().width(16).height(16).color(Theme.ACCENT)
        } else {
          Text('测速').fontSize(12).fontColor(Theme.ACCENT).padding({ left: 6, right: 6, top: 4, bottom: 4 })
            .onClick(() => { this.testSource(src); })
        }
        Toggle({ type: ToggleType.Switch, isOn: src.enabled })
          .selectedColor(Theme.ACCENT)
          .width(40).height(22)
          .onChange(() => { this.toggleSource(src); })
      }.width('100%')

      Text(src.url).fontSize(10).fontColor(Theme.TERTIARY).maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')

      Row() {
        Text(this.statusLine(src)).fontSize(10).fontColor(this.statusColor(src)).layoutWeight(1)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        Text('删除').fontSize(11).fontColor(Theme.DANGER).padding({ left: 8, right: 2, top: 4, bottom: 2 })
          .onClick(() => { this.removeSource(src); })
      }.width('100%')
    }
    .width('100%').padding({ left: 12, right: 12, top: 10, bottom: 8 })
    .borderRadius(Theme.RADIUS_ROW).backgroundColor(Theme.PANEL)
    .border({ width: 1, color: this.isBuiltIn(src.url) ? Theme.BORDER : '#EDE6CF' })
    .opacity(src.enabled ? 1 : 0.72)
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
            .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
            .onClick(() => {
              router.pushUrl({ url: 'pages/Scan', params: { mode: 'source' } as RouteParams });
            })
          Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
            .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
            .onClick(() => { router.back(); })
        }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

        Row({ space: 8 }) {
          Button('点播源').fontSize(13).height(36).borderRadius(18).layoutWeight(1)
            .backgroundColor(this.tab === 0 ? Theme.ACCENT : Theme.PANEL)
            .fontColor(this.tab === 0 ? Theme.ON_ACCENT : Theme.SECONDARY)
            .onClick(() => { this.tab = 0; })
          Button('直播源').fontSize(13).height(36).borderRadius(18).layoutWeight(1)
            .backgroundColor(this.tab === 1 ? Theme.ACCENT : Theme.PANEL)
            .fontColor(this.tab === 1 ? Theme.ON_ACCENT : Theme.SECONDARY)
            .onClick(() => { this.tab = 1; })
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

        if (this.tab === 0) {
          // 统计条：一眼看清总量与可用情况
          Row({ space: 12 }) {
            Text(`共 ${this.sources.length}`).fontSize(11).fontColor(Theme.SECONDARY)
            Text(`启用 ${this.enabledCount()}`).fontSize(11).fontColor(Theme.ACCENT)
            Text(`可用 ${this.okCount()}`).fontSize(11).fontColor(Theme.ACCENT)
            Text(`不可用 ${this.badCount()}`).fontSize(11)
              .fontColor(this.badCount() > 0 ? Theme.DANGER : Theme.TERTIARY)
            Blank()
            Text(this.sortByHealth ? '可用优先' : '原顺序').fontSize(11).fontColor(Theme.ACCENT)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(10).backgroundColor(Theme.TINT)
              .onClick(() => { this.sortByHealth = !this.sortByHealth; })
          }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

          TextInput({ placeholder: '搜索名称或地址…', text: this.query })
            .fontSize(14).height(42).borderRadius(12)
            .backgroundColor(Theme.PANEL).fontColor(Theme.INK).placeholderColor(Theme.SECONDARY)
            .margin({ left: 16, right: 16, bottom: 8 })
            .onChange((v: string) => { this.query = v; })

          Scroll() {
            Row({ space: 6 }) {
              ForEach(CHIPS, (c: FilterChip) => {
                this.chip(c.key, c.label)
              }, (c: FilterChip) => c.key)
            }.padding({ left: 16, right: 16 })
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%').margin({ bottom: 8 })

          Row({ space: 8 }) {
            Button(this.testingAll ? `检测中 ${this.progressDone}/${this.progressTotal}` : '检测全部')
              .fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
              .enabled(!this.testingAll && this.testing === '' && this.sources.length > 0)
              .onClick(() => { this.testAllSources(); })
            Button('停用失败源').fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .enabled(!this.testingAll && this.badCount() > 0)
              .onClick(() => { this.disableFailedSources(); })
          }.width('100%').padding({ left: 16, right: 16, bottom: 6 })

          if (this.testingAll && this.progressTotal > 0) {
            Progress({ value: this.progressDone, total: this.progressTotal })
              .width('100%').height(4).color(Theme.ACCENT)
              .backgroundColor(Theme.TINT)
              .padding({ left: 16, right: 16 }).margin({ bottom: 6 })
          }

          Row({ space: 8 }) {
            Button('启用全部').fontSize(12).height(34).borderRadius(11).layoutWeight(1)
              .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
              .onClick(() => { this.setVisibleEnabled(true); })
            Button('停用全部').fontSize(12).height(34).borderRadius(11).layoutWeight(1)
              .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
              .onClick(() => { this.setVisibleEnabled(false); })
            Button('恢复内置源').fontSize(12).height(34).borderRadius(11).layoutWeight(1)
              .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
              .onClick(() => { this.restoreBuiltIn(); })
          }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

          Row({ space: 8 }) {
            Button('粘贴导入源').fontSize(12).height(34).borderRadius(11).layoutWeight(1)
              .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
              .onClick(() => { this.showImportDialog = true; })
            Button('删除全部源').fontSize(12).height(34).borderRadius(11).layoutWeight(1)
              .backgroundColor(Theme.PANEL).fontColor(Theme.DANGER)
              .enabled(this.sources.length > 0)
              .onClick(() => { this.deleteAllSources(); })
          }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

          if (this.msg !== '') {
            Text(this.msg).fontSize(11).fontColor(Theme.SECONDARY)
              .width('100%').padding({ left: 16, right: 16, bottom: 6 })
              .maxLines(2)
          }

          if (this.visibleSources().length === 0) {
            Column({ space: 10 }) {
              Text('当前筛选没有匹配的片源').fontSize(13).fontColor(Theme.SECONDARY)
              Text('换个筛选或清空搜索词').fontSize(11).fontColor(Theme.TERTIARY)
            }.layoutWeight(1).width('100%').justifyContent(FlexAlign.Center)
          } else {
            List({ space: 7 }) {
              ForEach(this.visibleSources(), (src: SourceConfig) => {
                ListItem() {
                  this.sourceRow(src)
                }
              }, (src: SourceConfig) => src.url + src.enabled.toString() + this.rank(src).toString())
            }
            .layoutWeight(1)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 16 })
            .scrollBar(BarState.Off)
          }
        } else {
          Row({ space: 8 }) {
            Button('＋ 添加直播订阅').fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
              .onClick(() => { this.showLiveDialog = true; })
            Button('导入本地列表').fontSize(13).height(38).borderRadius(12).layoutWeight(1)
              .backgroundColor(Theme.TILE_SOFT).fontColor(Theme.TILE_ICON)
              .onClick(() => { router.pushUrl({ url: 'pages/Live' }); })
          }.width('100%').padding({ left: 16, right: 16, bottom: 8 })

          if (this.msg !== '') {
            Text(this.msg).fontSize(11).fontColor(Theme.SECONDARY)
              .width('100%').padding({ left: 16, right: 16, bottom: 6 })
          }

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
        Column() { this.addSourceDialog() }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor('#66000000')
      }
      if (this.showSubDialog) {
        Column() { this.subImportDialog() }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor('#66000000')
      }
      if (this.showLiveDialog) {
        Column() { this.addLiveDialog() }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor('#66000000')
      }
      if (this.showImportDialog) {
        Column() { this.importSourceDialog() }
          .width('100%').height('100%').justifyContent(FlexAlign.Center)
          .backgroundColor('#66000000')
      }
    }
    .width('100%').height('100%')
  }
}
