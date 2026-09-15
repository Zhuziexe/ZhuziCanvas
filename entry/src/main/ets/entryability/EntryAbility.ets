import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    // 新增：读取窗口尺寸并监听变化
    windowStage.getMainWindow()
      .then((win) => {
        this.mainWindow = win;

        // 初始尺寸
        const rect = win.getWindowProperties().windowRect;
        const w = px2vp(rect.width);
        const h = px2vp(rect.height);
        AppStorage.setOrCreate('windowWidth', w);
        AppStorage.setOrCreate('windowHeight', h);
        hilog.info(DOMAIN, 'testTag', 'windowWidth=%{public}f, windowHeight=%{public}f', w, h);

        // 监听尺寸变化
        win.on('windowSizeChange', (data: window.Size) => {
          AppStorage.set('windowWidth', px2vp(data.width));
          AppStorage.set('windowHeight', px2vp(data.height));
          hilog.info(DOMAIN, 'testTag', 'windowSizeChange: %{public}f x %{public}f',
            px2vp(data.width), px2vp(data.height));
        });
      })
      .catch((err: Error) => {
        hilog.error(DOMAIN, 'testTag', 'getMainWindow failed: %{public}s', JSON.stringify(err));
      });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}