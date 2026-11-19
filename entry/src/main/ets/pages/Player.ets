import { matchEpisodeIndex } from '../common/EpisodeMatch';
/**
 * 播放页 —— AVPlayer + XComponent：
 *   · m3u8/HLS 播放
 *   · 续播（进入即 seek 到上次进度）
 *   · 上一集/下一集、自动连播（播完自动下一集）
 *   · 进度条拖动、暂停/播放
 *   · 每 30 秒与退出时写观看历史（Prefs）
 */

import { media } from '@kit.MediaKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { http } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { router, window, promptAction } from '@kit.ArkUI';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { avSession } from '@kit.AVSessionKit';
import { wantAgent } from '@kit.AbilityKit';
import { fitVideoFrame } from './VideoLayout';
import { EpisodeListSource } from './EpisodeListSource';
import { loadPosterBitmap } from '../components/PosterImage';
import { Prefs, PlaybackSettings, SkipMarks, WatchEntry, entryFromStatus } from '../store/Prefs';
import { Session } from '../store/Session';
import { ChildrenQuota } from '../store/ChildrenQuota';
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
  /** v1.5.2：片尾改记「距结束还有多久」，同一部剧时长不同的剧集也能对准 */
  private outroRemainingMs: number = 0;
  private outroReferenceMs: number = 0;
  /** 当前是否受儿童额度管理（播放时计时，用完暂停） */
  private childManaged: boolean = false;
  private quotaTimer: number = -1;
  private quotaLastAt: number = 0;
  private quotaPausePending: boolean = false;
  private quota: ChildrenQuota | null = null;
  private quotaReady: boolean = false;
  private quotaInitFailed: boolean = false;
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
  private temporarySpeed: boolean = false;
  private suppressClickUntil: number = 0;
  private hudTimer: number = -1;
  private sleepTimer: number = -1;
  private introSeekPending: boolean = false;
  private marksLoaded: boolean = false;
  private outroMarkedEpisode: number = -1;

  private session: Session = Session.getInstance();
  private player: media.AVPlayer | null = null;
  private xcController: XComponentController = new XComponentController();
  private episodes: string[] = [];
  private episodeLabels: string[] = [];
  private saveNextOnStart: boolean = false;
  /** 选集面板的数据源：上千集不能一次性建行 */
  private episodeSource: EpisodeListSource = new EpisodeListSource();
  private sourceUrl: string = '';
  private vodId: string = '';
  private cover: string = '';
  private resumeMs: number = 0;
  // Keep the position across failed candidates until a replacement confirms its seek.
  private recoveryPositionMs: number = 0;
  private recoverySeekPending: boolean = false;
  private lookingForSource: boolean = false;
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
  private effectiveSpeed: number = 1;
  private backgroundUpdate: number = 0;
  private backgroundStarting: boolean = false;
  private backgroundCanGoPrevious: boolean = false;
  private backgroundCanGoNext: boolean = false;
  private backgroundArtworkKey: string = '';
  private backgroundMetadataKey: string = '';
  private backgroundControlsKey: string = '';
  private backgroundArtwork: image.PixelMap | null = null;
  private speedRates: number[] = [0.75, 1, 1.25, 1.5, 1.75, 2];
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
    this.resumeRequestedManually = params['forceResume'] === '1';
    if (isNaN(this.episodeIndex)) {
      this.episodeIndex = 0;
    }
    if (this.episodeIndex < 0 || this.episodeIndex >= this.episodes.length) {
      this.episodeIndex = 0;
    }
    try {
      const labels = JSON.parse(params['episodeLabels'] ?? '[]') as Object[];
      if (Array.isArray(labels) && labels.length === this.episodes.length) {
        this.episodeLabels = labels.map((label: Object) => typeof label === 'string' ? label as string : '');
      }
    } catch (e) { /* Older playback routes may not contain episode labels. */ }
    this.episodeSource.setItems(this.episodes);
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
      if (this.disposed) { return; }
      this.prefs = p;
      ChildrenQuota.get(p).then((quota: ChildrenQuota) => {
        if (this.disposed) { return; }
        this.quota = quota;
        this.childManaged = !this.isLive && quota.isManaged(this.title);
        this.startQuotaTimer();
        this.quotaReady = true;
        this.onSettingsReady();
      }).catch(() => {
        if (!this.disposed) { this.quotaInitFailed = true; this.onSettingsReady(); }
      });
      p.getSkipMarks(this.title).then((marks: SkipMarks) => {
        if (this.disposed) { return; }
        this.introEndMs = marks.introEndMs; this.outroStartMs = marks.outroStartMs;
        this.autoIntro = marks.autoIntro; this.autoOutro = marks.autoOutro;
        this.outroRemainingMs = marks.outroRemainingMs; this.outroReferenceMs = marks.outroReferenceMs;
      }).catch(() => {}).finally(() => { this.marksLoaded = true; this.onSettingsReady(); });
      p.getPlaybackSettings().then((settings: PlaybackSettings) => {
        if (this.disposed) { return; }
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
      }).catch(() => {}).finally(() => { this.settingsReady = true; this.onSettingsReady(); });
    }).catch(() => {
      if (!this.disposed) { this.quotaInitFailed = true; this.settingsReady = true; this.onSettingsReady(); }
    });
  }

  private onSettingsReady(): void {
    if (this.disposed) { return; }
    if (this.quotaInitFailed) { this.loadMessage = ''; this.errorMsg = '儿童时间设置读取失败，请返回后重试'; return; }
    if (!this.settingsReady || !this.quotaReady || !this.marksLoaded) { return; }
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
    this.endTemporarySpeed();
    this.disposed = true;
    this.playerGeneration++;
    this.saveProgress(true);
    this.stopSaveTimer();
    this.stopStartupTimer();
    this.stopSpeedTimer();
    this.stopQuotaTimer();
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
      if (this.settingsReady && this.quotaReady && this.marksLoaded && !this.quotaInitFailed) { await this.setupPlayer(); }
      else if (!this.quotaInitFailed) { this.loadMessage = '正在读取播放设置…'; }
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
    this.endTemporarySpeed();
    const url = this.episodes[this.episodeIndex];
    this.switching = true;
    this.playing = false;
    this.firstFrameSeen = false;
    this.effectiveSpeed = 1;
    this.recoverySeekPending = false;
    this.introSeekPending = false;
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
      this.accountQuota();
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
        if (!this.canStartForQuota()) {
          this.switching = false; this.loadMessage = ''; this.stopStartupTimer(); this.showControls = true;
          return;
        }
        if (this.recoveryPositionMs > 0) {
          if (this.durMs > 0 && this.recoveryPositionMs >= this.durMs) {
            this.rejectRecoverySource();
            return;
          }
          this.recoverySeekPending = true;
          this.loadMessage = '正在恢复播放进度…';
          try {
            p.seek(this.recoveryPositionMs, media.SeekMode.SEEK_CLOSEST);
          } catch (e) {
            this.rejectRecoverySource();
          }
          return;
        }
        if (this.shouldSkipIntroAtStartup()) {
          this.introSeekPending = true;
          this.loadMessage = '正在跳过片头…';
          try {
            p.seek(this.introEndMs, media.SeekMode.SEEK_CLOSEST);
            return;
          } catch (e) { this.introSeekPending = false; }
        }
        this.playPreparedVideo(p, generation);
      } else if (state === 'playing') {
        this.playing = true;
        if (this.childManaged && this.quota !== null && this.quota.isExhausted()) {
          this.switching = false; this.stopStartupTimer(); this.pauseForQuota(); return;
        }
        this.isPaused = false;
        this.buffering = false;
        this.stopSpeedTimer();
        this.netSpeed = '';
        this.switching = false;
        if (!this.isLive && this.resumeMs > 0) {
          const resume = this.resumeMs;
          this.resumeMs = 0;
          if (this.resumeRequestedManually || (this.rememberProgress && resume >= this.resumeThresholdSeconds * 1000)) {
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
        this.endTemporarySpeed();
        if (this.quota !== null) { this.quota.flush(); }
        this.playing = false;
        this.isPaused = true;
        this.updateBackgroundSession(false);
        this.stopBackgroundTask();
        this.stopSaveTimer();
        this.saveProgress(false);
        if (!this.locked) { this.showControls = true; }
      } else if (state === 'completed') {
        if (this.durMs > 0) { this.curMs = this.durMs; this.saveProgress(false); }
        this.playing = false;
        this.updateBackgroundSession(false);
        this.stopBackgroundTask();
        if (!this.isLive && this.autoNext && this.episodeIndex < this.episodes.length - 1) {
          this.switchEpisode(1, true);
        }
      }
    });
    p.on('seekDone', (position: number) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      if (this.introSeekPending) {
        this.introSeekPending = false;
        if (Number.isFinite(position) && position > 0 && Math.abs(position - this.introEndMs) <= 1500) {
          this.curMs = position;
          this.resumeMs = 0;
          this.resumeRequestedManually = false;
        }
        this.playPreparedVideo(p, generation);
        return;
      }
      if (!this.recoverySeekPending) {
        if (Number.isFinite(position) && position >= 0) {
          this.curMs = position;
          this.updateBackgroundSession(this.playing);
        }
        return;
      }
      if (!Number.isFinite(position) || Math.abs(position - this.recoveryPositionMs) > 3000) {
        this.rejectRecoverySource();
        return;
      }
      this.recoverySeekPending = false;
      this.recoveryPositionMs = 0;
      this.resumeMs = 0;
      this.resumeRequestedManually = false;
      this.curMs = position;
      this.playPreparedVideo(p, generation);
    });
    p.on('startRenderFrame', () => {
      if (this.disposed || generation !== this.playerGeneration || this.recoverySeekPending || this.introSeekPending) { return; }
      this.firstFrameSeen = true;
      this.saveStartedEpisode();
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
      if (!this.disposed && generation === this.playerGeneration && !this.userDragging && !this.recoverySeekPending && !this.introSeekPending) {
        this.curMs = time;
        this.applySkipMarks(time);
        if (time > 0 && p.width > 0 && !this.lookingForSource) {
          this.firstFrameSeen = true;
          this.saveStartedEpisode();
          this.loadMessage = '';
          this.stopStartupTimer();
        }
      }
    });
    p.on('bufferingUpdate', (infoType: media.BufferingInfoType, value: number) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      if (infoType === media.BufferingInfoType.BUFFERING_START || infoType === media.BufferingInfoType.BUFFERING_END) {
        this.accountQuota();
      }
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
    p.on('speedDone', (mode: number) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      const index = this.speeds.findIndex((speed: media.PlaybackSpeed) => speed === mode);
      if (index < 0) { return; }
      this.effectiveSpeed = this.speedRates[index];
      this.updateBackgroundSession(this.playing);
    });
    p.on('bitrateDone', (bitrate: number) => {
      if (this.disposed) { return; }
      // HLS 自适应码率切换完成时回调当前码率（bps）
      this.activeBitrate = bitrate;
    });
    p.on('error', (err: BusinessError) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      this.accountQuota();
      if (this.lookingForSource) { this.playing = false; return; }
      if (this.recoverySeekPending) { this.rejectRecoverySource(); return; }
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

  private playPreparedVideo(p: media.AVPlayer, generation: number): void {
    p.play().catch((e: Error) => {
      if (this.disposed || generation !== this.playerGeneration) { return; }
      if (this.handlePlaybackFailure((e as BusinessError).code, generation)) { return; }
      this.switching = false;
      this.loadMessage = '';
      this.stopStartupTimer();
      this.errorMsg = `起播失败：${e.message}`;
    });
  }

  private keepRecoveryPosition(): void {
    if (this.isLive || this.recoveryPositionMs > 0) { return; }
    const position = this.curMs > 0 ? this.curMs : this.resumeMs;
    if (Number.isFinite(position) && position > 0 && (this.durMs <= 0 || position < this.durMs)) {
      this.recoveryPositionMs = position;
    }
  }

  private rejectRecoverySource(): void {
    this.recoverySeekPending = false;
    this.loadMessage = '当前片源无法恢复进度，正在尝试其他片源…';
    this.playerGeneration++;
    this.releasePlayer();
    this.stopStartupTimer();
    this.switching = true;
    this.sourceSwitchTried = true;
    this.switchToNextSource();
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
    this.keepRecoveryPosition();
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

  /** 只尝试包含当前集的备用源。手动换源时，找到候选前保留原播放器。 */
  private async switchToNextSource(manual: boolean = false): Promise<void> {
    this.lookingForSource = true;
    try {
      await this.findReplacementSource(manual);
    } finally {
      this.lookingForSource = false;
    }
  }

  private async findReplacementSource(manual: boolean): Promise<void> {
    const generation = this.playerGeneration;
    const api = this.session.api;
    if (api === null || this.title.trim() === '') {
      this.finishHealFail('没有可用的服务端', manual);
      return;
    }
    const sources = this.session.enabledSources().filter((src) => !this.triedSourceUrls.has(src.url));
    if (sources.length === 0) {
      this.finishHealFail('没有其他可尝试的片源', manual);
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
      this.finishHealFail('其他片源找不到可确认的同一集', manual);
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
      try {
        if (this.session.directCms.shouldTryDirect(src)) {
          try { detail = await this.session.directCms.detail(src, item.vodId); }
          catch (e) { detail = await api.detail(item.vodId, src); }
        } else {
          detail = await api.detail(item.vodId, src);
        }
      } catch (e) { continue; }
      if (this.disposed || generation !== this.playerGeneration) { return false; }
      const labels = detail.episodeLabels ?? [];
      const index = matchEpisodeIndex(this.episodeIndex, this.episodes, this.episodeLabels, detail.episodes, labels);
      if (index < 0 || detail.episodes[index].trim() === '') { continue; }
      this.episodeIndex = index;
      this.episodes = detail.episodes;
      this.episodeLabels = labels;
      this.episodeSource.setItems(this.episodes);
      this.sourceUrl = item.sourceUrl;
      this.vodId = item.vodId;
      this.cover = detail.info.cover !== '' ? detail.info.cover : this.cover;
      this.usePlainUrl = true;
      this.alternateTried = false;
      this.sameUrlRetried = false;
      this.sourceSwitchTried = false;
      this.curMs = 0;
      this.durMs = 0;
      this.switching = false;
      this.gestureMessage = `正在切换至：${item.sourceName}`;
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
  private finishHealFail(reason: string, manual: boolean = false): void {
    this.switching = false;
    this.sourceSwitchTried = false;
    this.loadMessage = '';
    this.stopStartupTimer();
    this.showControls = true;
    if (manual && this.canControl()) {
      this.recoveryPositionMs = 0;
      this.notify(reason);
      return;
    }
    this.errorMsg = `播放失败：${reason}。`;
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
      if (this.recoverySeekPending) { this.rejectRecoverySource(); return; }
      const p = this.player;
      if (this.introSeekPending && p !== null && p.state === 'prepared') {
        this.introSeekPending = false;
        this.startStartupTimer(generation);
        this.playPreparedVideo(p, generation);
        return;
      }
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
      if (!this.canStartForQuota()) { return; }
      p.play().then(() => { this.scheduleHide(); }).catch(() => { this.notify('无法继续播放'); });
    }
  }

  private async startBackgroundPlayback(): Promise<void> {
    if (!this.backgroundPlayback || !this.playing || this.isLive || this.disposed || this.backgroundStarting) { return; }
    this.backgroundStarting = true;
    try {
      if (this.backgroundSession === null) {
        const session = await avSession.createAVSession(getContext(this), 'ShiguangCinema', 'video');
        if (this.disposed) { await session.destroy(); return; }
        this.backgroundSession = session;
        session.on('play', () => {
          if (this.canStartForQuota() && !this.switching) { this.player?.play().catch(() => {}); }
        });
        session.on('pause', () => { this.player?.pause().catch(() => {}); });
        session.on('stop', () => { this.player?.pause().catch(() => {}); });
        session.on('seek', (time: number) => { this.seekFromMediaCenter(time); });
        session.on('fastForward', () => { this.skipFromMediaCenter(1); });
        session.on('rewind', () => { this.skipFromMediaCenter(-1); });
        this.syncBackgroundControls(session, false);
        await session.activate();
      }
      if (this.disposed || !this.playing) { return; }
      await this.updateBackgroundSession(true);
      if (!this.backgroundTaskActive && !this.disposed && this.playing) {
        const agent = await wantAgent.getWantAgent({
          wants: [{ bundleName: 'com.lshai.shiguangcinema', abilityName: 'EntryAbility' }],
          operationType: wantAgent.OperationType.START_ABILITY,
          requestCode: 1
        });
        if (this.disposed || !this.playing) { return; }
        await backgroundTaskManager.startBackgroundRunning(getContext(this),
          backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK, agent);
        this.backgroundTaskActive = true;
        if (this.disposed || !this.playing) { await this.stopBackgroundTask(); }
      }
    } catch (e) {
      hilog.warn(0, 'ShiguangCinema', 'background playback start failed: %{public}s', (e as Error).message);
    } finally {
      this.backgroundStarting = false;
    }
  }

  private syncBackgroundControls(session: avSession.AVSession, configure: boolean = true): void {
    const previous = this.episodeIndex > 0;
    const next = this.episodeIndex + 1 < this.episodes.length;
    if (previous !== this.backgroundCanGoPrevious) {
      if (previous) { session.on('playPrevious', () => { this.switchEpisode(-1); }); }
      else { session.off('playPrevious'); }
      this.backgroundCanGoPrevious = previous;
    }
    if (next !== this.backgroundCanGoNext) {
      if (next) { session.on('playNext', () => { this.switchEpisode(1); }); }
      else { session.off('playNext'); }
      this.backgroundCanGoNext = next;
    }
    const key = `${previous}:${next}`;
    if (configure && key !== this.backgroundControlsKey &&
      deviceInfo.sdkApiVersion >= 26 && typeof session.setMediaCenterControlType === 'function') {
      this.backgroundControlsKey = key;
      const controls: avSession.AVMediaCenterControlType[] = ['rewind', 'fastForward'];
      if (previous) { controls.push('playPrevious'); }
      if (next) { controls.push('playNext'); }
      session.setMediaCenterControlType(controls).catch(() => {
        if (this.backgroundControlsKey === key) { this.backgroundControlsKey = ''; }
      });
    }
  }

  private skipFromMediaCenter(direction: number): void {
    const player = this.player;
    if (player === null) { return; }
    const position = Number.isFinite(player.currentTime) && player.currentTime >= 0 ? player.currentTime : this.curMs;
    this.seekFromMediaCenter(position + direction * 10000);
  }

  private seekFromMediaCenter(position: number): void {
    if (this.disposed || this.switching || !Number.isFinite(position)) { return; }
    this.seekTo(position);
  }

  private refreshBackgroundArtwork(session: avSession.AVSession): void {
    const raw = this.cover.trim();
    const origin = this.sourceUrl.match(/^https?:\/\/[^/?#]+/);
    const url = raw.startsWith('//') ? `https:${raw}` :
      (raw.startsWith('/') && origin !== null ? origin[0] + raw : raw);
    if (url === this.backgroundArtworkKey) { return; }
    this.backgroundArtworkKey = url;
    this.backgroundArtwork = null;
    if (!/^https?:\/\//i.test(url)) { return; }
    const api = this.session.api;
    loadPosterBitmap(getContext(this), url, api?.imageUrl(url) ?? '', api?.currentCookie() ?? '')
      .then((bitmap: image.PixelMap | null) => {
        if (bitmap === null || this.disposed || this.backgroundSession !== session || this.backgroundArtworkKey !== url) {
          return;
        }
        this.backgroundArtwork = bitmap;
        this.updateBackgroundSession(this.playing);
      }).catch(() => {});
  }

  private async updateBackgroundSession(isPlaying: boolean): Promise<void> {
    const session = this.backgroundSession;
    if (session === null || this.disposed) { return; }
    const update = ++this.backgroundUpdate;
    try {
      this.refreshBackgroundArtwork(session);
      this.syncBackgroundControls(session);
      const metadata: avSession.AVMetadata = {
        assetId: `${this.vodId}:${this.episodeIndex}`,
        title: this.title, artist: this.episodeTitle(this.episodeIndex),
        duration: this.durMs, skipIntervals: avSession.SkipIntervals.SECONDS_10
      };
      if (deviceInfo.sdkApiVersion >= 26) {
        metadata.rewindSkipIntervals = avSession.SkipIntervals.SECONDS_10;
        metadata.fastForwardSkipIntervals = avSession.SkipIntervals.SECONDS_10;
      }
      const metadataKey = `${this.sourceUrl}|${metadata.assetId}|${this.durMs}|${this.backgroundArtworkKey}|${this.backgroundArtwork !== null}`;
      if (metadataKey !== this.backgroundMetadataKey) {
        if (this.backgroundArtwork !== null) { metadata.mediaImage = this.backgroundArtwork; }
        await session.setAVMetadata(metadata);
        if (update === this.backgroundUpdate && session === this.backgroundSession) {
          this.backgroundMetadataKey = metadataKey;
        }
      }
      if (update !== this.backgroundUpdate || session !== this.backgroundSession) { return; }
      await session.setAVPlaybackState({ state: isPlaying ? avSession.PlaybackState.PLAYBACK_STATE_PLAY :
        avSession.PlaybackState.PLAYBACK_STATE_PAUSE, speed: this.effectiveSpeed, duration: this.durMs,
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
    this.backgroundCanGoPrevious = false;
    this.backgroundCanGoNext = false;
    this.backgroundArtworkKey = '';
    this.backgroundMetadataKey = '';
    this.backgroundControlsKey = '';
    this.backgroundArtwork = null;
    if (session !== null) {
      try { await session.destroy(); } catch (e) { /* The system may already have closed this session. */ }
    }
  }

  private switchEpisode(delta: number, finished: boolean = false): void {
    const next = this.episodeIndex + delta;
    if (next < 0 || next >= this.episodes.length || this.switching) {
      return;
    }
    if (!finished) { this.saveProgress(true); }
    this.episodeIndex = next;
    this.saveNextOnStart = finished && !this.isLive && this.rememberProgress;
    if (this.saveNextOnStart) { this.writeProgress(0, 0, true); }
    this.usePlainUrl = true;
    this.alternateTried = false;
    this.sameUrlRetried = false;
    this.sourceSwitchTried = false;
    this.triedSourceUrls = new Set([this.sourceUrl]);
    this.curMs = 0;
    this.durMs = 0;
    this.resumeMs = 0;
    this.recoveryPositionMs = 0;
    this.resumeRequestedManually = false;
    this.setupPlayer();
  }

  private selectEpisode(index: number): void {
    if (index === this.episodeIndex || this.switching) { this.showEpisodes = false; return; }
    this.saveProgress(true);
    this.episodeIndex = index;
    this.saveNextOnStart = false;
    this.usePlainUrl = true;
    this.alternateTried = false;
    this.sameUrlRetried = false;
    this.sourceSwitchTried = false;
    this.triedSourceUrls = new Set([this.sourceUrl]);
    this.curMs = 0;
    this.durMs = 0;
    this.resumeMs = 0;
    this.recoveryPositionMs = 0;
    this.showEpisodes = false;
    this.setupPlayer();
  }

  private retryPlayback(): void {
    if (this.switching) { return; }
    this.keepRecoveryPosition();
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
    if (this.switching) { this.userDragging = false; return; }
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

  private saveStartedEpisode(): void {
    if (!this.saveNextOnStart || !this.playing || this.switching || this.durMs <= 0) { return; }
    this.saveNextOnStart = false;
    this.saveProgress(false);
  }

  private saveProgress(final: boolean): void {
    const p = this.player;
    if (p === null || this.durMs <= 0 || this.recoverySeekPending || this.introSeekPending || this.saveNextOnStart) { return; }
    this.writeProgress(final ? p.currentTime : this.curMs, this.durMs, final);
  }

  private episodeTitle(index: number): string {
    const label = (this.episodeLabels[index] ?? '').trim();
    return label !== '' ? label : `第 ${index + 1} 集`;
  }

  private writeProgress(position: number, duration: number, final: boolean): void {
    if (this.isLive || !this.rememberProgress || this.prefs === null) { return; }
    const entry: WatchEntry = entryFromStatus(
      this.session.serverUrl, this.sourceUrl, this.vodId,
      this.title, this.cover,
      this.episodeIndex, this.episodes.length,
      position, duration
    );
    entry.episodeLabel = this.episodeLabels[this.episodeIndex] ?? '';
    this.prefs.saveWatch(entry).catch(() => {
      if (final) { promptAction.showToast({ message: '观看进度保存失败，请检查设备存储' }); }
    });
  }


  private notify(message: string): void {
    promptAction.showToast({ message: message, duration: 1600 });
  }

  private canControl(): boolean {
    return !this.recoverySeekPending && !this.introSeekPending && this.player !== null &&
      ['prepared', 'playing', 'paused', 'completed'].includes(this.player.state);
  }

  private seekTo(position: number): void {
    if (!this.canControl() || this.isLive || this.durMs <= 0) { return; }
    const target = Math.max(0, Math.min(position, Math.max(0, this.durMs - 300)));
    try {
      (this.player as media.AVPlayer).seek(target, media.SeekMode.SEEK_PREV_SYNC);
      this.curMs = target;
    } catch (e) { this.notify('当前视频暂时无法定位'); }
  }

  private markIntroEnd(): void {
    const position = Math.floor(this.curMs);
    if (this.isLive || this.switching || this.userDragging || !this.canControl() ||
      !Number.isFinite(position) || position <= 0 || position >= this.durMs) { return; }
    this.introEndMs = position;
    this.autoIntro = true;
    this.saveSkipMarks();
    this.notify(`已标记片头结束 · ${this.fmt(position)}，下集自动跳过`);
  }

  private shouldSkipIntroAtStartup(): boolean {
    if (this.isLive || !this.autoIntro || this.introEndMs <= 0 || this.introEndMs >= this.durMs) {
      return false;
    }
    const hasResume = this.resumeMs > 0 && (this.resumeRequestedManually ||
      (this.rememberProgress && this.resumeMs >= this.resumeThresholdSeconds * 1000));
    return !hasResume || this.resumeMs < this.introEndMs;
  }

  private markOutroStart(advance: boolean): void {
    const position = Math.floor(this.curMs);
    if (this.isLive || this.switching || this.userDragging || !this.canControl() ||
      !Number.isFinite(position) || position <= 0 || position >= this.durMs) { return; }

    this.outroStartMs = position;
    this.outroRemainingMs = this.durMs - position;
    this.outroReferenceMs = this.durMs;
    this.autoOutro = true;
    this.outroMarkedEpisode = this.episodeIndex;
    this.saveSkipMarks();

    if (!advance) {
      this.notify('已保存本剧片尾位置');
      return;
    }
    if (this.episodeIndex < this.episodes.length - 1) {
      this.switchEpisode(1, true);
      this.notify('已标记片尾，正在播放下一集');
    } else {
      this.seekTo(this.durMs - 300);
      this.notify('已标记片尾，当前为最后一集');
    }
  }

  /**
   * 本集该从哪一刻算作片尾（v1.5.2）。
   * 新标记记的是「距结束还剩多少」，按当前集时长反推；但若当前集时长与记标记时
   * 相差超过 max(30 秒, 25%)，说明不是同一规格的剧集，宁可不动也不误跳。
   * 旧标记（没有 remaining）继续用绝对位置。
   */
  private effectiveOutroStart(): number {
    if (this.outroRemainingMs > 0 && this.outroReferenceMs > 0) {
      if (this.durMs <= 0) {
        return -1;
      }
      const tolerance = Math.max(30000, this.outroReferenceMs / 4);
      if (Math.abs(this.durMs - this.outroReferenceMs) > tolerance) {
        return -1;
      }
      const start = this.durMs - this.outroRemainingMs;
      return start > 0 && start < this.durMs ? start : -1;
    }
    return this.outroStartMs > 0 && this.outroStartMs < this.durMs ? this.outroStartMs : -1;
  }

  private applySkipMarks(time: number): void {
    if (this.isLive || !this.playing || this.switching || this.userDragging || this.durMs <= 0 || !this.marksLoaded) { return; }
    if (this.autoOutro && this.outroMarkedEpisode !== this.episodeIndex &&
      this.episodeIndex < this.episodes.length - 1) {
      const start = this.effectiveOutroStart();
      if (start > 0 && time >= start) { this.switchEpisode(1, true); }
    }
  }

  private saveSkipMarks(): void {
    if (this.prefs === null) { return; }
    const marks: SkipMarks = { introEndMs: this.introEndMs, outroStartMs: this.outroStartMs,
      autoIntro: this.autoIntro, autoOutro: this.autoOutro,
      outroRemainingMs: this.outroRemainingMs, outroReferenceMs: this.outroReferenceMs };
    this.prefs.setSkipMarks(this.title, marks).catch(() => { this.notify('片头片尾设置保存失败'); });
  }

  // ---------------------------------------------------------------- 儿童额度

  private canStartForQuota(): boolean {
    if (!this.quotaReady || this.quotaInitFailed) { this.notify('儿童时间设置尚未就绪'); return false; }
    if (this.childManaged && this.quota !== null && this.quota.isExhausted()) {
      this.notify('今天的儿童时间已用完，明天再来吧');
      return false;
    }
    return true;
  }

  /** 按经过时间计费，并在播放与缓冲状态变化时结算。 */
  private accountQuota(): void {
    const now = Date.now();
    const previous = this.quotaLastAt;
    this.quotaLastAt = now;
    const quota = this.quota;
    if (previous <= 0 || now <= previous || quota === null || !this.childManaged ||
      !this.playing || this.buffering || this.isLive || this.quotaPausePending) { return; }
    // 跨零点时，昨天的部分不计入今天的额度。
    const midnight = new Date(now);
    midnight.setHours(0, 0, 0, 0);
    const elapsed = now - Math.max(previous, midnight.getTime());
    if (elapsed > 0 && quota.consume(elapsed)) { this.pauseForQuota(); }
  }

  private startQuotaTimer(): void {
    if (this.quotaTimer >= 0) { return; }
    this.quotaLastAt = Date.now();
    this.quotaTimer = setInterval(() => { this.accountQuota(); }, 1000);
  }

  private stopQuotaTimer(): void {
    this.accountQuota();
    if (this.quotaTimer >= 0) { clearInterval(this.quotaTimer); this.quotaTimer = -1; }
    this.quotaLastAt = 0;
    if (this.quota !== null) { this.quota.flush(); }
  }

  private pauseForQuota(): void {
    const p = this.player;
    if (p === null || this.quotaPausePending || p.state === 'paused' ||
      p.state === 'completed' || p.state === 'stopped') { return; }
    this.quotaPausePending = true;
    p.pause().then(() => {
      this.playing = false;
      this.isPaused = true;
      this.saveProgress(true);
      this.showControls = true;
      this.notify('今天的儿童时间已用完，明天再来吧');
    }).catch(() => {
      if (this.disposed || this.player !== p) { return; }
      this.playerGeneration++; this.player = null; this.playing = false; this.switching = false;
      this.stopStartupTimer(); p.release().catch(() => {});
      this.errorMsg = '儿童时间已用完，暂停失败，请返回'; this.showControls = true;
    }).finally(() => { this.quotaPausePending = false; });
  }

  /** 点击换源后自动寻找备用源，保持当前集和点击时的进度。 */
  private openSourceSwitch(): void {
    this.activeMenu = '';
    if (this.isLive || this.switching || this.lookingForSource) { return; }
    this.saveProgress(true);
    this.keepRecoveryPosition();
    this.triedSourceUrls = new Set([this.sourceUrl]);
    this.switching = true;
    this.loadMessage = '正在寻找可用片源…';
    this.showControls = true;
    this.switchToNextSource(true);
  }

  /** 普通返回：保存进度、停止播放，直接回首页（v1.3.11） */
  private leaveToHome(): void {
    this.saveProgress(true);
    this.stopQuotaTimer();
    try {
      router.back({ url: 'pages/Index' });
    } catch (e) {
      router.back();
    }
  }

  private toggleFullscreen(): void {
    this.pureFullscreen = !this.pureFullscreen;
    this.cropVideo = this.pureFullscreen;
    this.applyScale();
    this.showControls = !this.pureFullscreen;
  }

  private beginTemporarySpeed(): void {
    if (this.locked || this.isLive || !this.playing || !this.canControl() || this.temporarySpeed) { return; }
    try {
      (this.player as media.AVPlayer).setSpeed(media.PlaybackSpeed.SPEED_FORWARD_2_00_X);
      this.temporarySpeed = true;
      this.suppressClickUntil = Date.now() + 1000;
      this.gestureMessage = '2.0× 快进中';
      if (this.hudTimer >= 0) { clearTimeout(this.hudTimer); this.hudTimer = -1; }
    } catch (e) { this.notify('当前视频不支持 2 倍速'); }
  }

  private endTemporarySpeed(): void {
    if (!this.temporarySpeed) { return; }
    this.temporarySpeed = false;
    this.suppressClickUntil = Date.now() + 500;
    if (this.player !== null && this.canControl()) {
      try { this.player.setSpeed(this.speeds[this.speedIndex]); }
      catch (e) { this.notify('无法恢复播放倍速'); }
    }
    this.gestureMessage = '';
  }

  private setSpeed(index: number): void {
    if (this.isLive || !this.canControl()) { this.notify('视频准备完成后可调整倍速'); return; }
    this.endTemporarySpeed();
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
    if (this.switching) { return; }
    this.recoveryPositionMs = 0;
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
      items.push({ label: `跳到片头结束 ${this.fmt(this.introEndMs)}`, action: () => {
        if (this.introEndMs > this.curMs && this.introEndMs < this.durMs) { this.seekTo(this.introEndMs); }
        this.activeMenu = '';
      } });
      items.push({ label: `将当前位置 ${this.fmt(this.curMs)} 记为片头结束`, action: () => { this.markIntroEnd(); } });
      items.push({ label: '将当前位置记为片尾开始', action: () => { this.markOutroStart(false); } });
      items.push({ label: `自动跳片头：${this.autoIntro ? '开' : '关'}`, action: () => { this.autoIntro = !this.autoIntro; this.saveSkipMarks(); } });
      items.push({ label: `自动跳片尾：${this.autoOutro ? '开' : '关'}`, action: () => { this.autoOutro = !this.autoOutro; this.saveSkipMarks(); } });
      for (const seconds of [30, 60, 90, 120, 180]) {
        items.push({ label: `片头时长 ${seconds} 秒`, action: () => { this.introEndMs = seconds * 1000; this.saveSkipMarks(); } });
      }
      items.push({ label: '清除本剧标记并关闭自动跳过', action: () => {
        this.introEndMs = 90000; this.outroStartMs = 0; this.autoIntro = false; this.autoOutro = false;
        this.outroRemainingMs = 0; this.outroReferenceMs = 0;
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
      items.push({ label: `清晰度：${this.qualityLabel()}`, action: () => { this.activeMenu = 'quality'; } });
      items.push({ label: '换一个片源', action: () => { this.openSourceSwitch(); } });
      items.push({ label: '片头 / 片尾设置', action: () => { this.activeMenu = 'skip'; } });
      items.push({ label: `自动连播：${this.autoNext ? '开' : '关'}`, action: () => { this.autoNext = !this.autoNext; this.saveSettings(); } });
      items.push({ label: `显示比例：${this.cropVideo ? '裁切铺满' : '保持原比例'}`, action: () => {
        this.cropVideo = !this.cropVideo; this.pureFullscreen = false; this.applyScale(); this.saveSettings();
      } });
      items.push({ label: '音轨 / 字幕', action: () => { this.activeMenu = 'tracks'; } });
      items.push({ label: this.sleepMinutes > 0 ? `定时暂停：${this.sleepMinutes} 分钟` : '定时暂停', action: () => { this.activeMenu = 'sleep'; } });
      items.push({ label: '锁定操作', action: () => { this.locked = true; this.activeMenu = ''; this.showControls = false; } });
      items.push({ label: '退出播放', action: () => { this.leaveToHome(); } });
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
          if (this.locked || Date.now() < this.suppressClickUntil) { return; }
          const centerX = this.viewportWidth / 2;
          const centerY = this.viewportHeight / 2;
          // 用组件内坐标（x/y）而不是窗口坐标（displayX/displayY），与 viewport 尺寸同源
          if (Math.abs(event.x - centerX) < this.viewportWidth * 0.22 &&
            Math.abs(event.y - centerY) < this.viewportHeight * 0.28) {
            this.togglePlay();
          } else { this.scheduleHide(); }
        })
        .gesture(GestureGroup(GestureMode.Exclusive,
          PanGesture({ fingers: 1, direction: PanDirection.All, distance: 12 })
            .onActionStart((event: GestureEvent) => { this.beginGesture(event); })
            .onActionUpdate((event: GestureEvent) => { this.updateGesture(event); })
            .onActionEnd((event: GestureEvent) => { this.endGesture(event); })
            .onActionCancel(() => { this.cancelGesture(); }),
          LongPressGesture({ fingers: 1, duration: 500 })
            .onAction(() => { this.beginTemporarySpeed(); })
            .onActionEnd(() => { this.endTemporarySpeed(); })
            .onActionCancel(() => { this.endTemporarySpeed(); })))

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
              .onClick(() => { this.leaveToHome(); })
            Text(this.isLive
              ? `${this.title} · 直播`
              : `${this.title} · ${this.episodeTitle(this.episodeIndex)}`)
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
              this.toolbarButton('片头', this.durMs > 0 && this.curMs > 0 && !this.switching, () => { this.markIntroEnd(); })
              this.toolbarButton('片尾', this.durMs > 0 && this.curMs > 0 && !this.switching, () => { this.markOutroStart(true); })
            }
            this.toolbarButton(this.isLive ? '上台' : '上集', this.episodeIndex > 0, () => { this.switchEpisode(-1); })
            this.toolbarButton(this.isLive ? '下台' : '下集', this.episodeIndex < this.episodes.length - 1, () => { this.switchEpisode(1); })
            if (!this.isLive) {
              Text(`倍速 ${this.speedLabels[this.speedIndex]}`).fontSize(12).fontColor('#FFFFFF')
                .height(42).layoutWeight(1).textAlign(TextAlign.Center).maxLines(1)
                .onClick(() => { this.activeMenu = 'speed'; })
            }
            this.toolbarButton('选集', true, () => { this.showEpisodes = true; })
            // 换源常驻底部（v1.3.11）；清晰度收进「更多」，底部只留最常用的操作
            if (!this.isLive) {
              this.toolbarButton('换源', !this.switching, () => { this.openSourceSwitch(); })
            }
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
            LazyForEach(this.episodeSource, (_url: string, index: number) => {
              ListItem() {
                Text(this.isLive ? `频道 ${index + 1}` : this.episodeTitle(index))
                  .width('100%').padding(12).borderRadius(8)
                  .fontColor(index === this.episodeIndex ? '#FFFFFF' : '#DDDDDD')
                  .backgroundColor(index === this.episodeIndex ? '#0F766E' : '#33333A')
                  .onClick(() => { this.selectEpisode(index); })
              }
            }, (_url: string, index: number) => index.toString())
          }.layoutWeight(1).width('100%').cachedCount(8)
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
