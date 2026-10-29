import { AbilityConstant, UIAbility, Want, errorManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { Prefs } from '../store/Prefs';

const DOMAIN = 0x0000;
const TAG = 'ShiguangCinema';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    // 全局 JS 异常捕获：白屏类问题靠这里把堆栈吐到 hilog
    try {
      if (typeof errorManager.on === 'function') {
        errorManager.on('globalErrorOccurred', (err: Error) => {
          hilog.error(DOMAIN, TAG, 'UNHANDLED JS ERROR');
          Prefs.get(this.context).then((prefs: Prefs) => prefs.recordCrash(err)).catch(() => {});
        });
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'error observer unavailable: %{public}s', String(e));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent OK');
      // 预热首选项存储
      Prefs.get(this.context).then(() => {
        hilog.info(DOMAIN, TAG, 'prefs ready');
      }).catch((e: Object) => {
        hilog.error(DOMAIN, TAG, 'prefs init failed: %{public}s', (e as Error).message);
      });
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
