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

  // ---------- v1.5.5 手机端「清新浅色海报墙」 ----------
  /** 入口格子常态底色：柔和浅绿（替代原来的纯白） */
  static readonly TILE_SOFT: string = '#EDF6EF';
  /** 入口格子描边：比底色深一点点的浅绿 */
  static readonly TILE_SOFT_BORDER: string = '#DDEBE1';
  /** 入口图标常态色：深一档的墨绿，保证浅绿底上的对比度 */
  static readonly TILE_ICON: string = '#2C574F';
  /** 海报墙页面底色（比 BG 更干净的白绿） */
  static readonly WALL_BG: string = '#FBFDFA';
  /** 海报卡片标题区文字 */
  static readonly WALL_TITLE: string = '#1F3A34';

  // ---------- 儿童乐园（薄荷绿 + 奶油白） ----------
  /** 儿童乐园主色 */
  static readonly KID_ACCENT: string = '#3FA37B';
  /** 儿童乐园主色深一档（文字/按钮按下） */
  static readonly KID_ACCENT_DEEP: string = '#2F7F60';
  /** 儿童乐园页面底色：奶油白 */
  static readonly KID_BG: string = '#FFFDF6';
  /** 儿童乐园卡片底色 */
  static readonly KID_PANEL: string = '#FFFFFF';
  /** 儿童乐园浅绿底 */
  static readonly KID_TINT: string = '#E7F5EC';
  /** 儿童乐园文字 */
  static readonly KID_INK: string = '#2A4A3E';
  /** 儿童乐园次级文字 */
  static readonly KID_SECONDARY: string = '#6E8B7D';
  /** 儿童乐园描边 */
  static readonly KID_BORDER: string = '#E3EFE6';
  /** 额度条已经用掉的部分 */
  static readonly KID_BAR_USED: string = '#5CC08E';
  /** 额度用完 / 置灰 */
  static readonly KID_DISABLED: string = '#B9C7BE';
}
