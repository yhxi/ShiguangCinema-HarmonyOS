/**
 * 文本清洗与片名归一（对齐 Android 版 TextUtils.kt）。
 *
 * 这里放的都是纯函数：搜索命中率、历史记录归一、详情简介显示共用同一套规则，
 * 散在页面里改起来容易顾此失彼；单独成文件也方便被 node 测试直接覆盖。
 */

/** 采集站的简介常带 `<p>` / `<br>` / `&nbsp;`，直接显示会很脏 */
export function stripHtml(text: string): string {
  if (text === '') {
    return '';
  }
  return text
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/<\/?[a-zA-Z][^>]*>/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * 去掉括号注记、年份与标点，得到更可能被采集站命中的片名。
 * 豆瓣条目常带「（2023）」「：副标题」这类噪声，直接拿去搜采集站经常一条都中不了。
 */
export function cleanKeyword(keyword: string): string {
  if (keyword === '') {
    return '';
  }
  return keyword
    .replace(/[（(\[【][^）)\]】]*[）)\]】]/g, '')
    .replace(/[·:：!！?？,，.。\-—_~、|]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/** 剧名归一：不同采集站的标题常差在空格、全角括号与分隔符上 */
export function normalizeTitle(series: string): string {
  return series.replace(/[\s·・\-—_()（）\[\]【】:：,，.。]/g, '').toLowerCase();
}

const LANG_LABEL = /中文版|英文版|普通话版|国语版|英语版|粤语版|普通话|国语|英语|粤语/g;
const SEASON_MARK = /第([一二三四五六七八九十两0-9]+)(季|部)/g;

/** 中文数字转阿拉伯数字，只处理到 99（片名里的季数不会更大） */
function seasonNumber(text: string): number {
  if (/^[0-9]+$/.test(text)) {
    return parseInt(text, 10);
  }
  const DIGITS: string = '零一二三四五六七八九';
  let total = 0;
  let current = 0;
  for (let i = 0; i < text.length; i++) {
    const ch: string = text.charAt(i);
    if (ch === '十') {
      if (current === 0) {
        current = 1;
      }
      total += current * 10;
      current = 0;
      continue;
    }
    if (ch === '两') {
      current = 2;
      continue;
    }
    const idx: number = DIGITS.indexOf(ch);
    if (idx > 0) {
      current = idx;
    }
  }
  return total + current;
}

/**
 * 同一季的判定键：去掉语言标签、标点，并把「第二季」与「第2季」统一成阿拉伯数字。
 * 跨季的续作不会被当成同一部，避免续播/换源串到别的季。
 */
export function sourceTitleKey(title: string): string {
  if (title === '') {
    return '';
  }
  const stripped: string = normalizeTitle(title.replace(LANG_LABEL, ''));
  return stripped.replace(SEASON_MARK, (match: string, num: string, unit: string): string => {
    const value: number = seasonNumber(num);
    return value > 0 ? `第${value}${unit}` : match;
  });
}

/**
 * 搜索结果排序权重：0 完全同名，1 包含关键词，2 其他。
 * 关键词为空时一律算 2，保持各源返回的原始顺序。
 */
export function searchTitleRank(title: string, query: string): number {
  const target: string = normalizeTitle(title);
  const keyword: string = normalizeTitle(query);
  if (keyword === '') {
    return 2;
  }
  if (target === keyword) {
    return 0;
  }
  return target.indexOf(keyword) >= 0 ? 1 : 2;
}

/** 首字母匹配：片名包含关键词，或拼音首字母以关键词开头（2 个字母以上放宽到包含） */
export function matchesInitials(initials: string, query: string): boolean {
  if (initials === '' || query === '') {
    return false;
  }
  const q: string = query.toLowerCase();
  if (initials.startsWith(q)) {
    return true;
  }
  return q.length >= 2 && initials.indexOf(q) >= 0;
}
