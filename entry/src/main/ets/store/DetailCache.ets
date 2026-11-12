import { Detail } from '../api/Models';
export interface DetailCacheEntry { detail: Detail; at: number; }
export const DETAIL_CACHE_TTL_MS = 10 * 60 * 1000;
export const DETAIL_CACHE: Map<string, DetailCacheEntry> = new Map();
let cacheGeneration: number = 0;
export function detailCacheGeneration(): number { return cacheGeneration; }
export function clearDetailCache(): void { cacheGeneration++; DETAIL_CACHE.clear(); }
