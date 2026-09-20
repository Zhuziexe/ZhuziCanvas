import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CustomColors, ThemeControl, window } from '@kit.ArkUI';
import { deviceInfo, SuppressWarnings, SuppressWarningsType } from '@kit.BasicServicesKit';

const DOMAIN = 0x0000;

class AppColors implements CustomColors {
  public brand: ResourceColor = $r('app.color.brand');
  public confirm: ResourceColor = $r('app.color.brand');
  public backgroundEmphasize?: ResourceColor = $r('app.color.brand');
  public compBackgroundEmphasize?: ResourceColor = $r('app.color.brand');
  public interactiveFocus?: ResourceColor = $r('app.color.brand');
  public fontEmphasize?: ResourceColor = $r('app.color.brand');
  public iconEmphasize?: ResourceColor = $r('app.color.brand');
}

class AppTheme implements CustomTheme {
  public colors: AppColors = new AppColors();
}

let zhuziAppTheme: CustomTheme = new AppTheme();

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  private isTerminating: boolean = false;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  @SuppressWarnings({ rules: [SuppressWarningsType.SYSCAP] })
  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      try {
        ThemeControl.setDefaultTheme(zhuziAppTheme);
        hilog.info(DOMAIN, 'testTag', 'Custom theme applied successfully.');
      } catch (themeErr) {
        hilog.error(DOMAIN, 'testTag', 'Failed to apply custom theme: %{public}s', JSON.stringify(themeErr));
      }
    });

    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }

    windowStage.getMainWindow()
      .then((win) => {
        this.mainWindow = win;

        try {
          const rect = win.getWindowProperties().windowRect;
          const w = px2vp(rect.width);
          const h = px2vp(rect.height);
          AppStorage.setOrCreate('windowWidth', w);
          AppStorage.setOrCreate('windowHeight', h);
        } catch (error) {
          console.error('无法getWindowProperties，使用默认值');
          AppStorage.setOrCreate('windowWidth', 1280);
          AppStorage.setOrCreate('windowHeight', 720);
        }

        win.setWindowLimits({
          minWidth: 640,
          minHeight: 640
        }).catch(() => console.log('无法setWindowLimits'));

        win.on('windowSizeChange', (data: window.Size) => {
          AppStorage.set('windowWidth', px2vp(data.width));
          AppStorage.set('windowHeight', px2vp(data.height));
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

  async onPrepareToTerminateAsync(): Promise<boolean> {
    if (deviceInfo.deviceType !== '2in1') {
      console.info('设备类型不是2in1，直接退出');
      return false;
    }

    if (this.isTerminating) {
      console.info('正在退出');
      return false;
    }

    if (AppStorage.get<boolean>('editorDirty') !== true) {
      console.info('内容已保存，直接退出');
      return false;
    }

    this.isTerminating = true;

    try {
      const choice = await this.askUserToSave();

      if (choice === 'save') {
        const ok = await this.triggerSaveInEditor();
        if (ok) {
          return false;
        }
        this.isTerminating = false;
        return true;
      }

      if (choice === 'discard') {
        return false;
      }

      this.isTerminating = false;
      return true;
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'onPrepareToTerminateAsync 异常: %{public}s', JSON.stringify(e));
      this.isTerminating = false;
      return false;
    }
  }

  private askUserToSave(): Promise<'save' | 'discard' | 'cancel'> {
    return new Promise((resolve) => {
      if (!this.mainWindow) {
        resolve('discard');
        return;
      }
      let settled = false;
      const done = (v: 'save' | 'discard' | 'cancel') => {
        if (settled) return;
        settled = true;
        resolve(v);
      };

      try {
        this.mainWindow.getUIContext().showAlertDialog({
          title: '保存更改',
          message: '当前画板有未保存的修改，是否保存后退出？',
          buttons: [
            {
              value: '保存并退出',
              primary: true,
              backgroundColor: $r('app.color.brand'),
              fontColor: Color.White,
              action: () => done('save')
            },
            {
              value: '不保存退出',
              fontColor: $r('sys.color.warning'),
              action: () => done('discard')
            },
            {
              value: '取消',
              action: () => done('cancel')
            }
          ],
          buttonDirection: DialogButtonDirection.AUTO
        });
      } catch (error) {
        console.error('无法window.Window.getUIContext');
      }
    });
  }

  private triggerSaveInEditor(): Promise<boolean> {
    return new Promise((resolve) => {
      let finished = false;
      const token = Date.now();

      AppStorage.setOrCreate('saveAndExitResultToken', 0);
      AppStorage.setOrCreate('saveAndExitResult', false);

      AppStorage.setOrCreate('saveAndExitToken', token);

      const timer = setInterval(() => {
        if (finished) return;
        const resultToken = AppStorage.get<number>('saveAndExitResultToken');
        if (resultToken === token) {
          const result = AppStorage.get<boolean>('saveAndExitResult');
          finished = true;
          clearInterval(timer);
          resolve(result === true);
        }
      }, 50);

      setTimeout(() => {
        if (!finished) {
          finished = true;
          clearInterval(timer);
          resolve(false);
        }
      }, 8000);
    });
  }
}