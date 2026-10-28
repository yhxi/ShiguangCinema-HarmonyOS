/**
 * JSON 取值辅助 —— ArkTS 严格模式下安全解析服务端 JSON。
 * JSON.parse 返回 Object，用这些函数按类型安全取值，等价于 Kotlin 的 optString/optBoolean。
 */

export type JsonObj = Record<string, Object>;

export function asObj(v: Object | undefined | null): JsonObj | null {
  if (v === undefined || v === null) {
    return null;
  }
  if (typeof v === 'object' && !Array.isArray(v)) {
    return v as JsonObj;
  }
  return null;
}

export function asArr(v: Object | undefined | null): Object[] | null {
  if (v === undefined || v === null) {
    return null;
  }
  if (Array.isArray(v)) {
    return v as Object[];
  }
  return null;
}

export function s(v: Object | undefined | null, def: string = ''): string {
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'number') {
    return (v as number).toString();
  }
  return def;
}

export function n(v: Object | undefined | null, def: number = 0): number {
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const parsed = parseFloat(v as string);
    if (!isNaN(parsed)) {
      return parsed;
    }
  }
  return def;
}

export function b(v: Object | undefined | null, def: boolean = false): boolean {
  if (typeof v === 'boolean') {
    return v as boolean;
  }
  return def;
}

export function parseObj(text: string): JsonObj {
  const parsed: Object = JSON.parse(text) as Object;
  const o = asObj(parsed);
  if (o === null) {
    throw new Error('响应不是 JSON 对象');
  }
  return o;
}

export function getArr(o: JsonObj, key: string): Object[] | null {
  return asArr(o[key]);
}

export function getObj(o: JsonObj, key: string): JsonObj | null {
  return asObj(o[key]);
}
