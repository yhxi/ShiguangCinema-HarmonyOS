const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('E:/Development/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

function compile(path) {
  const source = fs.readFileSync(path, 'utf8');
  return ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
}

function load(path, extraRequire) {
  const context = { exports: {}, require: extraRequire || (() => ({})), console };
  vm.runInNewContext(compile(path), context);
  return context.exports;
}

/* ---------------------------------------------------------------- 直播频道表 */

const live = load('entry/src/main/ets/api/LivePlaylist.ets');

// M3U：引号里的逗号不算分隔符，EXTINF 属性要能取到分组与台标
const m3u = [
  '#EXTM3U',
  '#EXTINF:-1 tvg-name="CCTV1" tvg-logo="http://logo/1.png" group-title="央视",CCTV-1 综合, 高清',
  'http://a.example/cctv1.m3u8',
  '#EXTINF:-1 group-title="卫视",湖南卫视',
  '#EXTVLCOPT:http-user-agent=Mozilla/5.0 Test',
  'http://a.example/hunan.m3u8',
  '#EXTINF:-1,测试台',
  'rtmp://bad.example/live',
  '#KODIPROP:inputstream=adaptive',
  'ftp://bad.example/x'
].join('\n');

const report = live.inspectLocalLivePlaylist(m3u);
assert.equal(report.channels.length, 2);
assert.equal(report.channels[0].name, 'CCTV-1 综合, 高清');
assert.equal(report.channels[0].group, '央视');
assert.equal(report.channels[1].headers, 'User-Agent: Mozilla/5.0 Test');
assert.equal(report.unsupportedDirectives, 1);
// rtmp 地址与不认识的 ftp 行都不该进频道表
assert.equal(report.skipped, 2);

// TXT：#genre# 切换分组，同名频道保留为不同线路
const txt = [
  '央视频道,#genre#',
  'CCTV5,http://b.example/5.m3u8',
  'CCTV5+,http://b.example/5p.m3u8',
  'CCTV1,http://b.example/1.m3u8',
  '地方台,#genre#',
  '北京卫视,http://b.example/bj.m3u8',
  '坏行没有逗号'
].join('\n');
const txtReport = live.inspectLocalLivePlaylist(txt);
assert.equal(txtReport.channels.length, 4);
assert.equal(txtReport.skipped, 1);
assert.equal(txtReport.channels[1].group, '央视频道');

// 排序：央视编号在前（5 与 5+ 不合并），地方台其次
const sorted = live.sortedLiveChannels(txtReport.channels);
// 跨 vm 上下文的数组原型不同，deepEqual 会误判，这里比 JSON
assert.equal(JSON.stringify(sorted.map((c) => c.name)), JSON.stringify(['CCTV1', 'CCTV5', 'CCTV5+', '北京卫视']));
assert.equal(live.defaultLiveChannelIndex(sorted), 0);

// 同名频道（去掉画质后缀）指向同一台，换台按下标循环
assert.equal(live.liveChannelKey('CCTV5+'), live.liveChannelKey('CCTV5+ 高清'));
assert.notEqual(live.liveChannelKey('CCTV5'), live.liveChannelKey('CCTV5+'));
assert.equal(live.isCctvOne('央视一套'), true);
assert.equal(live.stepLiveChannel(0, -1, 3), 2);
assert.equal(live.stepLiveChannel(2, 1, 3), 0);

/* ---------------------------------------------------------------- 儿童额度 */

const catalog = load('entry/src/main/ets/api/ChildrenCatalog.ets');
const quotaModule = load('entry/src/main/ets/store/ChildrenQuota.ets', (name) => {
  if (name.includes('ChildrenCatalog')) { return catalog; }
  return {};
});

assert.equal(catalog.ChildrenCatalog.sections().length, 3);
const titles = catalog.ChildrenCatalog.allTitles();
assert.ok(titles.length >= 90, `目录应有约 100 部，实际 ${titles.length}`);
assert.equal(new Set(titles).size, titles.length);

// 分季、番外、语言版本都归到同一部作品
const key = quotaModule.childQuotaKey;
assert.equal(key('小猪佩奇 第二季'), key('小猪佩奇'));
assert.equal(key('小猪佩奇 番外篇'), key('小猪佩奇'));
assert.equal(key('熊出没 普通话版'), key('熊出没'));

const stored = new Set(['小猪佩奇', '开心超人联盟']);
const matches = quotaModule.matchesChildQuotaTitle;
assert.equal(matches('小猪佩奇 第 3 季', stored), true);
assert.equal(matches('开心超人联盟之星际联盟', stored), true, '系列副标题应视为同一部');
assert.equal(matches('小猪佩奇过大年', stored), false, '无分隔符的独立续作不算同一部');
assert.equal(matches('海底小纵队', stored), false);

// 家长验证：题面是两个 2–9 的大写数字，答案等于乘积
for (let i = 0; i < 40; i++) {
  const challenge = quotaModule.makeParentChallenge();
  // 汉字没有连续码位，不能用区间；这里逐个列出
  assert.match(challenge.question, /^[壹贰叁肆伍陆柒捌玖] × [壹贰叁肆伍陆柒捌玖] = \?$/u);
  assert.ok(challenge.answer >= 4 && challenge.answer <= 81);
}
assert.equal(quotaModule.parseParentAnswer('42'), 42);
assert.equal(quotaModule.parseParentAnswer(''), -1);

console.log('PASS: 直播解析/排序 + 儿童额度匹配回归');
