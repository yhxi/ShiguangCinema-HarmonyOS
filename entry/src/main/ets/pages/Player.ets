/**
 * 播放页 —— AVPlayer + XComponent：
 *   · m3u8/HLS 播放
 *   · 续播（进入即 seek 到上次进度）
 *   · 上一集/下一集、自动连播（播完自动下一集）
 *   · 进度条拖动、暂停/播放
 *   · 每 30 秒与退出时写观看历史（Prefs）
 */

import { media } from '@kit.MediaKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, window, promptAction } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { wantAgent } from '@kit.AbilityKit';
import { fitVideoFrame } from './VideoLayout';
import { Prefs, PlaybackSettings, SkipMarks, WatchEntry, entryFromStatus } from '../store/Prefs';
import { Session } from '../store/Session';
import { SourceConfig, SearchItem, Detail } from '../api/Models';

interface PlayerMenuAction { label: string; action: () => void; }
interface PlayerTrack { index: number; type: number; label: string; }

/** 字节/秒 → 人类可读 */
function formatNetSpeed(bytesPerSec: number): string {
  if (bytesPerSec >= 1024 * 1024) { return `${(bytesPerSec / 1024 / 1024).toFixed(1)} MB/s`; }
  if (bytesPerSec >= 1024) { return `${Math.round(bytesPerSec / 1024)} KB/s`; }
  return `${Math.round(bytesPerSec)} B/s`;
}

@Entry
@Component
struct Player {
  @State playing: boolean = false;
  @State curMs: number = 0;
  @State durMs: number = 0;
  @State episodeIndex: number = 0;
  @State errorMsg: string = '';
  @State showControls: boolean = true;
  @State title: string = '';
  @State showEpisodes: boolean = false;
  @State speedIndex: number = 1;
  @State autoNext: boolean = true;
  @State seekStepSeconds: number = 10;
  @State rememberProgress: boolean = true;
  @State resumeThresholdSeconds: number = 5;
  @State cropVideo: boolean = false;
  @State backgroundPlayback: boolean = false;
  @State loadMessage: string = '正在创建播放窗口…';
  @State buffering: boolean = false;
  @State isPaused: boolean = false;
  @State netSpeed: string = '';
  @State videoWidth: number = 16;
  @State videoHeight: number = 9;
  @State frameWidth: number = 0;
  @State frameHeight: number = 0;
  @State activeMenu: string = '';
  @State locked: boolean = false;
  @State pureFullscreen: boolean = false;
  @State introEndMs: number = 90000;
  @State outroStartMs: number = 0;
  @State autoIntro: boolean = false;
  @State autoOutro: boolean = false;
  @State availableBitrates: number[] = [];
  @State selectedBitrate: number = 0;
  @State mediaTracks: PlayerTrack[] = [];
  @State gestureMessage: string = '';
  @State sleepMinutes: number = 0;
  @State subtitleText: string = '';
  private subtitleTimer: number = -1;
  private previousBrightness: number = -1;
  private brightnessLevel: number = 0.5;
  private volumeLevel: number = 1;
  private gestureKind: string = '';
  private gestureStartX: number = 0;
  private gestureStartTime: number = 0;
  private gestureStartLevel: number = 0;
  private lastGestureUpdate: number = 0;
  private hudTimer: number = -1;
  private sleepTimer: number = -1;
  private introApplied: boolean = false;
  private marksLoaded: boolean = false;
  private outroMarkedEpisode: number = -1;

  private session: Session = Session.getInstance();
  private player: media.AVPlayer | null = null;
  private xcController: XComponentController = new XComponentController();
  private episodes: string[] = [];
  private sourceUrl: string = '';
  private vodId: string = '';
  private cover: string = '';
  private resumeMs: number = 0;
  private prefs: Prefs | null = null;
  private saveTimerId: number = -1;
  private hideTimerId: number = -1;
  private surfaceReady: boolean = false;
  private surfaceId: string = '';
  private switching: boolean = false;
  private userDragging: boolean = false;
  private usePlainUrl: boolean = true;
  private alternateTried: boolean = false;
  /** 网速估算：CACHED_DURATION 的增长速率 × 当前码率 */
  private cachedMs: number = -1;
  private lastCachedMs: number = -1;
  private lastCachedAt: number = 0;
  private activeBitrate: number = 0;
  private speedTimer: number = -1;
  /** 自愈：同源已重试过一次 / 已尝试过自动换源 */
  private sameUrlRetried: boolean = false;
  private sourceSwitchTried: boolean = false;
  /** 换源时已尝试过、不再回头的片源地址 */
  private triedSourceUrls: Set<string> = new Set();
  private startupTimer: number = -1;
  private firstFrameSeen: boolean = false;
  private disposed: boolean = false;
  private playerGeneration: number = 0;
  private settingsReady: boolean = false;
  private resumeRequestedManually: boolean = false;
  private viewportWidth: number = 0;
  private viewportHeight: number = 0;
  private playbackWindow: window.Window | null = null;
  private backgroundSession: avSession.AVSession | null = null;
  private backgroundTaskActive: boolean = false;
  private previousOrientation: window.Orientation = window.Orientation.UNSPECIFIED;
  private previousKeepScreenOn: boolean = false;
  private speeds: media.PlaybackSpeed[] = [media.PlaybackSpeed.SPEED_FORWARD_0_75_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_00_X, media.PlaybackSpeed.SPEED_FORWARD_1_25_X,
    media.PlaybackSpeed.SPEED_FORWARD_1_50_X, media.PlaybackSpeed.SPEED_FORWARD_1_75_X,
    media.PlaybackSpeed.SPEED_FORWARD_2_00_X];
  private speedLabels: string[] = ['0.75×', '1.0×', '1.25×', '1.5×', '1.75×', '2.0×'];
  /** 直播模式：无进度条/不写历史/不自动连播 */
  private isLive: boolean = false;

  aboutToAppear(): void {
    this.enterPlaybackWindow();
    const params = router.getParams() as Record<string, string> | undefined;
    if (params === undefined) {
      this.errorMsg = '缺少播放参数';
      return;
    }
    try {
      const parsed: Object = JSON.parse(params['episodes'] ?? '[]') as Object;
      if (Array.isArray(parsed)) {
        for (const ep of parsed as Object[]) {
          if (typeof ep === 'string') {
            this.episodes.push(ep as string);
          }
        }
      }
    } catch (e) {
      this.errorMsg = '选集参数无效';
      return;
    }
    this.episodeIndex = parseInt(params['index'] ?? '0');
    this.title = params['title'] ?? '';
    this.cover = params['cover'] ?? '';
    this.sourceUrl = params['sourceUrl'] ?? '';
    this.vodId = params['vodId'] ?? '';
    this.resumeMs = parseInt(params['resumeMs'] ?? '0');
    if (isNaN(this.episodeIndex)) {
      this.episodeIndex = 0;
    }
    if (this.episodeIndex < 0 || this.episodeIndex >= this.episodes.length) {
      this.episodeIndex = 0;
    }
    if (isNaN(this.resumeMs)) {
      this.resumeMs = 0;
    }
    this.isLive = (params['isLive'] ?? '0') === '1';
    // 当前源记为"已尝试"，换源自愈时从别的源找
    this.triedSourceUrls = new Set([this.sourceUrl]);
    this.startupTimer = setTimeout(() => {
      if (!this.disposed && !this.surfaceReady) {
        this.loadMessage = '';
        this.errorMsg = '视频窗口创建超时，请返回后重新打开。';
      }
    }, 8000);
    Prefs.get(getContext(this)).then((p: Prefs) => {
      this.prefs = p;
      p.getSkipMarks(this.title).then((marks: SkipMarks) => {
        this.introEndMs = marks.introEndMs; this.outroStartMs = marks.outroStartMs;
        this.autoIntro = marks.autoIntro; this.autoOutro = marks.autoOutro;
        this.marksLoaded = true;
      }).catch(() => {});
      p.getPlaybackSettings().then((settings: PlaybackSettings) => {
        if (settings.speedIndex >= 0 && settings.speedIndex < this.speeds.length) { this.speedIndex = settings.speedIndex; }
        this.autoNext = settings.autoNext;
        this.seekStepSeconds = settings.seekStepSeconds;
        this.rememberProgress = settings.rememberProgress;
        this.resumeThresholdSeconds = settings.resumeThresholdSeconds;
        this.cropVideo = settings.cropVideo;
        this.backgroundPlayback = settings.backgroundPlayback;
        this.applyScale();
        if (!this.isLive && this.speedIndex !== 1 && this.playing && this.player !== null) {
          try { this.player.setSpeed(this.speeds[this.speedIndex]); } catch (e) { /* Stream may not support speed changes. */ }
        }
      }).catch(() => {}).finally(() => { this.onSettingsReady(); });
    }).catch(() => { this.onSettingsReady(); });
  }

  private onSettingsReady(): void {
    if (this.disposed) { return; }
    this.settingsReady = true;
    if (this.surfaceReady && this.player === null && !this.switching) { this.setupPlayer(); }
  }

  /** 切后台再回前台后系统可能恢复导航指示条，这里补一次隐藏 */
  onPageShow(): void {
    if (this.disposed) { return; }
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      if (this.disposed) { return; }
      win.setSpecificSystemBarEnabled('navigationIndicator', false).catch(() => {});
    }).catch(() => {});
  }

  onBackPress(): boolean {
    if (this.activeMenu !== '') { this.activeMenu = ''; this.scheduleHide(); return true; }
    if (this.showEpisodes) { this.showEpisodes = false; this.scheduleHide(); return true; }
    if (this.locked) { this.locked = false; this.scheduleHide(); return true; }
    if (this.pureFullscreen) { this.toggleFullscreen(); return true; }
    return false;
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.playerGeneration++;
    this.saveProgress(true);
    this.stopSaveTimer();
    this.stopStartupTimer();
    this.stopSpeedTimer();
    if (this.hudTimer >= 0) { clearTimeout(this.hudTimer); }
    if (this.sleepTimer >= 0) { clearTimeout(this.sleepTimer); }
    if (this.subtitleTimer >= 0) { clearTimeout(this.subtitleTimer); }
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
    }
    this.releasePlayer();
    this.stopBackgroundPlayback();
    this.restorePlaybackWindow();
  }

  private async enterPlaybackWindow(): Promise<void> {
    try {
      const win = await window.getLastWindow(getContext(this));
      if (this.disposed) { return; }
      this.playbackWindow = win;
      this.previousOrientation = win.getPreferredOrientation();
      this.previousKeepScreenOn = win.getWindowProperties().isKeepScreenOn;
      await win.setSpecificSystemBarEnabled('navigationIndicator', false);
      this.previousBrightness = win.getWindowProperties().brightness;
      this.brightnessLevel = this.previousBrightness >= 0 ? this.previousBrightness : 0.5;
      await win.setPreferredOrientation(window.Orientation.AUTO_ROTATION_LANDSCAPE);
      if (this.disposed) { this.restorePlaybackWindow(); return; }
      await win.setWindowKeepScreenOn(true);
      if (this.disposed) { this.restorePlaybackWindow(); }
    } catch (e) {
      hilog.warn(0, 'ShiguangCinema', 'player window setup failed: %{public}s', (e as Error).message);
    }
  }

  private restorePlaybackWindow(): void {
    const win = this.playbackWindow;
    if (win === null) { return; }
    win.setPreferredOrientation(this.previousOrientation).catch(() => {});
    win.setWindowKeepScreenOn(this.previousKeepScreenOn).catch(() => {});
    win.setWindowBrightness(this.previousBrightness).catch(() => {});
    win.setSpecificSystemBarEnabled('navigationIndicator', true).catch(() => {});
  }

  private updateVideoFrame(): void {
    const frame = fitVideoFrame(this.viewportWidth, this.viewportHeight, this.videoWidth, this.videoHeight, this.cropVideo);
    this.frameWidth = frame.width;
    this.frameHeight = frame.height;
  }

  private releasePlayer(): void {
    const p = this.player;
    this.player = null;
    if (p !== null) {
      p.release().catch(() => {});
    }
  }

  /** XComponent 加载完成后回调 */
  private async onSurfaceReady(): Promise<void> {
    try {
      const sid = this.xcController.getXComponentSurfaceId();
      if (sid === '') { throw new Error('视频窗口尚未创建'); }
      this.surfaceId = sid;
      this.surfaceReady = true;
      if (this.settingsReady) { await this.setupPlayer(); }
      else { this.loadMessage = '正在读取播放设置…'; }
    } catch (e) {
      this.loadMessage = '';
      this.errorMsg = `视频窗口初始化失败：${(e as Error).message}`;
    }
  }

  private async setupPlayer(): Promise<void> {
    if (this.disposed || !this.surfaceReady || this.episodes.length === 0) {
      if (this.episodes.length === 0) {
        this.errorMsg = '没有可播放的地址';
      }
      return;
    }
    const url = this.episodes[this.episodeIndex];
    this.switching = true;
    this.playing = false;
    this.firstFrameSeen = false;
    this.introApplied = false;
    this.buffering = false;
    this.isPaused = false;
    this.netSpeed = '';
    this.stopSpeedTimer();
    this.cachedMs = -1;
    this.availableBitrates = [];
    this.mediaTracks = [];
    this.subtitleText = '';
    if (this.subtitleTimer >= 0) { clearTimeout(this.subtitleTimer); this.subtitleTimer = -1; }
    this.stopSaveTimer();
    this.loadMessage = '正在连接视频…';
    const generation = ++this.playerGeneration;
    this.startStartupTimer(generation);
    const oldPlayer = this.player;
    this.player = null;
    try {
      if (oldPlayer !== null) { await this.releaseBeforeRestart(oldPlayer); }
      if (this.disposed || generation !== this.playerGeneration) { return; }
      const p = await media.createAVPlayer();
      if (this.disposed || generation !== this.playerGeneration) { await p.release().catch(() => {}); return; }
      this.player = p;
      this.bindPlayerEvents(p, generation);
      this.errorMsg = '';
      if (!this.usePlainUrl && url.toLowerCase().split('?')[0].endsWith('.m3u8')) {
        const headers: Record<string, string> = { 'User-Agent': 'CloudScreen-Android' };
        const source = media.createMediaSourceWithUrl(url, headers);
        source.setMimeType(media.AVMimeTypes.APPLICATION_M3U8);
        const strategy: media.PlaybackStrategy = { preferredBufferDuration: 5 };
        await p.setMediaSource(source, strategy);
      } else {
        p.url = url;
      }
    } catch (e) {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      if (this.handlePlaybackFailure((e as BusinessError).code, generation)) { return; }
      this.errorMsg = `起播失败：${(e as Error).message}`;
      this.loadMessage = '';
      this.stopStartupTimer();
      this.switching = false;
    }
  }

  private async releaseBeforeRestart(player: media.AVPlayer): Promise<void> {
    let timer: number = -1;
    const deadline = new Promise<void>((resolve: () => void) => { timer = setTimeout(resolve, 2000); });
    try { await Promise.race([player.release().catch(() => {}), deadline]); }
    finally { if (timer >= 0) { clearTimeout(timer); } }
  }

  private bindPlayerEvents(p: media.AVPlayer, generation: number): void {
    p.on('stateChange', (state: string) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      hilog.info(0, 'ShiguangCinema', 'player state=%{public}s generation=%{public}d', state, generation);
      if (state === 'initialized') {
        this.loadMessage = '正在解析视频并缓冲…';
        p.surfaceId = this.surfaceId;
        p.prepare().catch((e: Error) => {
          if (this.disposed || generation !== this.playerGeneration) { return; }
          if (this.handlePlaybackFailure((e as BusinessError).code, generation)) { return; }
          this.switching = false;
          this.loadMessage = '';
          this.stopStartupTimer();
          this.errorMsg = `准备播放失败：${e.message}`;
        });
      } else if (state === 'prepared') {
        if (p.width > 0 && p.height > 0) {
          this.videoWidth = p.width;
          this.videoHeight = p.height;
          this.updateVideoFrame();
        }
        this.durMs = p.duration > 0 ? p.duration : this.durMs;
        this.loadMessage = '正在显示第一帧…';
        this.applyScale();
        p.setVolume(this.volumeLevel);
        this.refreshTracks(p, generation);
        p.play().catch((e: Error) => {
          if (this.disposed || generation !== this.playerGeneration) { return; }
          if (this.handlePlaybackFailure((e as BusinessError).code, generation)) { return; }
          this.switching = false;
          this.loadMessage = '';
          this.stopStartupTimer();
          this.errorMsg = `起播失败：${e.message}`;
        });
      } else if (state === 'playing') {
        this.playing = true;
        this.isPaused = false;
        this.buffering = false;
        this.stopSpeedTimer();
        this.netSpeed = '';
        this.switching = false;
        if (!this.isLive && this.resumeMs > 0) {
          const resume = this.resumeMs;
          this.resumeMs = 0;
          if (!this.resumeRequestedManually && (!this.rememberProgress || resume < this.resumeThresholdSeconds * 1000)) {
            this.introApplied = false;
          } else {
            if (resume >= this.introEndMs) { this.introApplied = true; }
            try { p.seek(resume, media.SeekMode.SEEK_PREV_SYNC); } catch (e) { /* Start from the beginning if seeking is unsupported. */ }
          }
          this.resumeRequestedManually = false;
        }
        if (!this.isLive && this.speedIndex !== 1) {
          try { p.setSpeed(this.speeds[this.speedIndex]); } catch (e) { /* Playback continues at normal speed. */ }
        }
        this.startSaveTimer();
        if (this.backgroundPlayback) { this.startBackgroundPlayback(); }
        this.scheduleHide();
      } else if (state === 'error') {
        this.playing = false;
        this.stopBackgroundTask();
      } else if (state === 'paused') {
        this.playing = false;
        this.isPaused = true;
        this.updateBackgroundSession(false);
        this.stopBackgroundTask();
        this.stopSaveTimer();
        this.saveProgress(false);
        if (!this.locked) { this.showControls = true; }
      } else if (state === 'completed') {
        this.playing = false;
        this.updateBackgroundSession(false);
        this.stopBackgroundTask();
        if (!this.isLive && this.autoNext && this.episodeIndex < this.episodes.length - 1) {
          this.episodeIndex += 1;
          this.curMs = 0;
          this.durMs = 0;
          this.setupPlayer();
        }
      }
    });
    p.on('startRenderFrame', () => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      this.firstFrameSeen = true;
      // 起播成功后重置自愈状态：之后的失败可以再走一轮"重试 → 换源"
      this.sameUrlRetried = false;
      this.sourceSwitchTried = false;
      this.loadMessage = '';
      this.errorMsg = '';
      this.stopStartupTimer();
    });
    p.on('videoSizeChange', (width: number, height: number) => {
      if (this.disposed || generation !== this.playerGeneration || width <= 0 || height <= 0) { return; }
      this.videoWidth = width;
      this.videoHeight = height;
      this.updateVideoFrame();
    });
    p.on('availableBitrates', (bitrates: number[]) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      this.availableBitrates = bitrates.filter((value: number) => value > 0).sort((a: number, b: number) => b - a);
      if (this.selectedBitrate > 0 && this.availableBitrates.length > 0 && this.canControl()) {
        try { p.setBitrate(this.selectedBitrate); } catch (e) { this.selectedBitrate = 0; }
      }
    });
    p.on('subtitleUpdate', (info: media.SubtitleInfo) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      if (this.subtitleTimer >= 0) { clearTimeout(this.subtitleTimer); }
      this.subtitleText = info.text ?? '';
      if (info.duration !== undefined && info.duration > 0) {
        this.subtitleTimer = setTimeout(() => {
          if (generation === this.playerGeneration) { this.subtitleText = ''; }
        }, info.duration);
      }
    });
    p.on('durationUpdate', (duration: number) => {
      if (!this.disposed && generation === this.playerGeneration) { this.durMs = duration; }
    });
    p.on('timeUpdate', (time: number) => {
      if (!this.disposed && generation === this.playerGeneration && !this.userDragging) {
        this.curMs = time;
        this.applySkipMarks(time);
        if (time > 0 && p.width > 0) {
          this.firstFrameSeen = true;
          this.loadMessage = '';
          this.stopStartupTimer();
        }
      }
    });
    p.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      if (infoType === media.BufferingInfoType.BUFFERING_START) {
        this.buffering = true;
        this.startSpeedTimer();
      } else if (infoType === media.BufferingInfoType.BUFFERING_END) {
        this.buffering = false;
        this.netSpeed = '';
        this.stopSpeedTimer();
      } else if (infoType === media.BufferingInfoType.CACHED_DURATION) {
        // value = 缓冲区里可播放的时长（ms），增长速率 × 码率 ≈ 下载速度
        this.cachedMs = value;
      }
    });
    p.on('bitrateDone', (bitrate: number) => {
      if (this.disposed) { return; }
      // HLS 自适应码率切换完成时回调当前码率（bps）
      this.activeBitrate = bitrate;
    });
    p.on('error', (err: BusinessError) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      this.switching = false;
      this.playing = false;
      this.buffering = false;
      this.isPaused = false;
      this.stopSpeedTimer();
      this.showControls = true;
      if (this.handlePlaybackFailure(err.code, generation)) { return; }
      this.loadMessage = '';
      this.stopStartupTimer();
      const baseError = `播放失败（${err.code}，状态 ${p.state}）`;
      this.errorMsg = `${baseError}。正在检查播放地址…`;
      this.diagnoseStream(this.episodes[this.episodeIndex] ?? '', generation, baseError);
    });
  }

  private tryAutomaticFallback(code: number, generation: number): boolean {
    const url = this.episodes[this.episodeIndex] ?? '';
    if ((code !== 5400106 && code !== 5400104) || this.alternateTried ||
      !url.toLowerCase().split('?')[0].endsWith('.m3u8')) { return false; }
    this.alternateTried = true;
    this.usePlainUrl = !this.usePlainUrl;
    this.switching = true;
    this.errorMsg = '正在尝试另一种播放方式…';
    this.loadMessage = '正在切换播放方式…';
    this.stopStartupTimer();
    const fallbackGeneration = ++this.playerGeneration;
    setTimeout(() => {
      if (!this.disposed && fallbackGeneration === this.playerGeneration) { this.setupPlayer(); }
    }, 0);
    return true;
  }

  /**
   * 播放失败自愈，依次尝试：
   *   1. 解码 / 格式类错误 → 换播放方式（沿用原有逻辑）
   *   2. 同源重试一次（分片 404、超时等临时故障）
   *   3. 自动切换到下一个有这部片的片源
   * 都失败才把错误抛给用户手动处理。
   */
  private handlePlaybackFailure(code: number, generation: number): boolean {
    if (this.tryAutomaticFallback(code, generation)) { return true; }
    if (!this.sameUrlRetried) {
      this.sameUrlRetried = true;
      this.switching = true;
      this.errorMsg = '';
      this.loadMessage = '播放中断，正在重试…';
      this.stopStartupTimer();
      const retryGeneration = ++this.playerGeneration;
      setTimeout(() => {
        if (!this.disposed && retryGeneration === this.playerGeneration) { this.setupPlayer(); }
      }, 400);
      return true;
    }
    if (!this.sourceSwitchTried) {
      this.sourceSwitchTried = true;
      this.switching = true;
      this.loadMessage = '当前片源无法播放，正在切换片源…';
      this.stopStartupTimer();
      this.switchToNextSource();
      return true;
    }
    return false;
  }

  /** 换源后重建地址列表；episodeIndex 越界时从头放 */
  private async switchToNextSource(): Promise<void> {
    const generation = this.playerGeneration;
    const api = this.session.api;
    if (api === null || this.title.trim() === '') {
      this.finishHealFail('没有可用的服务端');
      return;
    }
    const sources = this.session.enabledSources().filter((src) => !this.triedSourceUrls.has(src.url));
    if (sources.length === 0) {
      this.finishHealFail('其他片源都已尝试过');
      return;
    }
    const cached = this.session.cachedSearch(this.title.trim());
    if (await this.trySourceCandidates(cached, generation)) { return; }
    if (this.disposed || generation !== this.playerGeneration) { return; }
    try {
      const remaining = sources.filter((src: SourceConfig) => !this.triedSourceUrls.has(src.url));
      if (remaining.length > 0) {
        const result = await api.search(this.title.trim(), remaining);
        if (this.disposed || generation !== this.playerGeneration) { return; }
        if (await this.trySourceCandidates(result.items, generation)) { return; }
      }
    } catch (e) {
      hilog.warn(0, 'ShiguangCinema', 'source switch search failed');
    }
    if (!this.disposed && generation === this.playerGeneration) {
      this.finishHealFail('其他片源也没有可播放的地址');
    }
  }

  private async trySourceCandidates(items: SearchItem[], generation: number): Promise<boolean> {
    const api = this.session.api;
    if (api === null) { return false; }
    for (const item of items) {
      if (this.disposed || generation !== this.playerGeneration) { return false; }
      if (item.name !== this.title.trim() || this.triedSourceUrls.has(item.sourceUrl)) { continue; }
      const src = this.findSourceByUrl(item.sourceUrl);
      if (src === null || !src.enabled) { continue; }
      this.triedSourceUrls.add(item.sourceUrl);
      let detail: Detail;
      try { detail = await api.detail(item.vodId, src); } catch (e) { continue; }
      if (this.disposed || generation !== this.playerGeneration) { return false; }
      if (detail.episodes.length === 0) { continue; }
      this.episodes = detail.episodes;
      this.sourceUrl = item.sourceUrl;
      this.vodId = item.vodId;
      if (this.episodeIndex >= this.episodes.length) { this.episodeIndex = 0; }
      this.cover = detail.info.cover !== '' ? detail.info.cover : this.cover;
      this.usePlainUrl = true;
      this.alternateTried = false;
      this.sameUrlRetried = false;
      this.sourceSwitchTried = false;
      this.curMs = 0;
      this.durMs = 0;
      this.switching = false;
      this.gestureMessage = `已切换片源：${item.sourceName}`;
      if (this.hudTimer >= 0) { clearTimeout(this.hudTimer); }
      this.hudTimer = setTimeout(() => { this.gestureMessage = ''; }, 2500);
      this.setupPlayer();
      return true;
    }
    return false;
  }

  private findSourceByUrl(url: string): SourceConfig | null {
    for (const src of this.session.sources) {
      if (src.url === url) { return src; }
    }
    return null;
  }

  /** 自愈全部失败：给出结论和手动换源提示 */
  private finishHealFail(reason: string): void {
    this.switching = false;
    this.sourceSwitchTried = false;
    this.loadMessage = '';
    this.stopStartupTimer();
    this.showControls = true;
    this.errorMsg = `播放失败：${reason}。可返回后换个片源再试。`;
  }

  private stopStartupTimer(): void {
    if (this.startupTimer >= 0) { clearTimeout(this.startupTimer); this.startupTimer = -1; }
  }

  /** 缓冲时每秒采样一次缓冲时长的增量，换算成实时网速 */
  private startSpeedTimer(): void {
    if (this.speedTimer >= 0) { return; }
    this.lastCachedMs = this.cachedMs;
    this.lastCachedAt = Date.now();
    this.speedTimer = setInterval(() => { this.updateNetSpeed(); }, 1000);
  }

  private stopSpeedTimer(): void {
    if (this.speedTimer >= 0) { clearInterval(this.speedTimer); this.speedTimer = -1; }
    this.lastCachedMs = -1;
  }

  private updateNetSpeed(): void {
    const now = Date.now();
    if (this.cachedMs >= 0 && this.lastCachedMs >= 0 && now > this.lastCachedAt && this.activeBitrate > 0) {
      const dtSec = (now - this.lastCachedAt) / 1000;
      const deltaMs = this.cachedMs - this.lastCachedMs;
      if (deltaMs > 0) {
        // 缓冲时长每秒增长 deltaMs 秒的片源内容，乘上码率即每秒字节数
        const bytesPerSec = (deltaMs / 1000) * (this.activeBitrate / 8);
        this.netSpeed = formatNetSpeed(bytesPerSec);
      }
    }
    this.lastCachedMs = this.cachedMs;
    this.lastCachedAt = now;
  }

  private startStartupTimer(generation: number): void {
    this.stopStartupTimer();
    this.startupTimer = setTimeout(() => {
      this.startupTimer = -1;
      if (this.disposed || generation !== this.playerGeneration || this.firstFrameSeen) { return; }
      if (this.handlePlaybackFailure(5400104, generation)) { return; }
      const state = this.player !== null ? this.player.state : 'creating';
      this.switching = false;
      this.loadMessage = '';
      this.errorMsg = `起播等待超时（状态 ${state}）。点击重试。`;
      this.showControls = true;
    }, 15000);
  }

  private async diagnoseStream(url: string, generation: number, baseError: string): Promise<void> {
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.errorMsg = `${baseError}。播放地址不是 HTTP(S) 地址。`;
      return;
    }
    const client = http.createHttp();
    try {
      const response = await client.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'CloudScreen-Android', 'Range': 'bytes=0-4095' },
        connectTimeout: 5000, readTimeout: 8000, expectDataType: http.HttpDataType.STRING,
        maxLimit: 1024 * 1024, usingCache: false
      });
      if (this.disposed || generation !== this.playerGeneration) { return; }
      const text = typeof response.result === 'string' ? response.result as string : '';
      let detail = `地址返回 HTTP ${response.responseCode}`;
      if (response.responseCode >= 200 && response.responseCode < 300) {
        if (text.includes('#EXTM3U')) {
          detail += text.includes('#EXT-X-KEY') ? '，检测到加密 HLS 清单' : '，检测到 HLS 清单';
        } else if (text.toLowerCase().includes('<html') || text.toLowerCase().includes('<!doctype')) {
          detail += '，返回的是网页而非播放清单';
        } else { detail += '，未识别为 HLS 清单'; }
      }
      this.errorMsg = `${baseError}。${detail}。`;
    } catch (e) {
      if (!this.disposed && generation === this.playerGeneration) {
        this.errorMsg = `${baseError}。手机无法读取播放地址（${(e as BusinessError).code ?? '网络错误'}）。`;
      }
    } finally { client.destroy(); }
  }

  private togglePlay(): void {
    const p = this.player;
    if (p === null || this.switching) {
      return;
    }
    if (this.errorMsg !== '') { this.retryPlayback(); return; }
    if (this.playing) {
      p.pause().then(() => {
        this.playing = false;
        this.saveProgress(false);
      });
    } else {
      p.play().then(() => {
        this.playing = true;
        this.scheduleHide();
      });
    }
  }

  private async startBackgroundPlayback(): Promise<void> {
    if (!this.backgroundPlayback || !this.playing || this.isLive) { return; }
    try {
      if (this.backgroundSession === null) {
        const session = await avSession.createAVSession(getContext(this), 'ShiguangCinema', 'video');
        session.on('play', () => { this.player?.play().catch(() => {}); });
        session.on('pause', () => { this.player?.pause().catch(() => {}); });
        session.on('stop', () => { this.player?.pause().catch(() => {}); });
        this.backgroundSession = session;
        await session.activate();
      }
      await this.updateBackgroundSession(true);
      if (!this.backgroundTaskActive) {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: 'com.lshai.shiguangcinema', abilityName: 'EntryAbility' }],
          operationType: wantAgent.OperationType.START_ABILITY,
          requestCode: 1
        });
        await backgroundTaskManager.startBackgroundRunning(getContext(this),
          backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
        this.backgroundTaskActive = true;
      }
    } catch (e) {
      hilog.warn(0, 'ShiguangCinema', 'background playback start failed: %{public}s', (e as Error).message);
    }
  }

  private async updateBackgroundSession(isPlaying: boolean): Promise<void> {
    const session = this.backgroundSession;
    if (session === null) { return; }
    try {
      await session.setAVMetadata({ assetId: `${this.vodId}:${this.episodeIndex}`, title: this.title,
        artist: `第 ${this.episodeIndex + 1} 集`, duration: this.durMs });
      await session.setAVPlaybackState({ state: isPlaying ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
        avSession.PlaybackState.PLAYBACK_STATE_PAUSE, speed: 1, duration: this.durMs,
        position: { elapsedTime: this.curMs, updateTime: Date.now() } });
    } catch (e) {
      hilog.warn(0, 'ShiguangCinema', 'background session update failed: %{public}s', (e as Error).message);
    }
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.backgroundTaskActive) { return; }
    this.backgroundTaskActive = false;
    try { await backgroundTaskManager.stopBackgroundRunning(getContext(this)); }
    catch (e) { hilog.warn(0, 'ShiguangCinema', 'background task stop failed: %{public}s', (e as Error).message); }
  }

  private async stopBackgroundPlayback(): Promise<void> {
    await this.stopBackgroundTask();
    const session = this.backgroundSession;
    this.backgroundSession = null;
    if (session !== null) {
      try { await session.destroy(); } catch (e) { /* The system may already have closed this session. */ }
    }
  }

  private switchEpisode(delta: number): void {
    const next = this.episodeIndex + delta;
    if (next < 0 || next >= this.episodes.length || this.switching) {
      return;
    }
    this.saveProgress(true);
    this.episodeIndex = next;
    this.usePlainUrl = true;
    this.alternateTried = false;
    this.sameUrlRetried = false;
    this.sourceSwitchTried = false;
    this.triedSourceUrls = new Set([this.sourceUrl]);
    this.curMs = 0;
    this.durMs = 0;
    this.setupPlayer();
  }

  private selectEpisode(index: number): void {
    if (index === this.episodeIndex || this.switching) { this.showEpisodes = false; return; }
    this.saveProgress(true);
    this.episodeIndex = index;
    this.usePlainUrl = true;
    this.alternateTried = false;
    this.sameUrlRetried = false;
    this.sourceSwitchTried = false;
    this.triedSourceUrls = new Set([this.sourceUrl]);
    this.curMs = 0;
    this.durMs = 0;
    this.resumeMs = 0;
    this.showEpisodes = false;
    this.setupPlayer();
  }

  private retryPlayback(): void {
    if (this.switching) { return; }
    this.usePlainUrl = !this.usePlainUrl;
    this.alternateTried = false;
    this.sameUrlRetried = false;
    this.sourceSwitchTried = false;
    this.triedSourceUrls = new Set([this.sourceUrl]);
    this.errorMsg = '';
    this.setupPlayer();
  }

  private applyScale(): void {
    this.updateVideoFrame();
    if (this.player === null || !['prepared', 'playing', 'paused', 'completed'].includes(this.player.state)) { return; }
    try {
      this.player.videoScaleType = this.cropVideo ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP :
        media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
    } catch (e) { /* Some streams or device implementations cannot change scaling. */ }
  }

  private saveSettings(): void {
    if (this.prefs === null) { return; }
    const settings: PlaybackSettings = { speedIndex: this.speedIndex, autoNext: this.autoNext, cropVideo: this.cropVideo,
      seekStepSeconds: this.seekStepSeconds, rememberProgress: this.rememberProgress,
      resumeThresholdSeconds: this.resumeThresholdSeconds, backgroundPlayback: this.backgroundPlayback };
    this.prefs.setPlaybackSettings(settings).catch(() => { this.errorMsg = '播放设置保存失败'; });
  }

  private onSliderChange(value: number, mode: SliderChangeMode): void {
    if (mode === SliderChangeMode.Begin) {
      this.userDragging = true;
      return;
    }
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      this.userDragging = false;
      const p = this.player;
      if (p !== null) {
        p.seek(value, media.SeekMode.SEEK_PREV_SYNC);
        this.curMs = value;
      }
      this.scheduleHide();
    }
  }

  private saveTick: number = 0;

  private startSaveTimer(): void {
    this.stopSaveTimer();
    this.saveTick = 0;
    this.saveTimerId = setInterval(() => {
      this.saveTick++;
      if (this.saveTick % 6 === 0) { this.saveProgress(false); }
      if (this.backgroundSession !== null) { this.updateBackgroundSession(this.playing); }
    }, 5000);
  }

  private stopSaveTimer(): void {
    if (this.saveTimerId >= 0) {
      clearInterval(this.saveTimerId);
      this.saveTimerId = -1;
    }
  }

  private scheduleHide(): void {
    if (this.locked) { return; }
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
    }
    this.showControls = true;
    this.hideTimerId = setTimeout(() => {
      this.showControls = false;
    }, 3000);
  }

  private saveProgress(final: boolean): void {
    if (this.isLive || !this.rememberProgress) {
      return;
    }
    const p = this.player;
    if (this.prefs === null || p === null || this.durMs <= 0) {
      return;
    }
    const entry: WatchEntry = entryFromStatus(
      this.session.serverUrl, this.sourceUrl, this.vodId,
      this.title, this.cover,
      this.episodeIndex, this.episodes.length,
      final ? p.currentTime : this.curMs, this.durMs
    );
    this.prefs.saveWatch(entry).catch(() => {});
  }


  private notify(message: string): void {
    promptAction.showToast({ message: message, duration: 1600 });
  }

  private canControl(): boolean {
    return this.player !== null && ['prepared', 'playing', 'paused', 'completed'].includes(this.player.state);
  }

  private seekTo(position: number): void {
    if (!this.canControl() || this.isLive || this.durMs <= 0) { return; }
    const target = Math.max(0, Math.min(position, Math.max(0, this.durMs - 300)));
    try {
      (this.player as media.AVPlayer).seek(target, media.SeekMode.SEEK_PREV_SYNC);
      this.curMs = target;
    } catch (e) { this.notify('当前视频暂时无法定位'); }
  }

  private skipIntro(): void {
    if (this.isLive) { return; }
    if (!this.canControl() || this.durMs <= 0) { return; }
    if (this.introEndMs >= this.durMs) { this.notify('片头位置超过本集时长，请在更多中调整'); return; }
    if (this.curMs >= this.introEndMs) { this.notify('已超过片头位置，可在更多里调整片头'); return; }
    this.introApplied = true;
    this.seekTo(this.introEndMs);
    this.notify(`已跳过片头 · ${this.fmt(this.introEndMs)}`);
  }

  private skipOutro(): void {
    if (this.isLive || !this.canControl()) { return; }
    if (this.episodeIndex < this.episodes.length - 1) { this.switchEpisode(1); }
    else { this.seekTo(this.durMs - 300); this.notify('已跳过片尾，当前为最后一集'); }
  }

  private applySkipMarks(time: number): void {
    if (this.isLive || !this.playing || this.switching || this.userDragging || this.durMs <= 0 || !this.marksLoaded) { return; }
    if (!this.introApplied) {
      this.introApplied = true;
      if (this.autoIntro && this.introEndMs > 0 && this.introEndMs < this.durMs &&
        Math.max(time, this.resumeMs) < this.introEndMs - 1500) { this.seekTo(this.introEndMs); return; }
    }
    if (this.autoOutro && this.autoNext && this.outroStartMs > 0 && this.outroStartMs < this.durMs &&
      this.outroMarkedEpisode !== this.episodeIndex && time >= this.outroStartMs &&
      this.episodeIndex < this.episodes.length - 1) { this.switchEpisode(1); }
  }

  private saveSkipMarks(): void {
    if (this.prefs === null) { return; }
    const marks: SkipMarks = { introEndMs: this.introEndMs, outroStartMs: this.outroStartMs,
      autoIntro: this.autoIntro, autoOutro: this.autoOutro };
    this.prefs.setSkipMarks(this.title, marks).catch(() => { this.notify('片头片尾设置保存失败'); });
  }

  private toggleFullscreen(): void {
    this.pureFullscreen = !this.pureFullscreen;
    this.cropVideo = this.pureFullscreen;
    this.applyScale();
    this.showControls = !this.pureFullscreen;
  }

  private setSpeed(index: number): void {
    if (this.isLive || !this.canControl()) { this.notify('视频准备完成后可调整倍速'); return; }
    try {
      (this.player as media.AVPlayer).setSpeed(this.speeds[index]);
      this.speedIndex = index;
      this.saveSettings();
      this.activeMenu = '';
      this.scheduleHide();
    } catch (e) { this.notify('当前视频不支持此倍速'); }
  }

  private qualityLabel(): string {
    if (this.videoWidth <= 16) { return '自动'; }
    const longEdge = Math.max(this.videoWidth, this.videoHeight);
    const label = longEdge >= 3800 ? '4K' : longEdge >= 1900 ? '1080P' : longEdge >= 1250 ? '720P' : `${this.videoHeight}P`;
    return `${this.selectedBitrate === 0 ? '自动·' : ''}${label}`;
  }

  private async refreshTracks(player: media.AVPlayer, generation: number): Promise<void> {
    try {
      const descriptions = await player.getTrackDescription();
      if (this.disposed || generation !== this.playerGeneration) { return; }
      const tracks: PlayerTrack[] = [];
      let bitrateTotal = 0;
      let bitrateSeen = false;
      for (const description of descriptions) {
        const index = description['track_index']; const type = description['track_type'];
        if (typeof index !== 'number' || typeof type !== 'number' || (type !== 0 && type !== 2)) { continue; }
        const language = description['language']; const name = description['track_name'];
        const label = typeof name === 'string' ? name : typeof language === 'string' ? language : `轨道 ${index + 1}`;
        tracks.push({ index: index, type: type, label: `${type === 0 ? '音轨' : '字幕'} · ${label}` });
        const bit = description['bitrate'];
        if (typeof bit === 'number' && bit > 0) { bitrateTotal += bit; bitrateSeen = true; }
      }
      this.mediaTracks = tracks;
      // 非自适应流（mp4 直链）从这里拿码率，用于估算网速；HLS 用 bitrateDone 事件
      if (bitrateSeen) { this.activeBitrate = bitrateTotal; }
    } catch (e) { this.mediaTracks = []; }
  }

  private async selectTrack(track: PlayerTrack): Promise<void> {
    if (!this.canControl()) { return; }
    try {
      await (this.player as media.AVPlayer).selectTrack(track.index);
      this.notify(`已切换${track.label}`); this.activeMenu = '';
    } catch (e) { this.notify('当前流或设备不支持切换该轨道'); }
  }

  private async disableSubtitles(): Promise<void> {
    if (!this.canControl()) { return; }
    const player = this.player as media.AVPlayer;
    try {
      const selected = await player.getSelectedTracks();
      for (const track of this.mediaTracks) {
        if (track.type === 2 && selected.includes(track.index)) { await player.deselectTrack(track.index); }
      }
      this.subtitleText = '';
      if (this.subtitleTimer >= 0) { clearTimeout(this.subtitleTimer); }
      this.notify('已关闭可选字幕');
    } catch (e) { this.notify('无法关闭该流的字幕，画面内字幕无法移除'); }
  }

  private reloadCurrent(fromStart: boolean = false): void {
    this.resumeMs = fromStart ? 0 : this.curMs;
    this.resumeRequestedManually = !fromStart;
    this.activeMenu = '';
    this.setupPlayer();
  }

  private setSleep(minutes: number): void {
    if (this.sleepTimer >= 0) { clearTimeout(this.sleepTimer); this.sleepTimer = -1; }
    this.sleepMinutes = minutes;
    if (minutes > 0) {
      this.sleepTimer = setTimeout(() => {
        this.sleepTimer = -1; this.sleepMinutes = 0;
        if (!this.disposed && this.canControl()) {
          (this.player as media.AVPlayer).pause().then(() => {
            this.playing = false; this.saveProgress(true); this.showControls = true; this.notify('定时已到，已暂停播放');
          }).catch(() => {});
        }
      }, minutes * 60000);
    }
    this.activeMenu = ''; this.notify(minutes > 0 ? `${minutes} 分钟后暂停播放` : '已关闭定时');
  }

  private menuTitle(): string {
    if (this.activeMenu === 'speed') { return '播放速度'; }
    if (this.activeMenu === 'quality') { return `清晰度 · ${this.qualityLabel()}`; }
    if (this.activeMenu === 'skip') { return '片头 / 片尾'; }
    if (this.activeMenu === 'tracks') { return '音轨 / 字幕'; }
    if (this.activeMenu === 'sleep') { return '定时暂停'; }
    return '更多操作';
  }

  private menuActions(): PlayerMenuAction[] {
    const items: PlayerMenuAction[] = [];
    if (this.activeMenu === 'speed') {
      for (let i = 0; i < this.speedLabels.length; i++) {
        const index = i;
        items.push({ label: `${this.speedIndex === index ? '✓ ' : ''}${this.speedLabels[index]}`,
          action: () => { this.setSpeed(index); } });
      }
    } else if (this.activeMenu === 'quality') {
      items.push({ label: '自动选择', action: () => { this.selectedBitrate = 0; this.reloadCurrent(); } });
      for (const bitrate of this.availableBitrates) {
        items.push({ label: `${this.selectedBitrate === bitrate ? '✓ ' : ''}${(bitrate / 1000000).toFixed(2)} Mbps`, action: () => {
          if (!this.canControl()) { return; }
          try { (this.player as media.AVPlayer).setBitrate(bitrate); this.selectedBitrate = bitrate; this.activeMenu = ''; }
          catch (e) { this.notify('无法切换当前流的码率'); }
        } });
      }
      if (this.availableBitrates.length <= 1) {
        items.push({ label: '当前片源仅提供原始清晰度', action: () => { this.notify('可返回搜索选择其他片源的画质'); } });
      }
    } else if (this.activeMenu === 'skip') {
      items.push({ label: `跳到片头结束 ${this.fmt(this.introEndMs)}`, action: () => { this.skipIntro(); this.activeMenu = ''; } });
      items.push({ label: `将当前位置 ${this.fmt(this.curMs)} 记为片头结束`, action: () => {
        if (!this.canControl() || this.curMs <= 0) { return; }
        this.introEndMs = this.curMs; this.introApplied = true; this.saveSkipMarks(); this.notify('已保存本剧片头位置');
      } });
      items.push({ label: '将当前位置记为片尾开始', action: () => {
        if (!this.canControl() || this.curMs <= 0) { return; }
        this.outroStartMs = this.curMs; this.outroMarkedEpisode = this.episodeIndex; this.saveSkipMarks();
        this.notify('已保存本剧片尾位置');
      } });
      items.push({ label: `自动跳片头：${this.autoIntro ? '开' : '关'}`, action: () => { this.autoIntro = !this.autoIntro; this.saveSkipMarks(); } });
      items.push({ label: `自动跳片尾：${this.autoOutro ? '开' : '关'}`, action: () => { this.autoOutro = !this.autoOutro; this.saveSkipMarks(); } });
      for (const seconds of [30, 60, 90, 120, 180]) {
        items.push({ label: `片头时长 ${seconds} 秒`, action: () => { this.introEndMs = seconds * 1000; this.saveSkipMarks(); } });
      }
      items.push({ label: '清除本剧标记并关闭自动跳过', action: () => {
        this.introEndMs = 90000; this.outroStartMs = 0; this.autoIntro = false; this.autoOutro = false;
        this.saveSkipMarks(); this.notify('已清除');
      } });
    } else if (this.activeMenu === 'tracks') {
      for (const track of this.mediaTracks) { items.push({ label: track.label, action: () => { this.selectTrack(track); } }); }
      items.push({ label: '关闭可选字幕', action: () => { this.disableSubtitles(); } });
      if (this.mediaTracks.length === 0) { items.push({ label: '当前流未提供可切换轨道', action: () => {} }); }
    } else if (this.activeMenu === 'sleep') {
      for (const minutes of [0, 15, 30, 60, 90]) {
        items.push({ label: minutes === 0 ? '关闭定时' : `${minutes} 分钟后暂停`, action: () => { this.setSleep(minutes); } });
      }
    } else {
      items.push({ label: '重新加载这一集', action: () => { this.reloadCurrent(); } });
      items.push({ label: '从头重播', action: () => { this.reloadCurrent(true); } });
      items.push({ label: '片头 / 片尾设置', action: () => { this.activeMenu = 'skip'; } });
      items.push({ label: `自动连播：${this.autoNext ? '开' : '关'}`, action: () => { this.autoNext = !this.autoNext; this.saveSettings(); } });
      items.push({ label: `显示比例：${this.cropVideo ? '裁切铺满' : '保持原比例'}`, action: () => {
        this.cropVideo = !this.cropVideo; this.pureFullscreen = false; this.applyScale(); this.saveSettings();
      } });
      items.push({ label: '音轨 / 字幕', action: () => { this.activeMenu = 'tracks'; } });
      items.push({ label: this.sleepMinutes > 0 ? `定时暂停：${this.sleepMinutes} 分钟` : '定时暂停', action: () => { this.activeMenu = 'sleep'; } });
      items.push({ label: '锁定操作', action: () => { this.locked = true; this.activeMenu = ''; this.showControls = false; } });
      items.push({ label: '退出播放', action: () => { router.back(); } });
    }
    return items;
  }

  private beginGesture(event: GestureEvent): void {
    if (this.locked) { return; }
    this.gestureKind = '';
    this.gestureStartX = event.fingerList.length > 0 ? event.fingerList[0].localX - event.offsetX : this.viewportWidth / 2;
    this.gestureStartTime = this.curMs;
    this.lastGestureUpdate = 0;
    if (this.hideTimerId >= 0) { clearTimeout(this.hideTimerId); }
  }

  private updateGesture(event: GestureEvent): void {
    if (this.locked) { return; }
    if (this.gestureKind === '') {
      if (Math.abs(event.offsetX) > Math.abs(event.offsetY)) { this.gestureKind = 'seek'; }
      else {
        this.gestureKind = this.gestureStartX < this.viewportWidth / 2 ? 'brightness' : 'volume';
        this.gestureStartLevel = this.gestureKind === 'brightness' ? this.brightnessLevel : this.volumeLevel;
      }
    }
    if (this.gestureKind === 'seek') {
      if (this.isLive) { this.gestureMessage = '直播不支持快进 / 后退'; return; }
      this.gestureMessage = event.offsetX >= 0 ? `快进 ${this.seekStepSeconds} 秒` : `后退 ${this.seekStepSeconds} 秒`;
      return;
    }
    if (Date.now() - this.lastGestureUpdate < 50) { return; }
    this.lastGestureUpdate = Date.now();
    const value = Math.max(0, Math.min(1, this.gestureStartLevel - event.offsetY / Math.max(160, this.viewportHeight * 0.65)));
    if (this.gestureKind === 'brightness') {
      this.brightnessLevel = Math.max(0.02, value);
      if (this.playbackWindow !== null) { this.playbackWindow.setWindowBrightness(this.brightnessLevel).catch(() => {}); }
      this.gestureMessage = `亮度 ${Math.round(this.brightnessLevel * 100)}%`;
    } else {
      this.volumeLevel = value;
      if (this.canControl()) { try { (this.player as media.AVPlayer).setVolume(value); } catch (e) {} }
      this.gestureMessage = `视频音量 ${Math.round(value * 100)}%`;
    }
  }

  private endGesture(event: GestureEvent): void {
    if (this.locked) { return; }
    if (this.gestureKind === 'seek' && !this.isLive) {
      this.seekTo(this.gestureStartTime + (event.offsetX >= 0 ? this.seekStepSeconds * 1000 : -this.seekStepSeconds * 1000));
    }
    this.gestureKind = '';
    if (this.hudTimer >= 0) { clearTimeout(this.hudTimer); }
    this.hudTimer = setTimeout(() => { this.gestureMessage = ''; }, 900);
    this.scheduleHide();
  }

  private cancelGesture(): void {
    this.gestureKind = '';
    this.gestureMessage = '';
    this.scheduleHide();
  }

  @Builder
  toolbarButton(label: string, enabled: boolean, action: () => void) {
    Text(label).fontSize(12).fontColor('#FFFFFF').height(42).layoutWeight(1).textAlign(TextAlign.Center)
      .opacity(enabled ? 1 : 0.35).maxLines(1)
      .onClick(() => { if (enabled) { action(); } })
  }

  private fmt(ms: number): string {
    const totalSec = Math.floor(ms / 1000);
    const h = Math.floor(totalSec / 3600);
    const m = Math.floor((totalSec % 3600) / 60);
    const sec = totalSec % 60;
    const mm = m < 10 ? `0${m}` : `${m}`;
    const ss = sec < 10 ? `0${sec}` : `${sec}`;
    return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
  }

  build() {
    Stack() {
      // 视频层
      XComponent({ id: 'video', type: 'surface', controller: this.xcController })
        .onLoad(() => {
          this.onSurfaceReady();
        })
        .width(this.frameWidth > 0 ? this.frameWidth : '100%')
        .height(this.frameHeight > 0 ? this.frameHeight : '100%')

      // 错误提示
      if (this.subtitleText !== '') {
        Column() {
          Blank()
          Text(this.subtitleText).fontSize(18).fontColor('#FFFFFF').textAlign(TextAlign.Center)
            .padding(6).backgroundColor('#66000000').borderRadius(4).maxLines(3)
            .margin({ bottom: this.showControls && !this.locked ? 100 : 24 })
        }.width('90%').height('100%').hitTestBehavior(HitTestMode.None)
      }
      if (this.loadMessage !== '' && this.errorMsg === '') {
        Column({ space: 12 }) {
          LoadingProgress().width(36).height(36).color('#FFFFFF')
          Text(this.loadMessage).fontSize(14).fontColor('#FFFFFF')
        }.padding(18).backgroundColor('#CC16161C').borderRadius(10)
      }
      if (this.loadMessage === '' && this.errorMsg === '') {
        if (this.buffering) {
          // 卡顿 / 缓冲：居中提示 + 实时网速
          Column({ space: 8 }) {
            LoadingProgress().width(30).height(30).color('#FFFFFF')
            Text('缓冲中').fontSize(14).fontColor('#FFFFFF')
            if (this.netSpeed !== '') {
              Text(this.netSpeed).fontSize(12).fontColor('#B9CBC5')
            }
          }.padding(16).backgroundColor('#CC16161C').borderRadius(10)
            .hitTestBehavior(HitTestMode.None)
        } else if (this.isPaused) {
          // 用户暂停：居中提示，点一下继续
          Column({ space: 6 }) {
            Text('已暂停').fontSize(14).fontColor('#FFFFFF')
            if (this.netSpeed !== '') {
              Text(this.netSpeed).fontSize(12).fontColor('#B9CBC5')
            }
          }.padding(16).backgroundColor('#CC16161C').borderRadius(10)
            .onClick(() => { this.togglePlay(); })
        }
      }
      if (this.errorMsg !== '') {
        Text(this.errorMsg).fontSize(14).fontColor('#FF6B6B')
          .padding(12).backgroundColor('#CC16161C').borderRadius(8)
      }

      // 点击区：唤起控制栏
      Column()
        .width('100%').height('100%')
        .onClick((event: ClickEvent) => {
          if (this.locked) { return; }
          const centerX = this.viewportWidth / 2;
          const centerY = this.viewportHeight / 2;
          // 用组件内坐标（x/y）而不是窗口坐标（displayX/displayY），与 viewport 尺寸同源
          if (Math.abs(event.x - centerX) < this.viewportWidth * 0.22 &&
            Math.abs(event.y - centerY) < this.viewportHeight * 0.28) {
            this.togglePlay();
          } else { this.scheduleHide(); }
        })
        .gesture(PanGesture({ fingers: 1, direction: PanDirection.All, distance: 12 })
          .onActionStart((event: GestureEvent) => { this.beginGesture(event); })
          .onActionUpdate((event: GestureEvent) => { this.updateGesture(event); })
          .onActionEnd((event: GestureEvent) => { this.endGesture(event); })
          .onActionCancel(() => { this.cancelGesture(); }))

      if (this.gestureMessage !== '') {
        Text(this.gestureMessage).fontSize(17).fontColor('#FFFFFF')
          .padding(14).borderRadius(10).backgroundColor('#CC16161C')
          .hitTestBehavior(HitTestMode.None)
      }
      if (this.locked || this.showControls) {
        Row() {
          Text(this.locked ? '解锁' : '锁屏').fontSize(14).fontColor('#FFFFFF').padding(12).borderRadius(24)
            .backgroundColor('#AA000000').onClick(() => {
              this.locked = !this.locked;
              this.showControls = !this.locked;
              if (!this.locked) { this.scheduleHide(); }
            })
        }.width('100%').padding({ left: 12 }).hitTestBehavior(HitTestMode.Transparent)
      }
      if (!this.playing && this.loadMessage === '' && this.errorMsg === '' && !this.buffering &&
        !this.isPaused && !this.locked && this.activeMenu === '' && !this.showEpisodes) {
        Text('▶').fontSize(34).fontColor('#FFFFFF').width(70).height(70).textAlign(TextAlign.Center)
          .borderRadius(35).backgroundColor('#66000000').onClick(() => { this.togglePlay(); })
      }
      if (this.showControls && !this.locked) {
        Column() {
          Row({ space: 10 }) {
            Text('<').fontSize(22).fontColor('#FFFFFF')
              .padding(10)
              .onClick(() => { router.back(); })
            Text(this.isLive
              ? `${this.title} · 直播`
              : `${this.title} · 第${this.episodeIndex + 1}/${this.episodes.length}集`)
              .fontSize(14).fontColor('#FFFFFF')
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.isLive) {
              Text('LIVE').fontSize(10).fontColor('#FF5A5A')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .borderRadius(4).border({ width: 1, color: '#FF5A5A' })
            }
            Text('设置').fontSize(13).fontColor('#FFFFFF').padding(8)
              .onClick(() => { this.activeMenu = 'more'; })
          }.width('100%').padding({ left: 6, top: 6, right: 12 })

          Blank()

          if (!this.isLive) {
            Row({ space: 8 }) {
              Text(this.fmt(this.curMs)).fontSize(11).fontColor('#FFFFFF')
              Slider({ value: this.curMs, min: 0, max: this.durMs > 0 ? this.durMs : 1 })
                .layoutWeight(1).selectedColor('#FFFFFF').trackColor('#777777')
                .onChange((value: number, mode: SliderChangeMode) => { this.onSliderChange(value, mode); })
              Text(this.fmt(this.durMs)).fontSize(11).fontColor('#FFFFFF')
            }.width('100%').padding({ left: 16, right: 16, bottom: 4 })
          }
          Row() {
            this.toolbarButton(this.errorMsg !== '' ? '重试' : (this.playing ? 'Ⅱ' : '▶'), true, () => { this.togglePlay(); })
            if (!this.isLive) {
              this.toolbarButton('片头', this.durMs > 0, () => { this.skipIntro(); })
              this.toolbarButton('片尾', this.durMs > 0, () => { this.skipOutro(); })
            }
            this.toolbarButton(this.isLive ? '上台' : '上集', this.episodeIndex > 0, () => { this.switchEpisode(-1); })
            this.toolbarButton(this.isLive ? '下台' : '下集', this.episodeIndex < this.episodes.length - 1, () => { this.switchEpisode(1); })
            if (!this.isLive) {
              this.toolbarButton(`倍速 ${this.speedLabels[this.speedIndex]}`, true, () => { this.activeMenu = 'speed'; })
            }
            this.toolbarButton('选集', true, () => { this.showEpisodes = true; })
            this.toolbarButton(this.qualityLabel(), true, () => { this.activeMenu = 'quality'; })
            this.toolbarButton(this.pureFullscreen ? '还原' : '全屏', true, () => { this.toggleFullscreen(); })
            this.toolbarButton('更多', true, () => { this.activeMenu = 'more'; })
          }.width('100%').padding({ left: 8, right: 8, bottom: 8 })

        }
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [['#88000000', 0], ['#00000000', 0.3], ['#00000000', 0.7], ['#88000000', 1]]
        })
        .hitTestBehavior(HitTestMode.Transparent)
      }
      if (this.activeMenu !== '') {
        Column({ space: 8 }) {
          Row() {
            Text(this.menuTitle()).fontSize(18).fontColor('#FFFFFF').layoutWeight(1)
            Text('关闭').fontSize(14).fontColor('#FFFFFF').padding(8)
              .onClick(() => { this.activeMenu = ''; this.scheduleHide(); })
          }.width('100%')
          Scroll() {
            Column({ space: 6 }) {
              ForEach(this.menuActions(), (item: PlayerMenuAction, index: number) => {
                Text(item.label).fontSize(14).fontColor('#FFFFFF').width('100%').padding(12)
                  .borderRadius(8).backgroundColor('#33333A')
                  .onClick(() => { item.action(); })
              }, (item: PlayerMenuAction, index: number) => `${index}:${item.label}`)
            }.width('100%')
          }.layoutWeight(1).width('100%')
        }.width('70%').height('80%').padding(16).borderRadius(16).backgroundColor('#EE202025')
      }
      if (this.showEpisodes) {
        Column({ space: 10 }) {
          Row() {
            Text(this.isLive ? '选择频道' : '选择剧集').fontSize(18).fontColor('#FFFFFF').layoutWeight(1)
            Text('关闭').fontSize(14).fontColor('#FFFFFF').padding(8)
              .onClick(() => { this.showEpisodes = false; this.scheduleHide(); })
          }.width('100%')
          List({ space: 5 }) {
            ForEach(this.episodes, (_url: string, index: number) => {
              ListItem() {
                Text(this.isLive ? `频道 ${index + 1}` : `第 ${index + 1} 集`)
                  .width('100%').padding(12).borderRadius(8)
                  .fontColor(index === this.episodeIndex ? '#FFFFFF' : '#DDDDDD')
                  .backgroundColor(index === this.episodeIndex ? '#0F766E' : '#33333A')
                  .onClick(() => { this.selectEpisode(index); })
              }
            }, (_url: string, index: number) => index.toString())
          }.layoutWeight(1).width('100%')
        }.width('85%').height('75%').padding(16).borderRadius(16).backgroundColor('#EE202025')
      }

    }
    .width('100%').height('100%')
    .backgroundColor('#000000')
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.viewportWidth = parseFloat(newArea.width.toString());
      this.viewportHeight = parseFloat(newArea.height.toString());
      this.updateVideoFrame();
    })
  }
}
