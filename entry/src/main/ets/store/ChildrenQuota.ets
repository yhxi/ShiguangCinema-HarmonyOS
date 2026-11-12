/**
 * 儿童每日额度（对齐 Android 版 ChildrenQuota.kt + ChildrenQuotaMatching.kt）。
 *
 * 规则：
 *   · 只统计**受管理作品**真正在播放的时间；浏览、搜索、暂停都不计入（v1.5.0）
 *   · 默认每日 15 分钟，家长可设 1–240 分钟；临时加时只对当天生效，不累积到次日
 *   · 额度用完仍可浏览，继续播放须家长加时；零点按本地日期重置
 *   · 受管理作品 = 手动加入的 + 内置儿童清单里的（按系列名归一匹配，分季 / 番外 /
 *     语言版本都算同一部）
 *
 * 计时方式：播放页每秒调用一次 consume()，只有 isPlaying 时才加，避免暂停还在扣时间。
 */

import { Prefs } from '../store/Prefs';
import { ChildrenCatalog } from '../api/ChildrenCatalog';

const KEY_LIMIT = 'childrenLimitMinutes';
const KEY_BONUS = 'childrenBonusMs';
const KEY_USED = 'childrenUsedMs';
const KEY_DAY = 'childrenUsedDay';
const KEY_TRACKED = 'childrenTrackedTitles';
const KEY_STATE = 'childrenQuotaStateV2';

interface QuotaState { day: string; usedMs: number; bonusMs: number; limitMinutes: number; }

/** 单集/单条记录里带的剧集后缀：「 · 第3集」之后都不算剧名 */
export function seriesNameOf(label: string): string {
  let name = label;
  const marks: string[] = [' · 第', '·第'];
  for (const mark of marks) {
    const idx = name.indexOf(mark);
    if (idx > 0) {
      name = name.substring(0, idx);
    }
  }
  return name.trim();
}

/** 剧名归一化：采集站标题常差在空格、全角括号、· 分隔符上，不归一化匹配不上 */
export function normalizeSeries(series: string): string {
  return series.replace(/[\s·・\-—_()（）\[\]【】:：,，.。]/g, '').toLowerCase();
}

/** 分季 / 番外 / 语言版本后缀，去掉后是同一部作品 */
const VARIANT_SUFFIX =
  /(第[一二三四五六七八九十百零两0-9]+[季部辑]|season[0-9]+|番外篇|番外|特别篇|特别版|特別篇|特別版|剧场版|劇場版|大电影|电影版|动画版|上篇|下篇|上集|下集|中文版|英文版|普通话版|国语版|英语版|粤语版|中文|国语|普通话|英语|粤语|全集|完整版)+$/;

const SERIES_ALIASES: Map<string, string> = new Map<string, string>([
  ['大耳朵图图彩色世界', '大耳朵图图']
]);

export function childQuotaKey(title: string): string {
  return normalizeSeries(seriesNameOf(title)).replace(VARIANT_SUFFIX, '');
}

/** 该片名是否落在已登记的受管理集合里（系列名 + 副标题 / 别名也算） */
export function matchesChildQuotaTitle(title: string, storedKeys: Set<string>): boolean {
  const key = childQuotaKey(title);
  if (key === '') {
    return false;
  }
  const raw = seriesNameOf(title).replace(/\s+/g, '').toLowerCase();
  const alias = SERIES_ALIASES.get(key);
  for (const stored of storedKeys) {
    const base = childQuotaKey(stored);
    if (base === '') {
      continue;
    }
    if (key === base) {
      return true;
    }
    if (alias !== undefined && alias === base) {
      return true;
    }
    if (raw.startsWith(base) && /^[之・·:：—-].+/.test(raw.substring(base.length))) {
      return true;
    }
  }
  return false;
}

function todayKey(): string {
  const d = new Date();
  const month = d.getMonth() + 1;
  const day = d.getDate();
  return `${d.getFullYear()}-${month < 10 ? '0' : ''}${month}-${day < 10 ? '0' : ''}${day}`;
}

export class ChildrenQuota {
  private static instance: ChildrenQuota | null = null;

  private prefs: Prefs | null = null;
  private limitMinutes: number = 15;
  private bonusMs: number = 0;
  private usedMs: number = 0;
  private day: string = '';
  private tracked: string[] = [];
  /** 内置清单的归一 key，构造一次即可 */
  private catalogKeys: Set<string> = new Set<string>();
  private dirtyMs: number = 0;
  private persistChain: Promise<void> = Promise.resolve();

  private constructor() {
  }

  static async get(prefs: Prefs): Promise<ChildrenQuota> {
    const quota = ChildrenQuota.instance !== null ? ChildrenQuota.instance : new ChildrenQuota();
    if (ChildrenQuota.instance !== null) {
      return quota;
    }
    quota.prefs = prefs;
    quota.catalogKeys = new Set<string>();
    for (const title of ChildrenCatalog.allTitles()) {
      quota.catalogKeys.add(normalizeSeries(title));
    }
    const limit = prefs.getRaw(KEY_LIMIT, '15');
    const parsed = parseInt(limit, 10);
    quota.limitMinutes = isNaN(parsed) ? 15 : Math.max(1, Math.min(240, parsed));
    quota.bonusMs = Math.max(0, parseInt(prefs.getRaw(KEY_BONUS, '0'), 10) || 0);
    quota.usedMs = Math.max(0, parseInt(prefs.getRaw(KEY_USED, '0'), 10) || 0);
    quota.day = prefs.getRaw(KEY_DAY, '');
    const saved = prefs.getRaw(KEY_STATE, '');
    if (saved !== '') {
      try {
        const state = JSON.parse(saved) as QuotaState;
        if (typeof state.day === 'string' && typeof state.usedMs === 'number' &&
          typeof state.bonusMs === 'number' && typeof state.limitMinutes === 'number' &&
          isFinite(state.usedMs) && isFinite(state.bonusMs) && isFinite(state.limitMinutes)) {
          quota.day = state.day;
          quota.usedMs = Math.max(0, state.usedMs);
          quota.bonusMs = Math.max(0, state.bonusMs);
          quota.limitMinutes = Math.max(1, Math.min(240, state.limitMinutes));
        }
      } catch (e) { /* Fall back to legacy fields. */ }
    }
    quota.tracked = prefs.getStringList(KEY_TRACKED);
    quota.rollOverIfNeeded();
    ChildrenQuota.instance = quota;
    return quota;
  }

  /** 当前单例（没初始化过返回 null，避免页面在 Prefs 就绪前强行读盘） */
  static peek(): ChildrenQuota | null {
    return ChildrenQuota.instance;
  }

  // ---------------------------------------------------------------- 核心状态

  private rollOverIfNeeded(): void {
    const today = todayKey();
    if (this.day === today) {
      return;
    }
    // 跨天：用量与临时加时都归零
    this.usedMs = 0;
    this.bonusMs = 0;
    this.day = today;
    this.dirtyMs = 0;
    this.persist(true).catch(() => {});
  }

  private limitMs(): number {
    return this.limitMinutes * 60000;
  }

  totalMs(): number {
    return this.limitMs() + this.bonusMs;
  }

  remainingMs(): number {
    this.rollOverIfNeeded();
    return Math.max(0, this.totalMs() - this.usedMs);
  }

  usedTodayMs(): number {
    this.rollOverIfNeeded();
    return this.usedMs;
  }

  isExhausted(): boolean {
    return this.remainingMs() <= 0;
  }

  /** 「今日剩余 12 分钟」/「今日已用完」，向上取整到分钟 */
  label(): string {
    const left = this.remainingMs();
    if (left <= 0) {
      return '今日已用完';
    }
    return `今日剩余 ${Math.ceil(left / 60000)} 分钟`;
  }

  /** 已用百分比（0–100），给额度条用 */
  percent(): number {
    const total = this.totalMs();
    if (total <= 0) {
      return 100;
    }
    return Math.max(0, Math.min(100, Math.round(this.usedMs / total * 100)));
  }

  dailyMinutes(): number {
    return this.limitMinutes;
  }

  bonusMinutes(): number {
    return Math.round(this.bonusMs / 60000);
  }

  /**
   * 累加播放时间。只有受管理作品在真正播放时才该调用。
   * 返回 true 表示本次调用把额度用完了（播放页据此暂停）。
   */
  consume(elapsedMs: number): boolean {
    if (elapsedMs <= 0) {
      return this.isExhausted();
    }
    this.rollOverIfNeeded();
    this.usedMs += elapsedMs;
    this.dirtyMs += elapsedMs;
    // 每 5 秒落盘一次；暂停、退出时由调用方 flush()
    if (this.dirtyMs >= 5000) {
      this.persist(false).catch(() => {});
    }
    return this.remainingMs() <= 0;
  }

  /** 强制落盘（暂停 / 退出播放页 / 切后台时调用） */
  flush(): void {
    this.persist(true).catch(() => {});
  }

  private persist(force: boolean): Promise<void> {
    const p = this.prefs;
    if (p === null || (!force && this.dirtyMs < 5000)) { return Promise.resolve(); }
    const state: QuotaState = { day: this.day, usedMs: this.usedMs,
      bonusMs: this.bonusMs, limitMinutes: this.limitMinutes };
    this.dirtyMs = 0;
    // 串行写完整快照，避免旧写入晚于新写入，也避免日期与用量分开落盘。
    const write = this.persistChain.catch(() => {}).then(() => p.putRaw(KEY_STATE, JSON.stringify(state)));
    this.persistChain = write.catch(() => { this.dirtyMs = Math.max(this.dirtyMs, 5000); });
    return write;
  }

  // ---------------------------------------------------------------- 家长设置

  async setDailyMinutes(minutes: number): Promise<void> {
    this.limitMinutes = Math.max(1, Math.min(240, Math.round(minutes)));
    await this.persist(true);
  }

  /** 仅今天加时，不写进每日固定额度 */
  async addBonusMinutes(minutes: number): Promise<void> {
    if (minutes <= 0) {
      return;
    }
    this.bonusMs += Math.round(minutes) * 60000;
    await this.persist(true);
  }

  // ---------------------------------------------------------------- 作品管理

  isManaged(title: string): boolean {
    const key = childQuotaKey(title);
    if (key === '') {
      return false;
    }
    const keys: Set<string> = new Set<string>();
    this.catalogKeys.forEach((v: string) => keys.add(v));
    for (const t of this.tracked) {
      keys.add(normalizeSeries(t));
    }
    return matchesChildQuotaTitle(title, keys);
  }

  /** 是否手动加入过（用于界面区分「自动识别」和「手动加入」） */
  isManuallyTracked(title: string): boolean {
    const key = childQuotaKey(title);
    if (key === '') {
      return false;
    }
    return this.tracked.some((t: string) => childQuotaKey(t) === key);
  }

  /** 内置清单自动纳入的不可手动移除 */
  isBuiltIn(title: string): boolean {
    const key = childQuotaKey(title);
    return key !== '' && matchesChildQuotaTitle(title, this.catalogKeys);
  }

  trackedTitles(): string[] {
    return this.tracked.slice();
  }

  async mark(title: string): Promise<void> {
    if (title.trim() === '' || this.isManaged(title)) {
      return;
    }
    this.tracked.push(title.trim());
    if (this.prefs !== null) {
      await this.prefs.putStringList(KEY_TRACKED, this.tracked);
    }
  }

  async unmark(title: string): Promise<boolean> {
    const key = childQuotaKey(title);
    const next = this.tracked.filter((t: string) => childQuotaKey(t) !== key);
    if (next.length === this.tracked.length) {
      return false;
    }
    this.tracked = next;
    if (this.prefs !== null) {
      await this.prefs.putStringList(KEY_TRACKED, this.tracked);
    }
    return true;
  }

  /** 界面文案：自动识别 / 手动加入 */
  origin(title: string): string {
    return this.isBuiltIn(title) ? '内置清单自动识别' : '手动加入';
  }
}

// -------------------------------------------------------------------- 家长验证

/** 中文大写数字，家长题面用；刻意不用 PIN，避免小孩记住或试出来 */
const UPPER_DIGITS: string[] = ['零', '壹', '贰', '叁', '肆', '伍', '陆', '柒', '捌', '玖'];

export interface ParentChallenge {
  question: string;
  answer: number;
}

/** 生成一道「叁 × 柒 = ?」的乘法题，两个因数都是 2–9 */
export function makeParentChallenge(): ParentChallenge {
  const a = 2 + Math.floor(Math.random() * 8);
  const b = 2 + Math.floor(Math.random() * 8);
  return { question: `${UPPER_DIGITS[a]} × ${UPPER_DIGITS[b]} = ?`, answer: a * b };
}

/** 把用户输入的数字面板字符串转成答案 */
export function parseParentAnswer(text: string): number {
  const value = parseInt(text, 10);
  return isNaN(value) ? -1 : value;
}
