/**
 * 首页入口图标 —— 对应 Android 版 HomeIcons.kt（HomeIconView）。
 *
 * 全部按 24×24 设计稿用路径描边绘制，再按控件尺寸缩放。
 * 之前用 ▣ ◉ ⌕ ♧ ☼ 这些字体符号，各家字体字面大小/笔画粗细/基线都不同，
 * 真机上「搜索」「设置」会明显比别的图标小一圈，还有被当 emoji 渲染的风险。
 *
 * 路径数值与 Kotlin 版逐条对应，保证两端图标完全一致。
 */

import { Theme } from '../common/Theme';

/** 设计稿坐标系边长 */
const UNIT: number = 24;

function scale(v: number, size: number): string {
  return (v * size / UNIT).toFixed(2);
}

/** 圆形：两段半圆弧 */
function circle(cx: number, cy: number, r: number, size: number): string {
  const x1 = scale(cx - r, size);
  const x2 = scale(cx + r, size);
  const y = scale(cy, size);
  const rr = scale(r, size);
  return `M ${x1} ${y} A ${rr} ${rr} 0 1 0 ${x2} ${y} A ${rr} ${rr} 0 1 0 ${x1} ${y} Z`;
}

/** 圆角矩形 */
function roundRect(x: number, y: number, w: number, h: number, r: number, size: number): string {
  const l = scale(x, size);
  const t = scale(y, size);
  const rt = scale(x + w, size);
  const b = scale(y + h, size);
  const rr = scale(r, size);
  return `M ${scale(x + r, size)} ${t} L ${scale(x + w - r, size)} ${t} ` +
    `A ${rr} ${rr} 0 0 1 ${rt} ${scale(y + r, size)} ` +
    `L ${rt} ${scale(y + h - r, size)} ` +
    `A ${rr} ${rr} 0 0 1 ${scale(x + w - r, size)} ${b} ` +
    `L ${scale(x + r, size)} ${b} ` +
    `A ${rr} ${rr} 0 0 1 ${l} ${scale(y + h - r, size)} ` +
    `L ${l} ${scale(y + r, size)} ` +
    `A ${rr} ${rr} 0 0 1 ${scale(x + r, size)} ${t} Z`;
}

/** 三角形 */
function triangle(ax: number, ay: number, bx: number, by: number, cx: number, cy: number,
  size: number): string {
  return `M ${scale(ax, size)} ${scale(ay, size)} L ${scale(bx, size)} ${scale(by, size)} ` +
    `L ${scale(cx, size)} ${scale(cy, size)} Z`;
}

/** 线段 */
function line(x1: number, y1: number, x2: number, y2: number, size: number): string {
  return `M ${scale(x1, size)} ${scale(y1, size)} L ${scale(x2, size)} ${scale(y2, size)}`;
}

/** 描边部分 */
export function iconStrokePath(kind: string, size: number): string {
  if (kind === 'tv') {
    // 屏幕 + 里面一个实心小三角
    return roundRect(3.5, 5, 17, 14, 2.6, size);
  }
  if (kind === 'live') {
    // 同心圆：外圈描边，内点实心
    return circle(12, 12, 8, size);
  }
  if (kind === 'search') {
    return circle(10.5, 10.5, 6.3, size) + ' ' + line(15.2, 15.2, 20, 20, size);
  }
  if (kind === 'fav') {
    // 书签
    return `M ${scale(7, size)} ${scale(4.5, size)} L ${scale(17, size)} ${scale(4.5, size)} ` +
      `L ${scale(17, size)} ${scale(20, size)} L ${scale(12, size)} ${scale(16, size)} ` +
      `L ${scale(7, size)} ${scale(20, size)} Z`;
  }
  if (kind === 'setup') {
    // 齿轮：圆 + 八颗均匀的齿
    let cmd = circle(12, 12, 5.2, size);
    for (let i = 0; i < 8; i++) {
      const a = i * 45 * Math.PI / 180;
      const c = Math.cos(a);
      const s = Math.sin(a);
      cmd += ' ' + line(12 + c * 7.2, 12 + s * 7.2, 12 + c * 9.6, 12 + s * 9.6, size);
    }
    return cmd;
  }
  if (kind === 'movie') {
    return triangle(6.5, 4.5, 19.5, 12, 6.5, 19.5, size);
  }
  if (kind === 'show') {
    return `M ${scale(12, size)} ${scale(3.2, size)} ` +
      `Q ${scale(13.4, size)} ${scale(10.6, size)} ${scale(20.8, size)} ${scale(12, size)} ` +
      `Q ${scale(13.4, size)} ${scale(13.4, size)} ${scale(12, size)} ${scale(20.8, size)} ` +
      `Q ${scale(10.6, size)} ${scale(13.4, size)} ${scale(3.2, size)} ${scale(12, size)} ` +
      `Q ${scale(10.6, size)} ${scale(10.6, size)} ${scale(12, size)} ${scale(3.2, size)} Z`;
  }
  if (kind === 'history') {
    return circle(12, 12, 8, size) + ' ' + line(12, 12, 12, 7.6, size) + ' ' +
      line(12, 12, 15.6, 13.8, size);
  }
  if (kind === 'sources') {
    return line(12, 5, 12, 19, size) + ' ' + line(5, 12, 19, 12, size);
  }
  return '';
}

/** 实心部分（没有则返回空串） */
export function iconFillPath(kind: string, size: number): string {
  if (kind === 'tv') {
    return triangle(10, 9, 15.5, 12, 10, 15, size);
  }
  if (kind === 'live') {
    return circle(12, 12, 2.8, size);
  }
  if (kind === 'movie') {
    return triangle(6.5, 4.5, 19.5, 12, 6.5, 19.5, size);
  }
  return '';
}

@Component
export struct HomeIcon {
  @Prop kind: string = 'tv';
  @Prop iconSize: number = 24;
  @Prop tint: string = Theme.INK;

  build() {
    Stack() {
      if (iconStrokePath(this.kind, this.iconSize) !== '') {
        Path()
          .width(this.iconSize).height(this.iconSize)
          .commands(iconStrokePath(this.kind, this.iconSize))
          .fillOpacity(0)
          .stroke(this.tint)
          .strokeWidth(this.iconSize / UNIT * 1.9)
          .strokeLineCap(LineCapStyle.Round)
          .strokeLineJoin(LineJoinStyle.Round)
          .antiAlias(true)
      }
      if (iconFillPath(this.kind, this.iconSize) !== '') {
        Path()
          .width(this.iconSize).height(this.iconSize)
          .commands(iconFillPath(this.kind, this.iconSize))
          .fill(this.tint)
          .antiAlias(true)
      }
    }.width(this.iconSize).height(this.iconSize)
  }
}
