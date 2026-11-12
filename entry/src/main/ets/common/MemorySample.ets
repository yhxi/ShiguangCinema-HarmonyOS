import { hidebug } from '@kit.PerformanceAnalysisKit';

export interface MemorySample {
  pss: number; rss: number; vss: number; privateKb: number;
  nativeTotal: number; nativeUsed: number;
  systemTotal: number; systemAvailable: number;
  sampledAt: number;
}

/** Runs on taskpool: smaps_rollup can be expensive on the UI thread. */
@Concurrent
export function sampleMemory(): MemorySample {
  const result: MemorySample = { pss: -1, rss: -1, vss: -1, privateKb: -1,
    nativeTotal: -1, nativeUsed: -1, systemTotal: -1, systemAvailable: -1, sampledAt: 0 };
  try {
    const info = hidebug.getAppNativeMemInfo();
    result.pss = Number(info.pss);
    result.rss = Number(info.rss);
    result.vss = Number(info.vss);
    result.privateKb = Number(info.privateDirty) + Number(info.privateClean);
  } catch (e) { /* This group remains unavailable. */ }
  try {
    result.nativeTotal = Number(hidebug.getNativeHeapSize());
    result.nativeUsed = Number(hidebug.getNativeHeapAllocatedSize());
  } catch (e) { result.nativeTotal = -1; result.nativeUsed = -1; }
  try {
    const info = hidebug.getSystemMemInfo();
    result.systemTotal = Number(info.totalMem);
    result.systemAvailable = Number(info.availableMem);
  } catch (e) { result.systemTotal = -1; result.systemAvailable = -1; }
  result.sampledAt = Date.now();
  return result;
}
