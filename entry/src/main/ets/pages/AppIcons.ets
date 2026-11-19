import { bundleManager } from '@kit.AbilityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { router } from '@kit.ArkUI';
import { Theme } from '../common/Theme';

interface IconChoice {
  id: string;
  title: string;
  image: Resource;
}

interface IconGroup {
  title: string;
  choices: IconChoice[];
}

const GROUPS: IconGroup[] = [
  { title: '绿色时钟', choices: [
    { id: 'icon_jade_clock', title: '翡翠时钟', image: $r('app.media.icon_jade_clock') },
    { id: 'icon_jade_arc', title: '翡翠刻度', image: $r('app.media.icon_jade_arc') }
  ] },
  { title: '紫色放映机', choices: [
    { id: 'icon_violet_projector', title: '紫蓝放映', image: $r('app.media.icon_violet_projector') },
    { id: 'icon_purple_projector', title: '紫幕放映', image: $r('app.media.icon_purple_projector') }
  ] },
  { title: '红色场记板', choices: [
    { id: 'icon_red_slate', title: '红色场记', image: $r('app.media.icon_red_slate') },
    { id: 'icon_red_premiere', title: '红幕开拍', image: $r('app.media.icon_red_premiere') }
  ] }
];

@Entry
@Component
struct AppIcons {
  @State selected: string = '';
  @State available: string[] = [];
  @State ready: boolean = false;
  @State working: boolean = false;
  @State status: string = '';
  @State error: boolean = false;

  aboutToAppear(): void {
    this.loadSelection();
  }

  private async loadSelection(): Promise<void> {
    this.ready = false;
    this.error = false;
    if (deviceInfo.sdkApiVersion < 26 || typeof bundleManager.getAlternateIcons !== 'function' ||
      typeof bundleManager.setAlternateIcon !== 'function') {
      this.status = '当前系统可预览图标。桌面切换需要支持备用图标的 HarmonyOS 版本。';
      return;
    }
    try {
      const icons = await bundleManager.getAlternateIcons();
      this.available = icons.map(icon => icon.iconName);
      this.selected = icons.find(icon => icon.enabled)?.iconName ?? '';
      this.ready = this.available.length > 0;
      this.status = this.ready ? '' : '当前安装包没有可切换的桌面图标。';
    } catch (e) {
      this.error = true;
      this.status = '系统暂时无法读取应用图标。请在主应用中重试。';
    }
  }

  private async applyIcon(id: string): Promise<void> {
    if (!this.ready || this.working || this.selected === id || (id !== '' && !this.available.includes(id))) { return; }
    this.working = true;
    this.error = false;
    this.status = '';
    try {
      await bundleManager.setAlternateIcon(id);
      this.selected = id;
      this.status = id === '' ? '已恢复原图标' : '已切换桌面图标';
    } catch (e) {
      const err = e as BusinessError;
      if (id === '' && err.code === 17700309) {
        this.selected = '';
        this.status = '已使用原图标';
      } else {
        this.error = true;
        this.status = '系统未能切换图标。请在主应用中使用系统主题后重试。';
      }
    } finally {
      this.working = false;
    }
  }

  @Builder
  iconCard(choice: IconChoice) {
    Button() {
      Column({ space: 9 }) {
        Image(choice.image)
          .width(80).height(80).objectFit(ImageFit.Cover).borderRadius(20)
        Text(choice.title)
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor(Theme.INK).maxLines(1)
        Text(this.selected === choice.id ? '当前图标' : ' ')
          .fontSize(11).fontColor(Theme.ACCENT)
      }.width('100%').padding({ top: 16, bottom: 12 })
    }
    .type(ButtonType.Normal)
    .layoutWeight(1).borderRadius(16)
    .backgroundColor(this.selected === choice.id ? Theme.TINT : Theme.PANEL)
    .border({ width: 1, color: this.selected === choice.id ? Theme.ACCENT : Color.Transparent })
    .enabled(this.ready && !this.working && this.available.includes(choice.id))
    .onClick(() => { this.applyIcon(choice.id); })
  }

  build() {
    Column() {
      Row({ space: 12 }) {
        Button('‹ 返回')
          .fontSize(13).height(36).borderRadius(18)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .onClick(() => { router.back(); })
        Text('应用图标')
          .fontSize(24).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
          .layoutWeight(1)
      }.width('100%').padding({ left: 18, right: 18, top: 14, bottom: 14 })

      Scroll() {
        Column({ space: 16 }) {
          if (this.status !== '') {
            Text(this.status)
              .fontSize(13).fontColor(this.error ? Theme.DANGER : Theme.SECONDARY)
              .width('100%').padding(12).borderRadius(12).backgroundColor(Theme.PANEL)
          }
          ForEach(GROUPS, (group: IconGroup) => {
            Column({ space: 8 }) {
              Text(group.title)
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor(Theme.INK)
                .width('100%')
              Row({ space: 10 }) {
                ForEach(group.choices, (choice: IconChoice) => {
                  this.iconCard(choice)
                }, (choice: IconChoice) => choice.id)
              }.width('100%')
            }.width('100%')
          }, (group: IconGroup) => group.title)
          Button(this.ready && this.selected === '' ? '当前使用原图标' : '恢复原图标')
            .width('100%').height(42).borderRadius(14)
            .backgroundColor(Theme.PANEL).fontColor(Theme.ACCENT)
            .enabled(this.ready && !this.working && this.selected !== '')
            .onClick(() => { this.applyIcon(''); })
        }.width('100%').padding({ left: 18, right: 18, bottom: 18 })
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
    }.width('100%').height('100%').backgroundColor(Theme.BG)
  }
}
