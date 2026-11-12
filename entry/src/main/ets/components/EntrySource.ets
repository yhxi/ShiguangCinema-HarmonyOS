import { WatchEntry } from '../store/Prefs';

/**
 * 观看记录/收藏列表的 LazyForEach 数据源。
 *
 * 历史与收藏都可能累积上百条，用 ForEach 会一次性把每一行都建出来，
 * 每行的海报组件随即各发一次请求，首屏被自己的流量堵住。
 * 换成 LazyForEach 之后只挂当前可见的几行，滑到哪加载到哪。
 */
export class EntrySource implements IDataSource {
  private items: WatchEntry[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: WatchEntry[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): WatchEntry {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }
}
