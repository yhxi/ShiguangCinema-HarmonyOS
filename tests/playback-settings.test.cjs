const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('E:/Development/command-line-tools/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const data = new Map();
const fakeStore = { getSync: (key, fallback) => data.has(key) ? data.get(key) : fallback,
 put: async (key, value) => { data.set(key, value); }, flush: async () => {} };
function load(file) {
 const source = fs.readFileSync(file, 'utf8');
 const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
 const context = { exports: {}, require: name => {
   if (name === '@kit.ArkData') return { preferences: { getPreferences: async () => fakeStore } };
   if (name.endsWith('/JsonUtil')) return load('entry/src/main/ets/api/JsonUtil.ets');
   throw new Error(`Unexpected dependency: ${name}`);
 }};
 vm.runInNewContext(compiled.outputText, context);return context.exports;
}
(async () => {
 const { Prefs } = load('entry/src/main/ets/store/Prefs.ets');const prefs = await Prefs.get({});
 let settings = await prefs.getPlaybackSettings();
 assert.equal(settings.seekStepSeconds,10);assert.equal(settings.rememberProgress,true);assert.equal(settings.resumeThresholdSeconds,5);
 data.set('playbackSettings',JSON.stringify({speedIndex:3,autoNext:false,cropVideo:true}));
 settings=await prefs.getPlaybackSettings();assert.equal(settings.speedIndex,3);assert.equal(settings.autoNext,false);assert.equal(settings.seekStepSeconds,10);assert.equal(settings.rememberProgress,true);
 settings.seekStepSeconds=30;settings.rememberProgress=false;settings.resumeThresholdSeconds=60;
 await prefs.setPlaybackSettings(settings);settings=await prefs.getPlaybackSettings();
 assert.equal(settings.seekStepSeconds,30);assert.equal(settings.rememberProgress,false);assert.equal(settings.resumeThresholdSeconds,60);
 data.set('playbackSettings',JSON.stringify({seekStepSeconds:999,resumeThresholdSeconds:-10}));
 settings=await prefs.getPlaybackSettings();assert.equal(settings.seekStepSeconds,60);assert.equal(settings.resumeThresholdSeconds,0);
 let marks=await prefs.getSkipMarks('Example');assert.equal(marks.introEndMs,90000);assert.equal(marks.autoIntro,false);
 marks.introEndMs=60000;marks.autoIntro=true;await prefs.setSkipMarks('Example',marks);
 marks=await prefs.getSkipMarks(' example ');assert.equal(marks.introEndMs,60000);assert.equal(marks.autoIntro,true);
 console.log('PASS: settings defaults, upgrade migration, persistence, validation and per-title skip marks');
})().catch(error => { console.error(error);process.exitCode=1; });
