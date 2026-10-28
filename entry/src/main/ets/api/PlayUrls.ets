/** 原生媒体地址（带明确媒体扩展名） */
const MEDIA_EXT = /\.(m3u8|mp4|m4v|mov|mkv|ts|mpd|flv)(?:[?#]|$)/i;
/** 明确是网页的扩展名 */
const WEB_PAGE_EXT = /\.(?:html?|php|jsp|aspx|asp|do|action)(?:[?#]|$)/i;
/** 明确是网页播放器 / 分享页的路径 */
const WEB_PLAYER_PATH = /\/(?:player|play|vodplay|share|embed)(?:[/?#.]|$)/i;

/** 既不是媒体扩展名、又长得像网页播放器 —— 这种地址交给播放器必定失败 */
export function isWebPlayerUrl(url: string): boolean {
  if (MEDIA_EXT.test(url)) { return false; }
  return WEB_PAGE_EXT.test(url) || WEB_PLAYER_PATH.test(url);
}

/** Select a native media line rather than the provider's web player line. */
export function parsePlayUrls(raw: string, playFrom: string = ''): string[] {
  if (raw.trim() === '') { return []; }
  const lines = raw.split('$$$');
  const labels = playFrom.toLowerCase().split('$$$');
  let selected: string[] = [];
  let bestScore = -1;
  for (let i = 0; i < lines.length; i++) {
    const urls: string[] = [];
    let mediaCount = 0;
    let webCount = 0;
    for (const part of lines[i].split('#')) {
      const segment = part.trim();
      const separator = segment.indexOf('$');
      const url = (separator >= 0 ? segment.substring(separator + 1) : segment).trim();
      if (!/^https?:\/\//i.test(url)) { continue; }
      urls.push(url);
      if (MEDIA_EXT.test(url)) { mediaCount++; }
      else if (isWebPlayerUrl(url)) { webCount++; }
    }
    if (urls.length === 0) { continue; }
    // Inspect all episodes so a single malformed URL cannot choose a web line.
    const label = i < labels.length ? labels[i] : '';
    // 原生媒体线路优先；明确是网页播放器的线路重罚，避免整条线路都是网页时仍被选中
    const score = mediaCount / urls.length * 2000 + (label.includes('m3u8') ? 1000 : 0) -
      webCount / urls.length * 1500;
    if (score > bestScore) {
      bestScore = score;
      selected = urls;
    }
  }
  // 所有线路都是网页播放器地址时返回空：让上层提示"没有可播放的地址"，
  // 而不是把 HTML 页面丢给 AVPlayer 报一个含糊的播放失败。
  if (selected.length > 0) {
    let allWeb = true;
    for (const url of selected) {
      if (!isWebPlayerUrl(url)) { allWeb = false; break; }
    }
    if (allWeb) { return []; }
  }
  return selected;
}
