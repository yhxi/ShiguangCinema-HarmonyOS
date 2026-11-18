import { Context } from '@kit.AbilityKit';
import { Detail, SourceConfig } from '../api/Models';
import { RouteParams } from '../pages/RouteParams';
import { EpisodeCache } from '../store/EpisodeCache';
import { WatchEntry } from '../store/Prefs';
import { Session } from '../store/Session';

/** Resolve a history entry into a player route without displaying the detail page. */
export async function resumePlaybackParams(context: Context, entry: WatchEntry, session: Session): Promise<RouteParams> {
  if (entry.serverUrl.replace(/\/+$/, '') !== session.serverUrl.replace(/\/+$/, '')) {
    throw new Error('这条记录属于其他服务端，请先切换到对应服务端');
  }
  const index = entry.episodeIndex;
  if (!Number.isInteger(index) || index < 0) { throw new Error('观看记录的集数无效'); }
  const cached = EpisodeCache.getRecord(context, entry.serverUrl, entry.sourceUrl, entry.vodId);
  let episodes = cached?.urls ?? null;
  let episodeLabels = cached?.labels ?? [];
  if (episodes === null || index >= episodes.length) {
    const api = session.api;
    if (api === null) { throw new Error('请先连接服务端再继续播放'); }
    let source: SourceConfig | null = null;
    for (const item of session.sources) {
      if (item.url === entry.sourceUrl) { source = item; break; }
    }
    if (source === null) {
      source = { name: entry.sourceUrl, url: entry.sourceUrl, detail: '', isAdult: false, enabled: true };
    }
    try {
      let detail: Detail;
      if (session.directCms.shouldTryDirect(source)) {
        try { detail = await session.directCms.detail(source, entry.vodId); }
        catch (e) { detail = await api.detail(entry.vodId, source); }
      } else { detail = await api.detail(entry.vodId, source); }
      episodes = detail.episodes;
      episodeLabels = detail.episodeLabels ?? [];
    } catch (e) {
      throw new Error('无法获取选集，请检查网络或片源后重试');
    }
    if (entry.serverUrl.replace(/\/+$/, '') !== session.serverUrl.replace(/\/+$/, '')) {
      throw new Error('服务端已切换，请重新选择观看记录');
    }
    EpisodeCache.put(context, entry.serverUrl, entry.sourceUrl, entry.vodId, episodes, episodeLabels);
  }
  if (index >= episodes.length || episodes[index] === '') {
    throw new Error('上次观看的集数已不可用，请从搜索结果重新选择');
  }
  return { episodes: JSON.stringify(episodes), episodeLabels: JSON.stringify(episodeLabels), index: index.toString(), title: entry.title,
    cover: entry.cover, sourceUrl: entry.sourceUrl, vodId: entry.vodId,
    resumeMs: Math.max(0, entry.positionMs).toString(), forceResume: '1' };
}
