const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('E:/Development/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/pages/VideoLayout.ets', 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const ctx = { exports: {} }; vm.runInNewContext(js, ctx);
const fit = ctx.exports.fitVideoFrame;
const near = (actual, expected) => assert.ok(Math.abs(actual - expected) < 0.001, `${actual} != ${expected}`);
for (const [vw, vh, mw, mh] of [[800, 360, 1920, 1080], [360, 800, 1920, 1080], [800, 360, 1920, 816], [360, 800, 1080, 1920], [600, 600, 1280, 720]]) {
 const r = fit(vw, vh, mw, mh);
 assert.ok(r.width <= vw && r.height <= vh, 'video must fit in viewport');
 near(r.width / r.height, mw / mh);
 assert.ok(Math.abs(r.width - vw) < .001 || Math.abs(r.height - vh) < .001, 'one edge must touch viewport');
}
const cropped = fit(800,360,1920,1080,true); near(cropped.width,800);near(cropped.height,360);
const noMetadata=fit(360,800,0,0);near(noMetadata.width/noMetadata.height,16/9);
for (const [w,h] of [[0,800],[800,0],[NaN,400]]) { const r=fit(w,h,16,9);assert.equal(r.width,0);assert.equal(r.height,0); }
console.log('PASS: 10 video geometry cases (landscape, portrait, ultrawide, crop and invalid sizes)');
