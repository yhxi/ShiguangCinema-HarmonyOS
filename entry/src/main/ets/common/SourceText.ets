/**
 * 「名称,网址」批量文本 -> 片源列表（对齐常见采集站分享格式）。
 *
 * 用户从别处拷来的清单长这样：
 *   虎牙,https://www.huyaapi.com/api.php/provide/vod/from/hym3u8
 *   火狐,https://hhzyapi.com/api.php/provide/vod
 * 也可能只贴一个网址进来。这里统一解析、清洗并兜底命名，纯函数方便测试。
 */

export interface ParsedSource {
  name: string;
  url: string;
}

/** 取最后一个斜杠前的主机部分做名称兜底：「https://a.b/c/d」→「a.b」 */
export function hostLabelOf(url: string): string {
  const without = url.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, '');
  const host = without.split('/')[0];
  return host !== '' ? host : url;
}

/** 是否是合法的采集站地址（http/https 开头，且不是明显残缺的行） */
export function looksLikeSourceUrl(text: string): boolean {
  return /^https?:\/\/\S+\.\S+/i.test(text.trim());
}

/**
 * 解析多行文本。规则：
 *   · 按行拆分，忽略空行与 # 开头的注释行
 *   · 第一个逗号（中文逗号也算）之前是名称，之后是地址
 *   · 没有逗号时整行按地址处理
 *   · 地址必须以 http(s):// 开头，否则整行跳过（比如误粘了标题行）
 */
export function parseSourceLines(text: string): ParsedSource[] {
  const out: ParsedSource[] = [];
  if (text.trim() === '') {
    return out;
  }
  const lines = text.split(/\r?\n/);
  for (const raw of lines) {
    const line = raw.trim();
    if (line === '' || line.startsWith('#')) {
      continue;
    }
    let name = '';
    let url = line;
    const comma = indexOfFirst(line, [',', '，']);
    if (comma >= 0) {
      const first = line.substring(0, comma).trim();
      const rest = line.substring(comma + 1).trim();
      // 常规是「名称,地址」，也可能有人贴成「地址,名称」；看哪一段是合法网址
      if (looksLikeSourceUrl(first) && !looksLikeSourceUrl(rest)) {
        url = first;
        name = rest;
      } else {
        name = first;
        url = rest;
      }
    }
    if (!looksLikeSourceUrl(url)) {
      continue;
    }
    url = url.replace(/\s+/g, '');
    if (name === '') {
      name = hostLabelOf(url);
    }
    if (name.length > 24) {
      name = name.substring(0, 24);
    }
    let dup = false;
    for (const existing of out) {
      if (existing.url.replace(/\/+$/, '') === url.replace(/\/+$/, '')) {
        dup = true;
        break;
      }
    }
    if (!dup) {
      out.push({ name: name, url: url });
    }
  }
  return out;
}

/** 找一组分隔符里最先出现的位置；都没有返回 -1 */
function indexOfFirst(text: string, seps: string[]): number {
  let best = -1;
  for (const sep of seps) {
    const idx = text.indexOf(sep);
    if (idx >= 0 && (best < 0 || idx < best)) {
      best = idx;
    }
  }
  return best;
}
