/**
 * 选集面板的数据源。
 * 像《海贼王》这种一千多集的剧，一次性建 1000 个列表行会让面板弹出时明显卡顿；
 * 换成 LazyForEach 之后只建面板里看得见的那几行。
 */
export class EpisodeListSource implements IDataSource {
  private items: string[] = [];
  private listeners: DataChangeListener[] = [];

  setItems(items: string[]): void {
    this.items = items;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): string {
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
