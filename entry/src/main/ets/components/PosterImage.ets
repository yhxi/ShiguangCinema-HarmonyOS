import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';

class PosterCache {
  private static images: Map<string, image.PixelMap> = new Map();
  private static pending: Map<string, Promise<image.PixelMap | null>> = new Map();
  private static active: number = 0;
  private static waiting: Array<() => void> = [];

  static clear(): void {
    PosterCache.images.forEach((bitmap: image.PixelMap) => { bitmap.release().catch(() => {}); });
    PosterCache.images.clear();
  }

  static async get(url: string, proxy: string, cookie: string): Promise<image.PixelMap | null> {
    const cached = PosterCache.images.get(url);
    if (cached !== undefined) { return cached; }
    const pendingKey = `${url}|${proxy}|${cookie}`;
    const existing = PosterCache.pending.get(pendingKey);
    if (existing !== undefined) { return existing; }
    const job = PosterCache.load(url, proxy, cookie);
    PosterCache.pending.set(pendingKey, job);
    try { return await job; } finally { PosterCache.pending.delete(pendingKey); }
  }

  private static async load(url: string, proxy: string, cookie: string): Promise<image.PixelMap | null> {
    if (PosterCache.active >= 6) {
      await new Promise<void>((resolve: () => void) => { PosterCache.waiting.push(resolve); });
    }
    PosterCache.active++;
    try {
      let result: image.PixelMap | null = null;
      try { result = await PosterCache.fetch(url, false, ''); } catch (e) { /* Try proxy. */ }
      if (result === null && proxy !== '') {
        try { result = await PosterCache.fetch(proxy, true, cookie); } catch (e) { /* Leave placeholder. */ }
      }
      if (result !== null) {
        if (PosterCache.images.size >= 48) {
          let first: string = '';
          PosterCache.images.forEach((_value: image.PixelMap, key: string) => { if (first === '') { first = key; } });
          if (first !== '') { PosterCache.images.delete(first); }
        }
        PosterCache.images.set(url, result);
      }
      return result;
    } finally {
      PosterCache.active--;
      const next = PosterCache.waiting.shift();
      if (next !== undefined) { next(); }
    }
  }

  private static async fetch(url: string, proxy: boolean, cookie: string): Promise<image.PixelMap | null> {
    const request = http.createHttp();
    try {
      const headers: Record<string, string> = { 'User-Agent': 'Mozilla/5.0' };
      if (!proxy && (url.includes('doubanio.com') || url.includes('douban.com'))) {
        headers['Referer'] = 'https://movie.douban.com/';
      }
      if (proxy && cookie !== '') { headers['Cookie'] = cookie; }
      const response = await request.request(url, {
        method: http.RequestMethod.GET, header: headers, connectTimeout: 5000, readTimeout: 10000,
        expectDataType: http.HttpDataType.ARRAY_BUFFER, maxLimit: 4 * 1024 * 1024
      });
      if (response.responseCode < 200 || response.responseCode >= 300 || !(response.result instanceof ArrayBuffer)) {
        return null;
      }
      const source = image.createImageSource(response.result as ArrayBuffer);
      try { return await source.createPixelMap({ desiredSize: { width: 360, height: 540 } }); }
      finally { await source.release(); }
    } finally { request.destroy(); }
  }
}

export function clearPosterCache(): void { PosterCache.clear(); }

@Component
export struct PosterImage {
  @Prop @Watch('loadPoster') url: string = '';
  @Prop proxy: string = '';
  @Prop @Watch('loadPoster') cookie: string = '';
  @Prop posterHeight: number = 240;
  @State bitmap: image.PixelMap | null = null;
  private active: boolean = true;

  aboutToAppear(): void { this.loadPoster(); }

  private loadPoster(): void {
    if (this.url === '') { return; }
    const requested = this.url;
    PosterCache.get(requested, this.proxy, this.cookie).then((bitmap: image.PixelMap | null) => {
      if (this.active && this.url === requested) { this.bitmap = bitmap; }
    }).catch(() => {});
  }

  aboutToDisappear(): void { this.active = false; }

  build() {
    Stack() {
      if (this.bitmap !== null) {
        Image(this.bitmap).width('100%').height('100%').objectFit(ImageFit.Cover)
      }
    }.width('100%').height(this.posterHeight).backgroundColor('#DCE8DF').borderRadius(13).clip(true)
  }
}
