import { common } from '@kit.AbilityKit';
import { PrivacyConsentVM } from '../viewmodels/PrivacyConsentVM';
import { PrivacyText, TextType } from '../common/CustomTypes';
import { WindowListener } from '../common/WindowListener';

@ComponentV2
export struct PrivacyConsent {
  @Param @Require
  public model: PrivacyConsentVM;

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

            Text(this.model.appName)
              .fontSize(24)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .margin({ bottom: 8 })

            Text(this.model.appDescription)
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .constraintSize({ minHeight: '60%' })

          Column() {
            Image($r('app.media.ic_security_shield'))
              .height(24)
              .margin({ bottom: 16 })
            this.buildDocument()
          }
          .width('100%')
          .padding({ left: 24, right: 24 })
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(FlexAlign.SpaceBetween)
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
  private buildDocument(): void {
    Text() {
      ForEach(this.model.document, (text: PrivacyText) => {
        Span(text.text)
          .fontSize(text.fontSize ? text.fontSize : $r('sys.float.Caption_M'))
          .fontColor(text.color ? text.color :
            (text.type === TextType.PLAIN
              ? $r('sys.color.font_secondary')
              : $r('sys.color.multi_color_01')))
          .fontWeight(text.fontWeight ? text.fontWeight : FontWeight.Regular)
          .onClick(() => {
            if (text.type === TextType.LINK) {
            } else if (text.type === TextType.ACTION) {
              text.onAction && text.onAction();
            }
          })
      }, (text: PrivacyText, index: number) => index + '_' + JSON.stringify(text))
    }
    .width('100%')
    .textAlign(TextAlign.Start)
  }

  @Builder
  private buildButtons(): void {
    Row({ space: 12 }) {
      Button('退出应用')
        .type(ButtonType.ROUNDED_RECTANGLE)
        .fontColor($r('app.color.brand'))
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .layoutWeight(1)
        .onClick(() => this.model.onReject())
      Button('同意并继续')
        .type(ButtonType.ROUNDED_RECTANGLE)
        .backgroundColor($r('app.color.brand'))
        .fontColor(Color.White)
        .layoutWeight(1)
        .onClick(() => this.model.onAccept())
    }
    .width('100%')
    .padding(16)
  }
}