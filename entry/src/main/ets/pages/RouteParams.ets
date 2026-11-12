export interface RouteParams {
  mode?: string;
  keyword?: string;
  sourceUrl?: string;
  vodId?: string;
  resumeKey?: string;
  title?: string;
  episodes?: string;
  index?: string;
  cover?: string;
  resumeMs?: string;
  isLive?: string;
  /** 从儿童乐园点进来：搜索页据此显示「返回儿童乐园」 */
  fromChildren?: string;
  /** 从播放页点「换源」进来：搜索页据此说明是在换源 */
  fromPlayer?: string;
  /** 独立直播播放器：频道地址与名称表（JSON 数组字符串）、当前序号、请求头 */
  channelUrls?: string;
  channelNames?: string;
  channelIndex?: string;
  channelHeaders?: string;
}
