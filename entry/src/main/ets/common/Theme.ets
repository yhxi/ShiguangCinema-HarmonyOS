/**
 * 视觉令牌 —— 取值直接对齐 Android 版 MainActivity 的颜色常量，
 * 保证两端同一套配色，不再各页各写一套十六进制。
 *
 * 对应关系（Android -> 这里）：
 *   ACCENT 0xFF0F766E -> ACCENT
 *   INK    0xFF173B35 -> INK
 *   BRIGHTER_TEXT 0xFF617A70 -> SECONDARY
 *   PANEL  0xFFFFFFFF -> PANEL
 *   SOFT   0xFFF5F7F1 -> BG
 *   BORDER 0xFFDFE8E2 -> BORDER
 */
export class Theme {
  /** 主色：按钮、选中态、强调文字 */
  static readonly ACCENT: string = '#0F766E';
  /** 主色深一档：主按钮按下 / 渐变末端 */
  static readonly ACCENT_DEEP: string = '#174E48';
  /** 主色卡片上的渐变起点 */
  static readonly ACCENT_START: string = '#0F766E';
  /** 主文字（深墨绿） */
  static readonly INK: string = '#173B35';
  /** 次级文字 */
  static readonly SECONDARY: string = '#617A70';
  /** 更弱的辅助文字 */
  static readonly TERTIARY: string = '#8A9A92';
  /** 卡片 / 输入框底色 */
  static readonly PANEL: string = '#FFFFFF';
  /** 页面底色 */
  static readonly BG: string = '#F5F7F1';
  /** 卡片描边 */
  static readonly BORDER: string = '#DFE8E2';
  /** 图标底 / 浅绿色块 */
  static readonly TINT: string = '#E5F3ED';
  /** 图片占位底色 */
  static readonly PLACEHOLDER: string = '#D7E9DF';
  /** 危险操作 / 删除 */
  static readonly DANGER: string = '#C34545';
  /** 主色背景上的主文字 */
  static readonly ON_ACCENT: string = '#FFFFFF';
  /** 主色背景上的强调小字 */
  static readonly ON_ACCENT_SOFT: string = '#D7FFF0';
  /** 主色背景上的辅助小字 */
  static readonly ON_ACCENT_MUTED: string = '#C6E5DD';
  /** 正文（比次级文字略深） */
  static readonly BODY: string = '#4A5F57';

  /** 卡片圆角 */
  static readonly RADIUS_CARD: number = 16;
  /** 入口格子圆角 */
  static readonly RADIUS_TILE: number = 14;
  /** 首页选中的入口格子底色（按设计稿取样，比主色更沉一点） */
  static readonly TILE_ACTIVE: string = '#34736E';
  /** 列表行圆角 */
  static readonly RADIUS_ROW: number = 12;
}
