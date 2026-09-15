import { common } from '@kit.AbilityKit';
import { WindowListener } from '../common/WindowListener';

@ComponentV2
export struct AboutPage {
  @Param @Require
  onPermission:()=>void;

  @Param @Require
  onPrivacy:()=>void;

  @Param @Require
  onCode:()=>void;

  private abilityContext: common.UIAbilityContext =
    this.getUIContext().getHostContext() as common.UIAbilityContext;
  private listener: WindowListener = new WindowListener(this.abilityContext);

  public aboutToAppear(): void {
    this.listener.start();
  }

  public aboutToDisappear(): void {
    this.listener.stop();
  }

  public build(): void {
    this.buildContent();
  }

  @Builder
  buildContent() {
    Column() {
      Scroll() {
        Column() {
          Stack() {
            Image($r('app.media.background')).width(64).height(64)
            Image($r('app.media.foreground')).width(64).height(64)
          }
          .width(64)
          .height(64)
          .borderRadius(16)
          .clip(true)
          .margin({ bottom: 16 })

          Text('竹子画板')
            .fontSize(24)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .margin({ bottom: 8 })

          Text('一个只属于你的画板')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))

          Text('版本 1.0.2')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))

          Blank()
            .height(12)

          Text('作者:竹子')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .constraintSize({ minHeight: '100%' })
      }
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)

      this.buildButtons()
    }
    .width('100%')
    .height('100%')
    .padding({bottom:`${this.listener.avoidArea.bottom}px`})
  }

  @Builder
  private buildButtons(): void {
    Column({ space: 6 }) {
      Button('权限使用说明')
        .type(ButtonType.ROUNDED_RECTANGLE)
        .fontColor($r('app.color.brand'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .onClick(() => this.onPermission())
        .width('100%')
      Button('隐私说明')
        .type(ButtonType.ROUNDED_RECTANGLE)
        .fontColor($r('app.color.brand'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .onClick(() => this.onPrivacy())
        .width('100%')
      Button('源代码')
        .type(ButtonType.ROUNDED_RECTANGLE)
        .fontColor($r('app.color.brand'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .onClick(() => this.onCode())
        .width('100%')
    }
    .width('100%')
    .padding(16)
  }
}