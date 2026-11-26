const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require(require('node:path').join(process.env.DEVECO_SDK_HOME || 'E:/Development/command-line-tools/sdk', 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
function load(src, requireFn) {
  const js = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const ctx = { exports: {}, require: requireFn || (() => ({})), console, setTimeout, clearTimeout };
  vm.runInNewContext(js, ctx); return ctx.exports;
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test('poster cache reserves six slots and old completions cannot poison new requests', async () => {
  let source = fs.readFileSync('entry/src/main/ets/components/PosterImage.ets', 'utf8');
  source = source.slice(0, source.indexOf('export function clearPosterCache')) + '\nexport { PosterCache };';
  const { PosterCache: cache } = load(source, name => name === '@kit.ImageKit' ? { image: {} } : {});
  let active = 0, peak = 0;
  const pending = [];
  cache.readDisk = async () => null;
  cache.fetch = async () => {
    active++; peak = Math.max(peak, active);
    return new Promise(resolve => pending.push(() => { active--; resolve({}); }));
  };
  cache.writeDisk = () => {};
  const context = { filesDir: 'fake' };
  const jobs = Array.from({length: 15}, (_, i) => cache.get(context, `url${i}`, '', ''));
  await tick();
  assert.equal(active, 6); assert.equal(peak, 6);
  cache.clear();
  const newJob = cache.get(context, 'new', '', '');
  while (pending.length) { pending.shift()(); await tick(); }
  await Promise.all([...jobs, newJob]);
  assert.ok(peak <= 6);
  assert.equal(cache.failures.size, 0);
});

test('children quota migrates legacy data and serializes complete snapshots', async () => {
  const source = fs.readFileSync('entry/src/main/ets/store/ChildrenQuota.ets', 'utf8');
  const quota = load(source, name => name.includes('ChildrenCatalog') ? { ChildrenCatalog: { allTitles: () => [] } } : {});
  const today = new Date();
  const day = `${today.getFullYear()}-${String(today.getMonth()+1).padStart(2,'0')}-${String(today.getDate()).padStart(2,'0')}`;
  const values = {childrenUsedDay: day, childrenUsedMs: '6000', childrenBonusMs: '0', childrenLimitMinutes: '15'};
  const writes = [];
  const waits = [];
  const prefs = { getRaw: (k, d) => values[k] ?? d, getStringList: () => [],
    putRaw: (key, value) => new Promise(resolve => { writes.push(JSON.parse(value)); waits.push(resolve); }) };
  const q = await quota.ChildrenQuota.get(prefs);
  assert.equal(q.usedTodayMs(), 6000);
  q.consume(5000);
  const updated = q.setDailyMinutes(20);
  await tick();
  assert.equal(writes.length, 1); assert.equal(writes[0].usedMs, 11000); assert.equal(writes[0].limitMinutes, 15);
  waits.shift()(); await tick();
  assert.equal(writes.length, 2); assert.equal(writes[1].limitMinutes, 20); assert.equal(writes[1].usedMs, 11000);
  waits.shift()(); await updated;
});

test('search queries initial server sources once and retries only failures', async () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Search.ets', 'utf8');
  const start = src.indexOf('  private async runSearch(');
  const end = src.indexOf('\n  /**', start);
  const method = src.slice(start, end).replace('private async runSearch', 'async runSearch');
  const progress = src.slice(src.indexOf('  private updateSearchProgress()'), src.indexOf('  /** 直连源并发跑', src.indexOf('  private updateSearchProgress()')));
  const { SearchHarness } = load(`export class SearchHarness { ${method} ${progress} }`);
  const calls = [];
  const h = new SearchHarness();
  h.searchGeneration = 1; h.groups = []; h.freshResults = []; h.refreshFailed = false; h.applyIncoming = () => {};
  h.session = {
    enabledSources: () => [{url: 'server'}, {url: 'direct-ok'}, {url: 'direct-fail'}],
    directCms: { shouldTryDirect: s => s.url.startsWith('direct'),
      search: async s => { if (s.url === 'direct-fail') throw new Error('offline'); return []; } },
    api: { search: async (_, sources) => { calls.push(sources.map(s => s.url)); return {items: [], failures: 0}; } }
  };
  await h.runSearch('test', 1);
  assert.equal(JSON.stringify(calls), JSON.stringify([['server'], ['direct-fail']]));
});

test('saved empty source list remains distinguishable from uninitialized sources', async () => {
  const json = load(fs.readFileSync('entry/src/main/ets/api/JsonUtil.ets', 'utf8'));
  const { Prefs } = load(fs.readFileSync('entry/src/main/ets/store/Prefs.ets', 'utf8'), name => name.includes('JsonUtil') ? json : {});
  const p = new Prefs(); const values = {};
  p.store = {getSync: (k, d) => values[k] ?? d, put: async (k, v) => { values[k] = v; }, flush: async () => {}};
  assert.equal(await p.hasSources('server'), false);
  await p.setSources('server', []);
  assert.equal(await p.hasSources('server'), true);
  assert.equal((await p.getSources('server')).length, 0);
});

test('history writes serialize completed episode before a new episode', async () => {
  const json = load(fs.readFileSync('entry/src/main/ets/api/JsonUtil.ets', 'utf8'));
  const { Prefs } = load(fs.readFileSync('entry/src/main/ets/store/Prefs.ets', 'utf8'), name => name.includes('JsonUtil') ? json : {});
  const p = new Prefs(); const values = {}; const writes = []; const release = [];
  p.store = { getSync: (k, d) => values[k] ?? d,
    put: (k, v) => new Promise(resolve => { writes.push(JSON.parse(v)); release.push(() => { values[k] = v; resolve(); }); }),
    flush: async () => {} };
  const entry = (episodeIndex, positionMs) => ({ key: 'k', serverUrl: 's', sourceUrl: 'x', vodId: 'v', title: 't', cover: '', episodeIndex, episodeCount: 3, positionMs, durationMs: 100, updatedAt: episodeIndex });
  const first = p.saveWatch({ ...entry(0, 100), cover: 'old.jpg' });
  const second = p.saveWatch(entry(1, 5));
  await tick(); assert.equal(writes.length, 1); assert.equal(writes[0].list[0].episodeIndex, 0);
  release.shift()(); await tick(); assert.equal(writes.length, 2); assert.equal(writes[1].list[0].episodeIndex, 1);
  release.shift()(); await Promise.all([first, second]);
  assert.equal((await p.getHistory())[0].cover, 'old.jpg');
  const repair = p.updateWatchCover('k', 'old.jpg', 'new.jpg');
  await tick();
  assert.equal(writes[2].list[0].cover, 'new.jpg');
  assert.equal(writes[2].list[0].episodeIndex, 1);
  assert.equal(writes[2].list[0].positionMs, 5);
  release.shift()();
  await repair;
  await p.updateWatchCover('k', 'old.jpg', 'stale.jpg');
  assert.equal((await p.getHistory())[0].cover, 'new.jpg');
});

test('search cache omits disabled sources and can discard stale empty results', () => {
  const models = {builtInSources: () => []};
  const { Session } = load(fs.readFileSync('entry/src/main/ets/store/Session.ets', 'utf8'), name => name.includes('Models') ? models : { DirectCms: class {} });
  const s = new Session(); s.serverUrl = 'server';
  s.sources = [{url:'a', enabled:true}, {url:'b', enabled:false}];
  s.rememberSearch('film', [{sourceUrl:'a'}, {sourceUrl:'b'}]);
  assert.equal(s.cachedSearch('film').length, 1);
  s.sources = []; assert.equal(s.cachedSearch('film').length, 0);
  s.forgetSearch('film'); s.sources = [{url:'a', enabled:true}];
  assert.equal(s.cachedSearch('film').length, 0);
});

test('exhausted child quota blocks resume before invoking the player', () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Player.ets', 'utf8');
  const extract = (start, end) => src.slice(src.indexOf(start), src.indexOf(end, src.indexOf(start))).replaceAll('private ', '');
  const methods = extract('  private togglePlay():', '  private async startBackgroundPlayback') +
    extract('  private canStartForQuota():', '  /** 按经过时间计费');
  const { PlayerHarness } = load(`export class PlayerHarness { ${methods} }`);
  const p = new PlayerHarness(); let played = 0;
  p.player = {play: () => {played++; return Promise.resolve();}}; p.switching = false; p.playing = false; p.errorMsg = '';
  p.quotaReady = true; p.quotaInitFailed = false; p.childManaged = true; p.quota = {isExhausted: () => true};
  p.notify = () => {}; p.togglePlay(); assert.equal(played, 0);
  p.quota.isExhausted = () => false; p.scheduleHide = () => {}; p.togglePlay(); assert.equal(played, 1);
});

test('recent viewing resumes the exact episode and saved position from cache', async () => {
  const source = fs.readFileSync('entry/src/main/ets/common/ResumePlayback.ets', 'utf8');
  let networkCalls = 0;
  const episodeCache = {getRecord: () => ({urls: ['first', 'second'], labels: ['第1集', '第2集']}), put: () => {}};
  const episodeMatch = load(fs.readFileSync('entry/src/main/ets/common/EpisodeMatch.ets', 'utf8'));
  const { resumePlaybackParams } = load(source, name => name.includes('EpisodeCache') ? { EpisodeCache: episodeCache } : episodeMatch);
  const session = {serverUrl:'https://server', sources: [], api:{detail: async () => {networkCalls++;}}, directCms: {}};
  const entry = {serverUrl:'https://server', sourceUrl:'https://source', vodId:'1', episodeIndex:1, positionMs:42420, title:'剧', cover:'pic'};
  const p = await resumePlaybackParams({}, entry, session);
  assert.equal(p.index, '1'); assert.equal(p.resumeMs, '42420'); assert.equal(p.forceResume, '1');
  assert.deepEqual(JSON.parse(p.episodes), ['first', 'second']);
  assert.deepEqual(JSON.parse(p.episodeLabels), ['第1集', '第2集']); assert.equal(networkCalls, 0);
  episodeCache.getRecord = () => ({ urls: ['trailer','first','second'], labels: ['预告','EP01','EP02'] });
  const reordered = await resumePlaybackParams({}, { ...entry, episodeLabel: '第2集' }, session);
  assert.equal(reordered.index, '2');
  assert.equal(reordered.resumeMs, '42420');
  assert.equal(networkCalls, 0);
  session.serverUrl = 'https://other';
  await assert.rejects(resumePlaybackParams({}, entry, session), /其他服务端/);
});

test('recent viewing fetches missing episodes and reports unavailable saved episode', async () => {
  const source = fs.readFileSync('entry/src/main/ets/common/ResumePlayback.ets', 'utf8');
  const episodeCache = {getRecord: () => null, put: () => {}};
  const episodeMatch = load(fs.readFileSync('entry/src/main/ets/common/EpisodeMatch.ets', 'utf8'));
  const { resumePlaybackParams } = load(source, name => name.includes('EpisodeCache') ? { EpisodeCache: episodeCache } : episodeMatch);
  const entry = {serverUrl:'s', sourceUrl:'src', vodId:'1', episodeIndex:1, positionMs:100, title:'剧', cover:''};
  const session = {serverUrl:'s', sources:[{url:'src'}], directCms:{shouldTryDirect: () => true, detail: async () => {throw Error('unavailable');}},
    api:{detail: async () => ({episodes:['first', 'second']})}};
  const p = await resumePlaybackParams({}, entry, session);
  assert.equal(p.index, '1'); assert.equal(p.resumeMs, '100');
  session.api.detail = async () => ({episodes:['first']});
  await assert.rejects(resumePlaybackParams({}, entry, session), /集数已不可用/);
  session.api.detail = async () => ({episodes:['first', 'special'], episodeLabels:['第1集', '特别篇']});
  await assert.rejects(resumePlaybackParams({}, { ...entry, episodeLabel: '第2集' }, session), /集数已不可用/);
});

test('search suggestions load separate movie, television and animation lists', async () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Search.ets', 'utf8');
  const a = src.indexOf('  private prepareHotSections():');
  const b = src.indexOf('  @Builder', a);
  const methods = src.slice(a, b).replaceAll('private ', '');
  const prefix = "const ChildrenCatalog = { sections: () => [{ titles: ['小猪佩奇','汪汪队立大功','布鲁伊'] }] };\n";
  const { HotHarness } = load(`${prefix}export class HotHarness { ${methods} }`);
  const h = new HotHarness(); const requests = [];
  h.origin = ''; h.active = true; h.hotGeneration = 0; h.hotSections = []; h.hotCacheWrites = Promise.resolve();
  h.prefs = {getRecommendations: async () => [], setRecommendations: async () => {}};
  h.session = {serverUrl:'server', api:{douban: async (type, tag) => { requests.push(`${type}|${tag}`); return [{title: `${type}-${tag}`, cover:'', rating:''}]; }}};
  h.prepareHotSections(); h.loadHot(); await tick(); await tick();
  assert.equal(JSON.stringify(requests.sort()), JSON.stringify(['movie|热门','tv|国产动画','tv|热门'].sort()));
  assert.equal(h.hotSections.length, 4);
  assert.equal(h.hotSections.find(s => s.key === 'kids').items[0].title, '小猪佩奇');
  assert.equal(h.hotSections.find(s => s.key === 'movie').items[0].title, 'movie-热门');
  h.toggleHot('movie'); assert.equal(h.hotSections.find(s => s.key === 'movie').expanded, true);
});

test('cancelling a search destroys only its requests and prevents double destruction', () => {
  const src = fs.readFileSync('entry/src/main/ets/api/DirectCms.ets', 'utf8');
  const { SearchRequests } = load(src);
  const group = new SearchRequests();
  let destroyed = 0;
  const client = { destroy: () => { destroyed++; } };
  group.add(client);
  group.cancel();
  assert.equal(group.cancelled, true);
  assert.equal(destroyed, 1);
  assert.equal(group.remove(client), false);
  group.cancel();
  assert.equal(destroyed, 1);
});

test('skip actions and temporary speed preserve episode and playback state', () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Player.ets', 'utf8');
  const method = (name, next) => src.slice(src.indexOf(`  private ${name}`), src.indexOf(next, src.indexOf(`  private ${name}`))).replace('private ', '');
  const code = [method('markOutroStart(', '\n  /**'),
    method('effectiveOutroStart()', '\n  private applySkipMarks'),
    method('applySkipMarks(', '\n  private saveSkipMarks'),
    method('beginTemporarySpeed()', '\n  private endTemporarySpeed'),
    method('endTemporarySpeed()', '\n  private setSpeed')].join('\n');
  const js = ts.transpileModule(`export class Harness { ${code} }`, {compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText;
  const context = {exports:{}, media:{PlaybackSpeed:{SPEED_FORWARD_2_00_X:2}}, Date, clearTimeout};
  vm.runInNewContext(js, context);
  const h = new context.exports.Harness();
  Object.assign(h, { isLive:false, playing:true, switching:false, userDragging:false, durMs:600000,
    marksLoaded:true,
    autoOutro:false, autoNext:false, outroMarkedEpisode:-1, episodeIndex:0, episodes:['a','b','c'],
    speedIndex:3, speeds:[0.75,1,1.25,1.5,1.75,2], locked:false, temporarySpeed:false,
    hudTimer:-1, gestureMessage:'', canControl:()=>true, notify:()=>{}, fmt:()=>'',
    seekTo:value=>{h.seek=value}, saveSkipMarks:()=>{h.savedOutro=h.outroRemainingMs},
    switchEpisode:()=>{h.episodeIndex++;},
    player:{setSpeed:value=>{h.appliedSpeed=value}} });
  h.curMs = 550000;
  h.markOutroStart(true);
  assert.equal(h.savedOutro, 50000);
  assert.equal(h.autoOutro, true);
  assert.equal(h.episodeIndex, 1);
  h.durMs = 610000;
  h.applySkipMarks(559999); assert.equal(h.episodeIndex, 1);
  h.applySkipMarks(560000); assert.equal(h.episodeIndex, 2);
  h.beginTemporarySpeed(); assert.equal(h.appliedSpeed,2); assert.equal(h.speedIndex,3);
  h.endTemporarySpeed(); assert.equal(h.appliedSpeed,1.5); assert.equal(h.speedIndex,3);
  h.playing=false; h.beginTemporarySpeed(); assert.equal(h.temporarySpeed,false);
});

test('switching source at 10:00 skips missing episodes and seeks before playing', async () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Player.ets', 'utf8');
  const method = (name, next) => {
    const start = src.indexOf('  private ' + name);
    return src.slice(start, src.indexOf(next, start)).replace('private ', '');
  };
  const code = [
    method('openSourceSwitch()', '\n  /**'),
    method('keepRecoveryPosition()', '\n  private rejectRecoverySource'),
    method('async trySourceCandidates(', '\n  private findSourceByUrl'),
    method('markIntroEnd()', '\n  private shouldSkipIntroAtStartup'),
    method('shouldSkipIntroAtStartup()', '\n  private markOutroStart'),
    method('bindPlayerEvents(', '\n  private playPreparedVideo')
  ].join('\n');
  const js = ts.transpileModule('export class Harness {' + code + '}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS }
  }).outputText;
  const { matchEpisodeIndex } = load(fs.readFileSync('entry/src/main/ets/common/EpisodeMatch.ets', 'utf8'));
  const context = { exports: {}, matchEpisodeIndex, media: { SeekMode: { SEEK_CLOSEST: 2 } },
    hilog: { info: () => {} }, setTimeout: () => 1 };
  vm.runInNewContext(js, context);
  const player = new context.exports.Harness();
  const calls = [];
  const handlers = new Map();
  Object.assign(player, {
    title: 'Example', sourceUrl: 'primary', episodeIndex: 2,
    episodes: ['a1','a2','a3'], episodeLabels: ['第1集','第2集','第3集'], curMs: 600000, durMs: 1200000,
    recoveryPositionMs: 0, playerGeneration: 1, hudTimer: -1, restoringSource: null,
    session: { directCms: { shouldTryDirect: () => false }, api: { detail: async (id) => ({
      episodes: id === 'short' ? ['b1','b2','b4'] : ['trailer','b1','b2','b3'],
      episodeLabels: id === 'short' ? ['第1集','第2集','第4集'] : ['预告','EP01','EP02','EP03'],
      info: { cover: '' }
    }) } },
    findSourceByUrl: () => ({ enabled: true }),
    episodeSource: { setItems: () => {} }, setupPlayer: () => {},
    saveProgress: () => {}, switchToNextSource: () => { calls.push('lookup'); },
    accountQuota: () => {}, applyScale: () => {}, refreshTracks: () => {},
    canStartForQuota: () => true, playPreparedVideo: () => { calls.push('play'); },
    rejectRecoverySource: () => { calls.push('reject'); },
    canControl: () => true, saveSkipMarks: () => { calls.push('save marks'); },
    notify: () => {}, fmt: () => '',
    speeds: [1, 3, 4, 6, 7, 8], speedRates: [0.75, 1, 1.25, 1.5, 1.75, 2],
    updateBackgroundSession: () => { calls.push(player.effectiveSpeed); }
  });
  player.openSourceSwitch();
  assert.equal(player.recoveryPositionMs, 600000);
  assert.deepEqual(calls, ['lookup']);
  await player.trySourceCandidates([
    { name: 'Example', sourceUrl: 'short', vodId: 'short' },
    { name: 'Example', sourceUrl: 'backup', vodId: 'backup' }
  ], 1);
  assert.equal(player.sourceUrl, 'backup');
  assert.equal(player.episodeIndex, 3);
  assert.equal(player.episodes[player.episodeIndex], 'b3');
  assert.equal(player.recoveryPositionMs, 600000);

  player.bindPlayerEvents({
    duration: 1200000, setVolume: () => {}, on: (name, callback) => handlers.set(name, callback),
    seek: (time, mode) => { calls.push(['seek', time, mode]); }
  }, 1);
  handlers.get('speedDone')(6);
  assert.equal(calls.pop(), 1.5);
  handlers.get('speedDone')(8);
  assert.equal(calls.pop(), 2);
  handlers.get('speedDone')(6);
  assert.equal(calls.pop(), 1.5);
  handlers.get('stateChange')('prepared');
  assert.deepEqual(calls, ['lookup', ['seek', 600000, 2]]);
  handlers.get('seekDone')(0);
  assert.equal(calls.at(-1), 'reject');
  assert.equal(player.recoveryPositionMs, 600000);
  handlers.get('seekDone')(600000);
  assert.equal(calls.at(-1), 'play');
  assert.equal(player.curMs, 600000);
  assert.equal(player.recoveryPositionMs, 0);

  calls.length = 0;
  player.curMs = 71300;
  player.markIntroEnd();
  assert.deepEqual(calls, ['save marks']);
  assert.equal(player.introEndMs, 71300);
  assert.equal(player.autoIntro, true);
  player.curMs = 0;
  player.episodeIndex++;
  handlers.get('stateChange')('prepared');
  assert.deepEqual(calls, ['save marks', ['seek', 71300, 2]]);
  handlers.get('seekDone')(71300);
  assert.equal(player.curMs, 71300);
  assert.equal(calls.at(-1), 'play');
  player.resumeMs = 180000;
  player.resumeRequestedManually = true;
  assert.equal(player.shouldSkipIntroAtStartup(), false);
});

test('server search cancellation destroys the request and ignores its late response', async () => {
  const direct = fs.readFileSync('entry/src/main/ets/api/DirectCms.ets', 'utf8');
  const { SearchRequests } = load(direct);
  const src = fs.readFileSync('entry/src/main/ets/api/Api.ets', 'utf8');
  const method = src.slice(src.indexOf('  private async request('), src.indexOf('  private captureSessionCookie'));
  let complete;
  let destroyed = 0;
  const client = {
    request: () => new Promise(resolve => { complete = resolve; }),
    destroy: () => { destroyed++; }
  };
  const timeout = src.match(/^const CONNECT_TIMEOUT_MS = .*;$/m)[0];
  const body = "import { http } from '@kit.NetworkKit'; " + timeout +
    " export class Harness {" + method.replace('private ', '') + "}";
  const { Harness } = load(body, () => ({
    http: { createHttp: () => client, RequestMethod: { POST: 'POST' }, HttpDataType: { STRING: 'string' } }
  }));
  const requests = new SearchRequests();
  const harness = new Harness();
  harness.cookie = '';
  harness.baseUrl = 'https://example.test';
  harness.captureSessionCookie = () => { assert.fail('cancelled response updated cookie'); };
  const request = harness.request('/api/search', 'POST', '{}', 45000, requests);
  requests.cancel();
  complete({ responseCode: 200, result: '{}', header: { 'set-cookie': 'ltv_session=old' } });
  await assert.rejects(request, /搜索已取消/);
  assert.equal(destroyed, 1);
});

test('poster refresh keeps the same title image and tries alternates before refreshing the source', async () => {
  const src = fs.readFileSync('entry/src/main/ets/components/PosterImage.ets', 'utf8');
  const method = src.slice(src.indexOf('  private async loadPoster()'), src.indexOf('  aboutToDisappear()'));
  const code = "import { PosterCache } from './cache'; function getContext() {} " +
    "export class Harness {" + method.replace('private ', '') + "}";
  const bitmap = {};
  const lookups = [];
  const { Harness } = load(code, () => ({
    PosterCache: { get: async (_context, url) => {
      lookups.push(url);
      return url === 'fresh.jpg' ? bitmap : null;
    } }
  }));
  const poster = Object.assign(new Harness(), {
    active: true, loadGeneration: 0, url: 'expired.jpg', fallbackLabel: '第一部',
    displayedLabel: '第一部', displayedUrl: 'old.jpg', bitmap
  });
  await poster.loadPoster();
  assert.equal(poster.bitmap, bitmap);

  const stages = [];
  const recovered = [];
  poster.fallbackLabel = '第二部';
  poster.recoverPoster = async (refresh) => {
    stages.push(refresh);
    return [{ url: refresh ? 'fresh.jpg' : 'also-expired.jpg' }];
  };
  poster.onPosterRecovered = url => recovered.push(url);
  const job = poster.loadPoster();
  assert.equal(poster.bitmap, null);
  await job;
  assert.equal(poster.bitmap, bitmap);
  assert.deepEqual(stages, [false, true]);
  assert.deepEqual(lookups, ['expired.jpg', 'expired.jpg', 'also-expired.jpg', 'fresh.jpg']);
  assert.deepEqual(recovered, ['fresh.jpg']);
});

test('automatic next episode checkpoints history before startup and saves the new position once ready', () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Player.ets', 'utf8');
  const extract = (start, end) => src.slice(src.indexOf(start), src.indexOf(end)).replace('private ', '');
  const code = extract('  private switchEpisode(', '  private selectEpisode(') +
    extract('  private saveStartedEpisode()', '  private episodeTitle(');
  const { Harness } = load('export class Harness {' + code + '}');
  const writes = [];
  const player = Object.assign(new Harness(), {
    episodeIndex: 0, episodes: ['a','b'], curMs: 550000, durMs: 600000, player: {currentTime: 550000},
    rememberProgress: true, sourceUrl: 'source', playing: true, switching: false, restoringSource: null,
    writeProgress(position, duration) { writes.push([this.episodeIndex, position, duration]); },
    setupPlayer() { this.playing = false; this.switching = true; }
  });
  player.switchEpisode(1, true);
  player.saveProgress(true);
  assert.deepEqual(writes, [[1, 0, 0]]);
  Object.assign(player, { curMs: 71000, durMs: 612000, playing: true, switching: false });
  player.saveStartedEpisode();
  player.saveStartedEpisode();
  assert.deepEqual(writes, [[1, 0, 0], [1, 71000, 612000]]);
});

test('clear history only deletes records after explicit confirmation', async () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/History.ets', 'utf8');
  const method = src.slice(src.indexOf('  private async clearAll()'), src.indexOf('  private async resume('));
  let selected = 0;
  const code = "import { promptAction, Theme } from './ui'; export class Harness {" + method.replace('private ', '') + "}";
  const { Harness } = load(code, () => ({
    Theme: {}, promptAction: { showDialog: async () => ({index: selected}) }
  }));
  let deleted = 0;
  const page = Object.assign(new Harness(), {
    list: [{}], prefs: { clearHistory: async () => { deleted++; } },
    setList(value) { this.list = value; }
  });
  await page.clearAll();
  assert.equal(deleted, 0);
  selected = 1;
  await page.clearAll();
  assert.equal(deleted, 1);
  assert.equal(page.list.length, 0);
});

test('episode matching rejects ambiguous or unlabelled series and conflicting seasons', () => {
  const { matchEpisodeIndex } = load(fs.readFileSync('entry/src/main/ets/common/EpisodeMatch.ets', 'utf8'));
  assert.equal(matchEpisodeIndex(0, ['a','b'], ['第10集'], ['x','y'], ['EP10','第10集']), -1);
  assert.equal(matchEpisodeIndex(0, ['a','b'], [], ['x','y'], []), -1);
  assert.equal(matchEpisodeIndex(0, ['a','b'], ['S01E10'], ['x','y'], ['S02E10','S01E11']), -1);
});

test('media center enables only available episodes and skips ten seconds through the player gesture seek', () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Player.ets', 'utf8');
  const methods = src.slice(src.indexOf('  private syncBackgroundControls('),
    src.indexOf('  private refreshBackgroundArtwork(')) +
    src.slice(src.indexOf('  private seekTo('), src.indexOf('  private markIntroEnd('));
  const code = "import { deviceInfo, media } from './system'; export class Harness {" + methods.replaceAll('private ', '') + "}";
  const { Harness } = load(code, () => ({ deviceInfo: { sdkApiVersion: 26 }, media: { SeekMode: { SEEK_PREV_SYNC: 1 } } }));
  const handlers = new Map();
  const clicks = [];
  const seeks = [];
  let controls;
  const session = {
    on(name, handler) { handlers.set(name, handler); },
    off(name) { handlers.delete(name); },
    async setMediaCenterControlType(value) { controls = Array.from(value); }
  };
  const player = Object.assign(new Harness(), {
    episodeIndex: 0, episodes: ['a','b','c'], durMs: 120000,
    backgroundCanGoPrevious: false, backgroundCanGoNext: false,
    canControl: () => true, switchEpisode: delta => clicks.push(delta),
    player: { currentTime: 10000, seek: (position, mode) => seeks.push([position, mode]) }
  });
  player.syncBackgroundControls(session);
  assert.equal(handlers.has('playPrevious'), false);
  handlers.get('playNext')();
  assert.deepEqual(controls, ['rewind', 'fastForward', 'playNext']);

  player.episodeIndex = 1;
  player.syncBackgroundControls(session);
  assert.deepEqual(controls, ['rewind', 'fastForward', 'playPrevious', 'playNext']);
  handlers.get('playPrevious')();
  assert.deepEqual(clicks, [1, -1]);

  player.skipFromMediaCenter(1);
  player.skipFromMediaCenter(-1);
  player.seekFromMediaCenter(999999);
  assert.deepEqual(seeks, [[20000, 1], [0, 1], [119700, 1]]);
  player.player.currentTime = 45000;
  player.skipFromMediaCenter(-1);
  assert.deepEqual(seeks.at(-1), [35000, 1]);

  player.episodeIndex = 2;
  player.syncBackgroundControls(session);
  assert.equal(handlers.has('playNext'), false);
  player.switching = true;
  player.skipFromMediaCenter(1);
  assert.equal(seeks.length, 4);
});


test('a long stall switches source at the last position, while progress and pauses reset the wait', () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Player.ets', 'utf8');
  const extract = (name, end) => src.slice(src.indexOf('  private ' + name),
    src.indexOf('  private ' + end)).replace('private ', '');
  const methods = extract('checkPlaybackStall(', 'stopSaveTimer(') +
    extract('keepRecoveryPosition(', 'rejectRecoverySource(') +
    src.slice(src.indexOf('  private replacementFailureMessage('), src.indexOf('  /** 自愈全部失败')).replace('private ', '');
  const { Harness } = load('export class Harness {' + methods + '}');
  let switches = 0;
  const player = Object.assign(new Harness(), {
    playing: true, firstFrameSeen: true, durMs: 1200000, curMs: 600000,
    stallPositionMs: 600000, stallSince: 1000, errorMsg: '',
    recoveryPositionMs: 0, switchToNextSource: () => { switches++; }
  });
  assert.equal(player.checkPlaybackStall(19000), false);
  player.curMs += 1000;
  assert.equal(player.checkPlaybackStall(21000), false);
  player.playing = false;
  assert.equal(player.checkPlaybackStall(45000), false);
  player.playing = true;
  assert.equal(player.checkPlaybackStall(64000), false);
  assert.equal(player.checkPlaybackStall(65000), true);
  assert.equal(switches, 1);
  assert.equal(player.recoveryPositionMs, 601000);
  assert.equal(player.checkPlaybackStall(90000), false);

  assert.equal(player.replacementFailureMessage('无同一集'), '无同一集');
  player.replacementFailure = 'lookup';
  assert.match(player.replacementFailureMessage('无同一集'), /查询失败/);
  player.replacementFailure = 'play';
  assert.match(player.replacementFailureMessage('无同一集'), /无法播放/);
  player.replacementFailure = 'seek';
  assert.match(player.replacementFailureMessage('无同一集'), /无法跳到原进度/);
});

test('viewing backup merges without duplicates, preserves newer progress and excludes login data', async () => {
  const json = load(fs.readFileSync('entry/src/main/ets/api/JsonUtil.ets', 'utf8'));
  const { Prefs, entryFromStatus } = load(fs.readFileSync('entry/src/main/ets/store/Prefs.ets', 'utf8'),
    name => name.includes('JsonUtil') ? json : {});
  const make = () => {
    const prefs = new Prefs();
    const values = {};
    prefs.store = { getAll: async () => ({...values}), getSync: (k, d) => values[k] ?? d,
      hasSync: k => Object.hasOwn(values, k), deleteSync: k => { delete values[k]; },
      putSync: (k, value) => { values[k] = value; },
      put: async (k, value) => { values[k] = value; }, flush: async () => {} };
    return prefs;
  };
  const src = make();
  const dest = make();
  const server = 'https://server.test';
  const url = 'https://source.test/api';
  const old = entryFromStatus(server, url, 'id', '剧集', '', 1, 20, 12000, 100000);
  await src.saveWatch({ ...old, updatedAt: 1 });
  await src.toggleFavorite(old);
  await src.setCookie(server, 'secret-cookie');
  await src.setSkipMarks('剧集', {introEndMs:70000,outroStartMs:0,autoIntro:true,autoOutro:false,
    outroRemainingMs:0,outroReferenceMs:0});
  const text = await src.exportViewingBackup(server, [
    { name:'片源', url, detail:'', isAdult:false, enabled:false },
    { name:'私有源', url:'https://users.test/api?token=secret-token', detail:'', isAdult:false, enabled:true }
  ]);
  assert.ok(!text.includes('secret-cookie') && !text.includes('secret-token'));
  await dest.saveWatch({ ...old, positionMs: 99000, updatedAt: 2 });
  const original = await dest.store.getAll();
  const putSync = dest.store.putSync;
  dest.store.putSync = (key, value) => {
    if (key.startsWith('skip:')) { throw new Error('write failure'); }
    putSync(key, value);
  };
  await assert.rejects(dest.restoreViewingBackup(text, server, []), /已恢复原数据/);
  assert.deepEqual(await dest.store.getAll(), original);
  dest.store.putSync = putSync;
  let failFlush = true;
  dest.store.flush = async () => {
    if (failFlush) { failFlush = false; throw new Error('disk failure'); }
  };
  await assert.rejects(dest.restoreViewingBackup(text, server, []), /已恢复原数据/);
  assert.deepEqual(await dest.store.getAll(), original);
  assert.equal((await dest.getHistory())[0].positionMs, 99000);
  let sources = await dest.restoreViewingBackup(text, server, []);
  sources = await dest.restoreViewingBackup(text, server, sources);
  assert.equal(sources.length, 1);
  assert.equal(sources[0].enabled, false);
  assert.equal((await dest.getHistory())[0].positionMs, 99000);
  assert.equal((await dest.getFavorites()).length, 1);
  assert.equal((await dest.getSkipMarks('剧集')).introEndMs, 70000);
  const corrupted = JSON.parse(text);
  corrupted.marks[0].marks.introEndMs = 'invalid';
  await assert.rejects(dest.restoreViewingBackup(JSON.stringify(corrupted), server, sources), /跳过时间无效/);
  assert.equal((await dest.getHistory()).length, 1);
});

test('live source preference only restores a working line of the selected channel', async () => {
  const src = fs.readFileSync('entry/src/main/ets/store/LiveLocal.ets', 'utf8');
  const { LiveLocal } = load(src, name => name.includes('LivePlaylist') ? { liveChannelKey: name => name } : {});
  const values = {};
  const prefs = { getRaw: (key, fallback) => values[key] ?? fallback,
    putRaw: async (key, value) => { values[key] = value; } };
  await LiveLocal.rememberLine(prefs, 'CCTV1', 'backup');
  assert.equal(LiveLocal.preferredIndex(prefs, ['first','backup','other'], ['CCTV1','CCTV1','CCTV2'], 0), 1);
  assert.equal(LiveLocal.preferredIndex(prefs, ['first','backup'], ['CCTV1','CCTV2'], 0), 0);
});


test('source lookup and failed candidates share one deadline and restore the original episode', async () => {
  const src = fs.readFileSync('entry/src/main/ets/pages/Player.ets', 'utf8');
  const section = (start, end) => src.slice(src.indexOf('  private ' + start), src.indexOf('  private ' + end));
  const js = ts.transpileModule('export class Harness {' +
    section('async switchToNextSource(', 'async findReplacementSource(') +
    section('finishHealFail(', 'stopStartupTimer(') + '}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const deadlines = [];
  const clears = [];
  const context = { exports: {}, SearchRequests: class { cancel() { this.cancelled = true; } },
    setTimeout: (callback, ms) => deadlines.push({ callback, ms }),
    clearTimeout: id => clears.push(id) };
  vm.runInNewContext(js, context);
  const player = new context.exports.Harness();
  const original = ['a1', 'a2'];
  let releaseNext;
  let setupCount = 0;
  Object.assign(player, {
    sourceUrl: 'primary', vodId: 'primaryId', episodes: original, episodeLabels: ['第1集', '第2集'],
    episodeIndex: 1, cover: 'primary.jpg', durMs: 1200000, recoveryPositionMs: 600000,
    usePlainUrl: false, isPaused: true, sourceLookup: null, sourceSwitch: null, playerGeneration: 1,
    keepRecoveryPosition: () => {}, writeProgress: () => {}, stopStartupTimer: () => {}, stopSaveTimer: () => {},
    stopBackgroundTask: () => {}, releasePlayer: () => {}, notify: () => {},
    episodeSource: { setItems: () => {} },
    setupPlayer: () => { setupCount++; },
    findReplacementSource: async () => {}
  });
  await player.switchToNextSource(true);
  Object.assign(player, {
    sourceUrl: 'bad', vodId: 'badId', episodes: ['b1'], episodeLabels: [], episodeIndex: 0,
    cover: 'bad.jpg', recoveryPositionMs: 0, replacementNeedsProgress: true,
    findReplacementSource: () => new Promise(resolve => { releaseNext = resolve; })
  });
  const lookup = player.switchToNextSource();
  const request = player.sourceLookup;
  assert.deepEqual(deadlines.map(d => d.ms), [24000]);
  deadlines[0].callback();
  assert.equal(request.cancelled, true);
  assert.deepEqual(clears, [1]);
  assert.equal(player.sourceUrl, 'primary');
  assert.equal(player.vodId, 'primaryId');
  assert.equal(player.episodes, original);
  assert.equal(player.episodeIndex, 1);
  assert.equal(player.recoveryPositionMs, 600000);
  assert.equal(player.restoringSource.paused, true);
  assert.equal(setupCount, 1);
  assert.equal(player.failRestoredSource(), true);
  assert.equal(player.failRestoredSource(), false);
  assert.match(player.errorMsg, /已保留进度/);
  releaseNext();
  await lookup;
  assert.equal(player.sourceLookup, null);
  assert.equal(setupCount, 1);
});

test('HAP updater reuses verified files and removes old or partial packages after a verified download', async () => {
  const { createHash } = require('node:crypto');
  const root = 'fake/update/';
  const name = tag => root + 'ShiguangCinema-HarmonyOS-' + tag + '-unsigned.hap';
  const bytes = Buffer.alloc(70000, 1);
  bytes.set([0x50, 0x4b, 3, 4]);
  bytes.fill(0, bytes.length - 22);
  bytes.set([0x50, 0x4b, 5, 6], bytes.length - 22);
  const digest = 'sha256:' + createHash('sha256').update(bytes).digest('hex');
  const old = name('v1.5.5.16');
  const out = name('v1.5.5.17');
  const stalePart = name('v1.5.5.15') + '.part';
  const files = new Map([[old, bytes], [stalePart, bytes.subarray(0, 100)], [root + 'unrelated', bytes]]);
  let downloads = 0;
  let transfer = bytes.subarray(0, 100);
  const fileIo = {
    OpenMode: { READ_ONLY: 0 }, WhenceType: { SEEK_SET: 0 }, access: async () => true,
    open: async path => ({ fd: { path, offset: 0 } }), close: async () => {},
    lseek: (fd, offset) => { fd.offset = offset; },
    stat: async path => ({ size: files.get(path).length }),
    read: async (fd, buffer) => {
      const chunk = files.get(fd.path).subarray(fd.offset, fd.offset + buffer.byteLength);
      new Uint8Array(buffer).set(chunk);
      fd.offset += chunk.length;
      return chunk.length;
    },
    listFile: async () => [...files.keys()].map(path => path.slice(root.length)),
    unlink: async path => { files.delete(path); },
    rename: async (from, to) => { files.set(to, files.get(from)); files.delete(from); }
  };
  const request = { downloadFile: async (ctx, options) => {
    downloads++;
    files.set(options.filePath, transfer);
    return { on: (event, cb) => { if (event === 'complete') { queueMicrotask(cb); } } };
  } };
  const cryptoFramework = { createMd: () => {
    const hash = createHash('sha256');
    return { update: async blob => { hash.update(blob.data); }, digest: async () => ({ data: hash.digest() }) };
  } };
  const { downloadUpdateFile, findDownloadedUpdate } = load(
    fs.readFileSync('entry/src/main/ets/api/UpdateDownloader.ets', 'utf8'),
    name => name === '@kit.CoreFileKit' ? { fileIo } :
      name === '@kit.BasicServicesKit' ? { request } : { cryptoFramework });
  const context = { filesDir: 'fake' };
  const info = { tag: 'v1.5.5.17', url: 'https://github.com/asset', size: bytes.length, digest };
  assert.equal(await findDownloadedUpdate(context, { ...info, tag: 'v1.5.5.16', size: 0, digest: '' }), old);
  assert.equal((await downloadUpdateFile(context, info, () => {})).ok, false);
  assert.equal(files.has(out + '.part'), false);
  assert.equal(files.has(old), true);
  transfer = Buffer.from(bytes);
  transfer[66000] ^= 1;
  assert.equal((await downloadUpdateFile(context, info, () => {})).ok, false);
  transfer = bytes;
  const first = downloadUpdateFile(context, info, () => {});
  const second = downloadUpdateFile(context, info, () => {});
  assert.equal((await first).path, out);
  assert.equal((await second).path, out);
  assert.equal(files.has(stalePart), false);
  assert.equal(files.has(old), false);
  assert.equal(files.has(root + 'unrelated'), true);
  assert.equal(await findDownloadedUpdate(context, info), out);
  assert.equal((await downloadUpdateFile(context, info, () => {})).path, out);
  assert.equal(downloads, 3);
});
