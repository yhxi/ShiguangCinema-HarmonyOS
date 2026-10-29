import { http } from '@kit.NetworkKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { Context } from '@kit.AbilityKit';

interface GraveyardItem {
  bitmap: image.PixelMap;
  at: number;
}

interface DiskFileInfo {
  name: string;
  mtime: number;
}

const PACK_OPTIONS: image.PackingOption = { format: 'image/jpeg', quality: 82 };

/**
 * 海报缓存：内存 LRU + 磁盘两层。
 *   · 内存命中直接用；磁盘命中解码后进内存，不再走网络
 *   · 逐出的 PixelMap 不立即 release（可能还被画面上的 Image 引用着），
 *     放进"墓地"延迟 2 分钟再放弃缓存引用，交由系统管理生命周期
 *   · 磁盘上限 300 张，超出按修改时间删最旧的
 */
class PosterCache {
  private static images: Map<string, image.PixelMap> = new Map();
  private static failures: Map<string, number> = new Map();
  private static pending: Map<string, Promise<image.PixelMap | null>> = new Map();
  private static active: number = 0;
  private static waiting: Array<() => void> = [];
  private static graveyard: GraveyardItem[] = [];
  private static diskDir: string = '';
  private static diskBroken: boolean = false;
  private static diskWrites: number = 0;
  private static readonly MEMORY_LIMIT: number = 48;
  private static readonly DISK_LIMIT: number = 300;
  private static readonly GRAVEYARD_MS: number = 120000;

  static clear(): void {
    PosterCache.images.clear();
    PosterCache.graveyard = [];
    PosterCache.failures.clear();
    PosterCache.diskBroken = false;
  }

  static async get(context: Context, url: string, proxy: string, cookie: string): Promise<image.PixelMap | null> {
    if (PosterCache.diskDir === '' && !PosterCache.diskBroken) {
      try { PosterCache.diskDir = `${context.filesDir}/poster-cache`; } catch (e) { PosterCache.diskBroken = true; }
    }
    PosterCache.releaseGraveyard(false);
    const cached = PosterCache.images.get(url);
    if (cached !== undefined) {
      // 重新插入 = 刷新 LRU 位置，最常看的不会被挤掉
      PosterCache.images.delete(url);
      PosterCache.images.set(url, cached);
      return cached;
    }
    const pendingKey = `${url}|${proxy}|${cookie}`;
    const failedAt = PosterCache.failures.get(pendingKey);
    if (failedAt !== undefined && Date.now() - failedAt < 300000) { return null; }
    PosterCache.failures.delete(pendingKey);
    const existing = PosterCache.pending.get(pendingKey);
    if (existing !== undefined) { return existing; }
    const job = PosterCache.load(url, proxy, cookie);
    PosterCache.pending.set(pendingKey, job);
    try {
      const result = await job;
      if (result === null) {
        if (PosterCache.failures.size >= 300) { PosterCache.failures.clear(); }
        PosterCache.failures.set(pendingKey, Date.now());
      }
      return result;
    } finally { PosterCache.pending.delete(pendingKey); }
  }

  private static async load(url: string, proxy: string, cookie: string): Promise<image.PixelMap | null> {
    if (PosterCache.active >= 6) {
      await new Promise<void>((resolve: () => void) => { PosterCache.waiting.push(resolve); });
    }
    PosterCache.active++;
    try {
      // 1) 磁盘
      const fromDisk = await PosterCache.readDisk(url);
      if (fromDisk !== null) {
        PosterCache.remember(url, fromDisk);
        return fromDisk;
      }
      // 2) 网络（直连失败再走代理）
      let result: image.PixelMap | null = null;
      try { result = await PosterCache.fetch(url, false, ''); } catch (e) { /* Try proxy. */ }
      if (result === null && proxy !== '') {
        try { result = await PosterCache.fetch(proxy, true, cookie); } catch (e) { /* Leave placeholder. */ }
      }
      if (result !== null) {
        PosterCache.remember(url, result);
        PosterCache.writeDisk(url, result);
      }
      return result;
    } finally {
      PosterCache.active--;
      const next = PosterCache.waiting.shift();
      if (next !== undefined) { next(); }
    }
  }

  /** 放进内存缓存；满了就把最旧的挪进墓地延迟释放 */
  private static remember(url: string, bitmap: image.PixelMap): void {
    if (PosterCache.images.size >= PosterCache.MEMORY_LIMIT) {
      let first: string = '';
      PosterCache.images.forEach((_value: image.PixelMap, key: string) => { if (first === '') { first = key; } });
      if (first !== '') {
        const victim = PosterCache.images.get(first);
        if (victim !== undefined) {
          // 画面上的 Image 可能还引用着它，先延迟移除缓存引用
          const item: GraveyardItem = { bitmap: victim, at: Date.now() };
          PosterCache.graveyard.push(item);
        }
        PosterCache.images.delete(first);
      }
    }
    PosterCache.images.set(url, bitmap);
  }

  /** 超过宽限期后放弃缓存引用，不主动释放可能仍在显示的位图 */
  private static releaseGraveyard(force: boolean): void {
    if (PosterCache.graveyard.length === 0) { return; }
    const now = Date.now();
    const keep: GraveyardItem[] = [];
    for (const item of PosterCache.graveyard) {
      if (force || now - item.at >= PosterCache.GRAVEYARD_MS) {
        // Drop our reference; the UI may still hold the PixelMap.
      } else {
        keep.push(item);
      }
    }
    PosterCache.graveyard = keep;
  }

  // ---------- 磁盘层 ----------

  private static diskPath(url: string): string {
    // FNV-1a：URL 哈希做文件名，避免特殊字符问题
    let hash = 0x811c9dc5;
    for (let i = 0; i < url.length; i++) {
      hash ^= url.charCodeAt(i);
      hash = (hash * 0x01000193) >>> 0;
    }
    return `${PosterCache.diskDir}/${hash.toString(16)}-${url.length}.jpg`;
  }

  private static async readDisk(url: string): Promise<image.PixelMap | null> {
    if (PosterCache.diskBroken || PosterCache.diskDir === '') { return null; }
    const path = PosterCache.diskPath(url);
    try {
      if (!fs.accessSync(path)) { return null; }
      const source = image.createImageSource(path);
      try {
        return await source.createPixelMap({ desiredSize: { width: 360, height: 540 } });
      } finally { await source.release().catch(() => {}); }
    } catch (e) {
      // 磁盘层坏了就停用，别让每张海报都白等一次报错
      return null;
    }
  }

  private static writeDisk(url: string, bitmap: image.PixelMap): void {
    if (PosterCache.diskBroken || PosterCache.diskDir === '') { return; }
    // 打包 + 落盘是纯后台动作，失败也不影响界面
    const packer = image.createImagePacker();
    packer.packToData(bitmap, PACK_OPTIONS)
      .then((data: ArrayBuffer) => {
        try {
          fs.mkdirSync(PosterCache.diskDir, true);
          const path = PosterCache.diskPath(url);
          const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
          try { fs.writeSync(file.fd, data); } finally { fs.closeSync(file); }
          PosterCache.diskWrites++;
          if (PosterCache.diskWrites % 20 === 0) { PosterCache.trimDisk(); }
        } catch (e) { /* 磁盘写失败只影响下次启动的离线体验 */ }
      })
      .catch(() => {});
  }

  /** 磁盘超过上限时按修改时间删最旧的 */
  private static trimDisk(): void {
    try {
      const names: string[] = fs.listFileSync(PosterCache.diskDir);
      if (names.length <= PosterCache.DISK_LIMIT) { return; }
      const stats: DiskFileInfo[] = [];
      for (const name of names) {
        try {
          const st = fs.statSync(`${PosterCache.diskDir}/${name}`);
          const info: DiskFileInfo = { name: name, mtime: st.mtime };
          stats.push(info);
        } catch (e) { /* File vanished. */ }
      }
      stats.sort((a: DiskFileInfo, b: DiskFileInfo) => a.mtime - b.mtime);
      let excess = stats.length - PosterCache.DISK_LIMIT + 30;
      for (const item of stats) {
        if (excess <= 0) { break; }
        try { fs.unlinkSync(`${PosterCache.diskDir}/${item.name}`); excess--; } catch (e) { /* Already gone. */ }
      }
    } catch (e) { /* 目录读不到就算了 */ }
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

  aboutToAppear(): void { this.active = true; this.loadPoster(); }

  private loadPoster(): void {
    if (this.url === '') { this.bitmap = null; return; }
    this.bitmap = null;
    const requested = this.url;
    PosterCache.get(getContext(this), requested, this.proxy, this.cookie).then((bitmap: image.PixelMap | null) => {
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
