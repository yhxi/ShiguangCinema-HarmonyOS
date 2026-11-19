/** Bare numbers count only when provided as labels. URL basenames need an explicit episode marker. */
function episodeNumber(label: string, url: string): number {
  const trimmed = label.trim();
  const token = trimmed === '' ? (url.split(/[?#]/)[0].split('/').pop() ?? '') : trimmed;
  const numbered = token.match(/^第\s*(\d+)\s*[集话話]/) ??
    token.match(/^(?:s\d+[ ._-]*)?e(?:p(?:isode)?)?[ ._-]*(\d+)(?=$|[ ._-])/i) ??
    (trimmed !== '' ? token.match(/^(\d+)$/) : null);
  return numbered === null ? -1 : Number(numbered[1]);
}

function episodeSeason(label: string, url: string): string {
  const token = label !== '' ? label : (url.split(/[?#]/)[0].split('/').pop() ?? '');
  const match = token.match(/^s(\d+)[ ._-]*e\d+/i);
  return match === null ? '' : Number(match[1]).toString();
}

export function matchEpisodeIndex(index: number, urls: string[], labels: string[],
  otherUrls: string[], otherLabels: string[]): number {
  if (index < 0 || index >= urls.length) { return -1; }
  const label = (labels[index] ?? '').trim().toLowerCase();
  const number = episodeNumber(label, urls[index]);
  const currentSeason = episodeSeason(label, urls[index]);
  if (urls.length === 1 && otherUrls.length === 1 && label === '' &&
    (otherLabels[0] ?? '').trim() === '' && number < 0 && episodeNumber('', otherUrls[0]) < 0) { return 0; }
  let match = -1;
  for (let i = 0; i < otherUrls.length; i++) {
    const candidateLabel = (otherLabels[i] ?? '').trim().toLowerCase();
    const candidateSeason = episodeSeason(candidateLabel, otherUrls[i]);
    if (currentSeason !== '' && candidateSeason !== '' && currentSeason !== candidateSeason) { continue; }
    const same = (urls[index] !== '' && urls[index] === otherUrls[i]) || (number >= 0
      ? episodeNumber(candidateLabel, otherUrls[i]) === number : label !== '' && label === candidateLabel);
    if (same) {
      if (match >= 0) { return -1; }
      match = i;
    }
  }
  return match;
}

/** Older history entries only contain the index. Labelled entries must match uniquely. */
export function historyEpisodeIndex(index: number, label: string, urls: string[], labels: string[]): number {
  if (label.trim() !== '') { return matchEpisodeIndex(0, [''], [label], urls, labels); }
  return Number.isInteger(index) && index >= 0 && index < urls.length ? index : -1;
}
