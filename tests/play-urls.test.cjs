const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('E:/Development/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/api/PlayUrls.ets', 'utf8');
const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
const context = { exports: {} };
vm.runInNewContext(output.outputText, context);
const parse = context.exports.parsePlayUrls;
const check = (raw, labels, expected) => assert.deepEqual(Array.from(parse(raw, labels)), expected);
// Provider regression: first line is an HTML player, second is native HLS.
check('01$https://play.example/play/abc$$$01$https://play.example/play/abc/index.m3u8',
  'hhyun$$$hhm3u8', ['https://play.example/play/abc/index.m3u8']);
check('01$https://cdn.example/share/abc$$$01$https://cdn.example/20261016/a/index.m3u8?sign=test',
  'liangzi$$$lzm3u8', ['https://cdn.example/20261016/a/index.m3u8?sign=test']);
// Missing labels must still prefer native media, and preserve episode order.
check('01$https://cdn.example/share/a#02$https://cdn.example/share/b$$$01$https://cdn.example/a.m3u8#02$https://cdn.example/b.m3u8',
  '', ['https://cdn.example/a.m3u8', 'https://cdn.example/b.m3u8']);
// Single-line media providers and signed URLs remain intact.
check('01$https://cdn.example/a.m3u8?token=a$b#02$https://cdn.example/b.mp4', '',
  ['https://cdn.example/a.m3u8?token=a$b', 'https://cdn.example/b.mp4']);
// Explicit media label handles native endpoints without file extensions.
check('01$https://cdn.example/share/a$$$01$https://cdn.example/stream/a', 'web$$$m3u8',
  ['https://cdn.example/stream/a']);
check('', '', []);
check('01$javascript:alert(1)$$$01$https://cdn.example/a.mp4', '', ['https://cdn.example/a.mp4']);
console.log('PASS: 7 playback-line regression cases');
// Optional real provider fixtures, used by tools/probe-playback.py.
if (process.argv[2]) {
 const fixture = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
 const selected = parse(fixture.raw, fixture.labels);
 fs.writeFileSync(process.argv[3], JSON.stringify(Array.from(selected)));
}
