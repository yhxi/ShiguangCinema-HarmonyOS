const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const nodeUtil = require('node:util');
const ts = require('E:/Development/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

function compile(path) {
  const source = fs.readFileSync(path, 'utf8');
  return ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
}

function load(path, extraRequire) {
  const context = { exports: {}, require: extraRequire || (() => ({})), console, setTimeout, clearTimeout };
  vm.runInNewContext(compile(path), context);
  return context.exports;
}

/* ---------------------------------------------------------------- 文本清洗 */

const text = load('entry/src/main/ets/common/TextClean.ets');

assert.equal(text.stripHtml('<p>一个&nbsp;简介</p><br/>换行'), '一个 简介 换行');
assert.equal(text.stripHtml('&amp;&lt;&gt;'), '&<>');
assert.equal(text.stripHtml(''), '');

// 括号注记、年份、副标题都是采集站匹配不上的噪声
assert.equal(text.cleanKeyword('流浪地球（2023）'), '流浪地球');
assert.equal(text.cleanKeyword('名侦探柯南：万圣节的新娘'), '名侦探柯南 万圣节的新娘');
assert.equal(text.cleanKeyword('[修复版] 三体'), '三体');
assert.equal(text.cleanKeyword('   '), '');

assert.equal(text.normalizeTitle('海贼王 · 更新至 1000 集'), '海贼王更新至1000集');
assert.equal(text.normalizeTitle('ＳＰＹ'), 'ｓｐｙ');

// 同一季归一：全角/阿拉伯数字、语言版本都算同一部；跨季不算
assert.equal(text.sourceTitleKey('海贼王 第二季'), text.sourceTitleKey('海贼王 第2季'));
assert.equal(text.sourceTitleKey('熊出没 普通话版'), text.sourceTitleKey('熊出没'));
assert.notEqual(text.sourceTitleKey('斗罗大陆 第二季'), text.sourceTitleKey('斗罗大陆'));
assert.equal(text.sourceTitleKey('庆余年 第二十季'), text.sourceTitleKey('庆余年 第20季'));

// 排序权重：完全同名 > 包含关键词 > 其他
assert.equal(text.searchTitleRank('流浪地球', '流浪地球'), 0);
assert.equal(text.searchTitleRank('流浪地球 2', '流浪地球'), 1);
assert.equal(text.searchTitleRank('三体', '流浪地球'), 2);
assert.equal(text.searchTitleRank('三体', ''), 2);

// 首字母匹配：前缀命中，或两个字母以上放宽容错
assert.equal(text.matchesInitials('cjqc', 'cj'), true);
assert.equal(text.matchesInitials('cjqc', 'qc'), true);
assert.equal(text.matchesInitials('cjqc', 'x'), false);
assert.equal(text.matchesInitials('', 'cj'), false);

/* ---------------------------------------------------------------- 拼音首字母 */

const pinyin = load('entry/src/main/ets/api/PinyinInitials.ets', (name) => {
  if (name === '@kit.ArkTS') {
    return {
      util: {
        TextDecoder: {
          create: (encoding) => ({
            decodeToString: (bytes) => new nodeUtil.TextDecoder(encoding).decode(Buffer.from(bytes))
          })
        }
      }
    };
  }
  return {};
});

assert.equal(pinyin.PinyinInitials.initialsOf('超级汽车'), 'cjqc');
assert.equal(pinyin.PinyinInitials.initialsOf('仙逆'), 'xn');
assert.equal(pinyin.PinyinInitials.initialsOf('海贼王'), 'hzw');
assert.equal(pinyin.PinyinInitials.initialsOf('浙江卫视'), 'zjws');
// ASCII 原样保留，标点跳过
assert.equal(pinyin.PinyinInitials.initialsOf('超级宝贝JOJO'), 'cjbbjojo');
// 生僻字/日文假名不在 GB2312 常用字区，返回空串而不是乱码
assert.equal(pinyin.PinyinInitials.initialsOf('あ'), '');
assert.equal(pinyin.PinyinInitials.isAvailable(), true);

/* ---------------------------------------------------------------- 选集缓存 */

const episode = load('entry/src/main/ets/store/EpisodeCache.ets');

const key = episode.episodeCacheKey('https://tv.example/', 'https://api.example/', '12345');
assert.equal(key, 'https://tv.example|https://api.example|12345');

const now = Date.now();
const good = { urls: ['u1', 'u2', 'u3'], ts: now, first: 'u1', last: 'u3' };
assert.equal(episode.episodeRecordUsable(good, '', now), true);
assert.equal(episode.episodeRecordUsable(good, 'u2', now), true);
assert.equal(episode.episodeRecordUsable({ ...good, last: 'wrong' }, '', now), false);
// 正在播的地址不在列表里 = 片源换了线路，缓存作废
assert.equal(episode.episodeRecordUsable(good, 'u9', now), false);
// 超过 7 天
assert.equal(episode.episodeRecordUsable({ urls: ['u1', 'u2'], ts: now - 8 * 24 * 3600 * 1000, first: 'u1', last: 'u2' }, '', now), false);
// 首集对不上 = 整季换了版本
assert.equal(episode.episodeRecordUsable({ urls: ['u1', 'u2'], ts: now, first: 'u0', last: 'u2' }, '', now), false);
// 只有一集的多半是详情接口只回了半截，不当缓存用
assert.equal(episode.episodeRecordUsable({ urls: ['u1'], ts: now, first: 'u1', last: 'u1' }, '', now), false);
assert.equal(episode.episodeRecordUsable(undefined, '', now), false);

// 淘汰：先砍过期，再按写入时间砍到 40 部
const records = new Map();
for (let i = 0; i < 45; i++) {
  records.set(`k${i}`, { urls: ['a', 'b'], ts: now - i * 1000, first: 'a', last: 'b' });
}
records.set('expired', { urls: ['a', 'b'], ts: now - 9 * 24 * 3600 * 1000, first: 'a', last: 'b' });
episode.pruneEpisodeRecords(records, now);
assert.equal(records.has('expired'), false, '过期条目应被清掉');
assert.equal(records.size, 40);
assert.equal(records.has('k0'), true, '最新的应保留');
assert.equal(records.has('k44'), false, '最旧的应被淘汰');

console.log('PASS: 文本清洗/拼音首字母/选集缓存回归');
