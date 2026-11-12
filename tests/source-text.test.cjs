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

const context = { exports: {}, require: () => ({}), console };
vm.runInNewContext(compile('entry/src/main/ets/common/SourceText.ets'), context);
const src = context.exports;

// 常规「名称,网址」与中文逗号
let parsed = src.parseSourceLines('虎牙,https://www.huyaapi.com/api.php/provide/vod/from/hym3u8\n火狐,https://hhzyapi.com/api.php/provide/vod');
assert.equal(parsed.length, 2);
assert.equal(parsed[0].name, '虎牙');
assert.equal(parsed[0].url, 'https://www.huyaapi.com/api.php/provide/vod/from/hym3u8');
assert.equal(parsed[1].name, '火狐');

// 中文逗号
parsed = src.parseSourceLines('非凡(ffzy5)，http://ffzy5.tv/api.php/provide/vod');
assert.equal(parsed.length, 1);
assert.equal(parsed[0].name, '非凡(ffzy5)');

// 倒序「地址,名称」
parsed = src.parseSourceLines('https://example.com/api.php,我的源');
assert.equal(parsed.length, 1);
assert.equal(parsed[0].url, 'https://example.com/api.php');
assert.equal(parsed[0].name, '我的源');

// 裸网址：名称兜底为主机名
parsed = src.parseSourceLines('https://a.b/c/d');
assert.equal(parsed.length, 1);
assert.equal(parsed[0].name, 'a.b');
assert.equal(src.hostLabelOf('https://a.b/c/d'), 'a.b');

// 注释行、空行、非 http 行都要跳过
parsed = src.parseSourceLines('# 这是注释\n\n名称没有网址\nhttps://ok.example/vod\nftp://bad.example/x');
assert.equal(parsed.length, 1);
assert.equal(parsed[0].url, 'https://ok.example/vod');

// 按地址去重（尾部斜杠不敏感）
parsed = src.parseSourceLines('A,https://x.example/api/\nB,https://x.example/api');
assert.equal(parsed.length, 1);
assert.equal(parsed[0].name, 'A');

// 名称超长截断到 24 字符
parsed = src.parseSourceLines('这个名称实在是太长太长太长太长太长太长了,https://long.example/vod');
assert.ok(parsed[0].name.length <= 24);

// 空输入
assert.equal(src.parseSourceLines('   ').length, 0);

console.log('PASS: 片源批量文本解析回归');
