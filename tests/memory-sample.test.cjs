const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('E:/Development/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
function load(hidebug) {
  const source = fs.readFileSync('entry/src/main/ets/common/MemorySample.ets', 'utf8').replace('@Concurrent', '');
  const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const context = { exports: {}, require: () => ({ hidebug }), Date };
  vm.runInNewContext(js, context); return context.exports;
}
test('memory sampling keeps units and partial failures independent', () => {
  const h = { getAppNativeMemInfo: () => ({ pss: 1536n, rss: 2048n, vss: 4096n, privateDirty: 128n, privateClean: 64n }),
    getNativeHeapSize: () => 1048576n, getNativeHeapAllocatedSize: () => 524288n,
    getSystemMemInfo: () => ({ totalMem: 8192n, availableMem: 4096n }) };
  const { sampleMemory } = load(h);
  const a = sampleMemory();
  assert.equal(a.pss, 1536); assert.equal(a.privateKb, 192); assert.equal(a.nativeUsed, 524288);
  assert.equal(a.systemAvailable, 4096); assert.ok(a.sampledAt > 0);
  h.getAppNativeMemInfo = () => { throw Error('unavailable'); };
  const b = sampleMemory();
  assert.equal(b.pss, -1); assert.equal(b.rss, -1); assert.equal(b.systemTotal, 8192);
  h.getNativeHeapAllocatedSize = () => { throw Error('unavailable'); };
  const c = sampleMemory();
  assert.equal(c.nativeUsed, -1); assert.equal(c.nativeTotal, -1);
});
