const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('E:/Development/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
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
  const { SearchHarness } = load(`export class SearchHarness { ${method} }`);
  const calls = [];
  const h = new SearchHarness();
  h.searchGeneration = 1; h.groups = []; h.freshResults = []; h.refreshFailed = false; h.applyIncoming = () => {};
  h.session = {
    enabledSources: () => [{url: 'server'}, {url: 'direct-ok'}, {url: 'direct-fail'}],
    directCms: { shouldTryDirect: s => s.url.startsWith('direct'),
      search: async s => { if (s.url === 'direct-fail') throw new Error('offline'); return []; } },
    api: { search: async (_, sources) => { calls.push(sources.map(s => s.url)); return {items: []}; } }
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
  const first = p.saveWatch(entry(0, 100));
  const second = p.saveWatch(entry(1, 5));
  await tick(); assert.equal(writes.length, 1); assert.equal(writes[0].list[0].episodeIndex, 0);
  release.shift()(); await tick(); assert.equal(writes.length, 2); assert.equal(writes[1].list[0].episodeIndex, 1);
  release.shift()(); await Promise.all([first, second]);
  assert.equal((await p.getHistory())[0].episodeIndex, 1);
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
  const episodeCache = {get: () => ['first', 'second'], put: () => {}};
  const { resumePlaybackParams } = load(source, name => name.includes('EpisodeCache') ? { EpisodeCache: episodeCache } : {});
  const session = {serverUrl:'https://server', sources: [], api:{detail: async () => {networkCalls++;}}, directCms: {}};
  const entry = {serverUrl:'https://server', sourceUrl:'https://source', vodId:'1', episodeIndex:1, positionMs:42420, title:'剧', cover:'pic'};
  const p = await resumePlaybackParams({}, entry, session);
  assert.equal(p.index, '1'); assert.equal(p.resumeMs, '42420'); assert.equal(p.forceResume, '1');
  assert.deepEqual(JSON.parse(p.episodes), ['first', 'second']); assert.equal(networkCalls, 0);
  session.serverUrl = 'https://other';
  await assert.rejects(resumePlaybackParams({}, entry, session), /其他服务端/);
});

test('recent viewing fetches missing episodes and reports unavailable saved episode', async () => {
  const source = fs.readFileSync('entry/src/main/ets/common/ResumePlayback.ets', 'utf8');
  const episodeCache = {get: () => null, put: () => {}};
  const { resumePlaybackParams } = load(source, name => name.includes('EpisodeCache') ? { EpisodeCache: episodeCache } : {});
  const entry = {serverUrl:'s', sourceUrl:'src', vodId:'1', episodeIndex:1, positionMs:100, title:'剧', cover:''};
  const session = {serverUrl:'s', sources:[{url:'src'}], directCms:{shouldTryDirect: () => true, detail: async () => {throw Error('unavailable');}},
    api:{detail: async () => ({episodes:['first', 'second']})}};
  const p = await resumePlaybackParams({}, entry, session);
  assert.equal(p.index, '1'); assert.equal(p.resumeMs, '100');
  session.api.detail = async () => ({episodes:['first']});
  await assert.rejects(resumePlaybackParams({}, entry, session), /集数已不可用/);
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
