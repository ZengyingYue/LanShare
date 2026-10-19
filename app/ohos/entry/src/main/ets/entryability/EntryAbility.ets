import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { LanShareApp } from '../app/LanShareApp';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // Settings load is async; the app continues bootstrapping while the
    // first frame renders. Errors are logged and the UI still opens.
    LanShareApp.bootstrap(this.context).catch((e: Object) => {
      console.error(`[LanShare][Entry] bootstrap failed: ${JSON.stringify(e)}`);
    });
  }

  onDestroy(): void {
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        console.error(`[LanShare][Entry] failed to load content: ${err.message}`);
        return;
      }
      console.info('[LanShare][Entry] content loaded');
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
  }

  onBackground(): void {
  }
}
