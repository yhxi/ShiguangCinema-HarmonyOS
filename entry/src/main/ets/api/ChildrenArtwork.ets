/**
 * 儿童封面索引（对齐 Android 版 ChildrenArtworkIndex.kt）。
 *
 * 只是「片名 → 封面 URL 列表」的清单，不内置任何图片：
 *   · 优先用这份人工核验过的清单（82 部，约 16 KB），命中率高、不依赖片源可用性
 *   · 没命中就交给海报组件的片源兜底
 *
 * 清单放在 resources/rawfile/children_artwork.json，首次用到时解析一次后常驻内存。
 */

import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

export class ChildrenArtwork {
  private static map: Map<string, string[]> | null = null;

  /** 解析一次就缓存；失败按空清单处理，不影响卡片渲染 */
  private static ensure(context: common.Context): Map<string, string[]> {
    if (ChildrenArtwork.map !== null) {
      return ChildrenArtwork.map;
    }
    const result: Map<string, string[]> = new Map<string, string[]>();
    try {
      const bytes: Uint8Array = context.resourceManager.getRawFileContentSync('children_artwork.json');
      const decoder = util.TextDecoder.create('utf-8');
      const text = decoder.decodeToString(bytes);
      const root = JSON.parse(text) as Record<string, Object>;
      for (const title of Object.keys(root)) {
        const entry = root[title] as Record<string, Object>;
        if (entry === null || entry === undefined) {
          continue;
        }
        const urls = entry['urls'] as Object[];
        if (!Array.isArray(urls)) {
          continue;
        }
        const list: string[] = [];
        for (const value of urls) {
          if (typeof value !== 'string') {
            continue;
          }
          const url = (value as string).trim();
          if (url.startsWith('https://') && url.length > 8 && !list.includes(url)) {
            list.push(url);
          }
        }
        if (title.trim() !== '' && list.length > 0) {
          result.set(title, list);
        }
      }
    } catch (e) {
      // 资源缺失或格式变了都不该让儿童页白屏
    }
    ChildrenArtwork.map = result;
    return result;
  }

  /** 该片名有没有核验过的封面 */
  static has(context: common.Context, title: string): boolean {
    return ChildrenArtwork.ensure(context).has(title);
  }

  /** 取第一张候选封面；没有就返回空串 */
  static firstUrl(context: common.Context, title: string): string {
    const list = ChildrenArtwork.ensure(context).get(title);
    return list !== undefined && list.length > 0 ? list[0] : '';
  }

  static urls(context: common.Context, title: string): string[] {
    return (ChildrenArtwork.ensure(context).get(title) ?? []).slice();
  }

  static count(context: common.Context): number {
    return ChildrenArtwork.ensure(context).size;
  }
}
