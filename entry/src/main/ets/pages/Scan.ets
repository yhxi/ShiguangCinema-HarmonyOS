/**
 * 扫码页 —— ScanKit 扫二维码。
 *   · mode=server：扫码填服务端地址（首页用）
 *   · mode=source：扫码导入片源订阅 / 导出文件
 * 相机权限运行时申请；拒绝时给出手动粘贴兜底输入框。
 */

import { router } from '@kit.ArkUI';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Api, parseSourceList } from '../api/Api';
import { SourceConfig } from '../api/Models';
import { Prefs } from '../store/Prefs';
import { Session } from '../store/Session';
import { Theme } from '../common/Theme';

const TAG = 'ScanPage';
const DOMAIN = 0x0000;

@Entry
@Component
struct Scan {
  @State mode: string = 'server';
  @State manualText: string = '';
  @State msg: string = '';
  @State busy: boolean = false;

  private session: Session = Session.getInstance();
  private prefs: Prefs | null = null;

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, string> | undefined;
    if (params !== undefined && params['mode'] !== undefined) {
      this.mode = params['mode'];
    }
    Prefs.get(getContext(this)).then((p: Prefs) => {
      this.prefs = p;
    });
  }

  private async ensureCamera(): Promise<boolean> {
    const ctx = getContext(this);
    const atManager = abilityAccessCtrl.createAtManager();
    const perms: Array<Permissions> = ['ohos.permission.CAMERA'];
    const result = await atManager.requestPermissionsFromUser(ctx, perms);
    for (const r of result.authResults) {
      if (r === -1) {
        return false;
      }
    }
    return true;
  }

  private async startScan(): Promise<void> {
    const granted = await this.ensureCamera();
    if (!granted) {
      this.msg = '相机权限被拒绝，可手动粘贴二维码内容';
      return;
    }
    try {
      const options: scanBarcode.ScanOptions = {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false
      };
      const result: scanBarcode.ScanResult = await scanBarcode.startScanForResult(getContext(this), options);
      const text = result.originalValue;
      if (text === undefined || text === '') {
        this.msg = '未识别到内容';
        return;
      }
      await this.handle(text);
    } catch (e) {
      const err = e as Error;
      // 用户取消扫码（error code 1001）不算失败
      if (err.message.includes('1001')) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'scan failed: %{public}s', err.message);
      this.msg = `扫码失败：${err.message}`;
    }
  }

  private async handle(text: string): Promise<void> {
    const trimmed = text.trim();
    if (this.mode === 'server') {
      let url = trimmed;
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        this.msg = '二维码不是有效的服务端地址';
        return;
      }
      url = url.replace(/\/+$/, '');
      await this.prefs?.setServerUrl(url);
      // 直接尝试连接（无密码场景一步到位）
      try {
        const savedCookie = this.prefs !== null ? await this.prefs.getCookie(url) : '';
        await this.session.connect(url, '', savedCookie);
        if (this.prefs !== null) {
          await this.prefs.setServerUrl(this.session.serverUrl);
          await this.prefs.setCookie(this.session.serverUrl, (this.session.api as Api).currentCookie());
          const savedSources = await this.prefs.getSources(this.session.serverUrl);
          if (savedSources.length > 0) {
            this.session.sources = savedSources;
          } else {
            await this.prefs.setSources(this.session.serverUrl, this.session.sources);
          }
        }
        router.replaceUrl({ url: 'pages/Index' });
      } catch (e) {
        if ((e as Error).message === 'NEED_PASSWORD') {
          // 带回首页让用户输密码
          router.replaceUrl({ url: 'pages/Index' });
        } else {
          this.msg = `连接失败：${(e as Error).message}`;
        }
      }
    } else {
      // 片源导入：交给 SourceManage 的逻辑；这里直接导入并提示
      this.busy = true;
      try {
        const api = this.session.api;
        if (api === null) {
          this.msg = '请先连接服务端';
          return;
        }
        if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
          const list = await api.importSourceList(trimmed);
          const cur = await this.prefs?.getSources(this.session.serverUrl) ?? [];
          const existing = new Set<string>(cur.map((s0: SourceConfig) => s0.url));
          const fresh = list.filter((s0: SourceConfig) => !existing.has(s0.url));
          const merged = cur.concat(fresh);
          await this.prefs?.setSources(this.session.serverUrl, merged);
          this.session.sources = merged;
          this.msg = `扫码导入成功：新增 ${fresh.length} 条片源`;
        } else if (trimmed.includes('sources') || trimmed.includes('sites')) {
          const list = parseSourceList(trimmed);
          const cur = await this.prefs?.getSources(this.session.serverUrl) ?? [];
          const existing = new Set<string>(cur.map((s0: SourceConfig) => s0.url));
          const fresh = list.filter((s0: SourceConfig) => !existing.has(s0.url));
          const merged = cur.concat(fresh);
          await this.prefs?.setSources(this.session.serverUrl, merged);
          this.session.sources = merged;
          this.msg = `文本解析导入：新增 ${fresh.length} 条`;
        } else {
          this.msg = '二维码内容无法识别为片源';
        }
      } catch (e) {
        this.msg = `导入失败：${(e as Error).message}`;
      } finally {
        this.busy = false;
      }
    }
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 10 }) {
        Text('▶').fontSize(12).fontColor(Theme.ON_ACCENT)
          .width(26).height(26).textAlign(TextAlign.Center)
          .borderRadius(8).backgroundColor(Theme.ACCENT)
        Text(this.mode === 'server' ? '扫码连接服务端' : '扫码导入片源')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor(Theme.INK)
        Blank()
        Button('‹ 返回').fontSize(13).height(34).borderRadius(17)
          .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
          .onClick(() => { router.back(); })
      }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 4 })

      Button(this.busy ? '处理中…' : '打开相机扫码')
        .fontSize(15).height(48).borderRadius(14)
        .backgroundColor(Theme.ACCENT).fontColor(Theme.ON_ACCENT)
        .width('88%')
        .enabled(!this.busy)
        .onClick(() => { this.startScan(); })

      Text('或手动粘贴二维码内容').fontSize(12).fontColor(Theme.TERTIARY)

      TextInput({ placeholder: this.mode === 'server' ? 'https://tv.example.com' : '订阅地址或导出文本', text: this.manualText })
        .fontSize(14).height(46).borderRadius(14)
        .backgroundColor(Theme.PANEL).fontColor(Theme.INK)
        .placeholderColor(Theme.SECONDARY)
        .width('88%')
        .onChange((v: string) => { this.manualText = v; })

      Button('导入')
        .fontSize(15).height(44).borderRadius(14)
        .backgroundColor(Theme.TINT).fontColor(Theme.INK)
        .width('88%')
        .enabled(this.manualText.trim() !== '' && !this.busy)
        .onClick(() => { this.handle(this.manualText); })

      if (this.msg !== '') {
        Text(this.msg).fontSize(13).fontColor(Theme.SECONDARY)
          .width('88%').textAlign(TextAlign.Center)
      }

      Blank()
    }
    .width('100%').height('100%')
    .backgroundColor(Theme.BG)
  }
}
