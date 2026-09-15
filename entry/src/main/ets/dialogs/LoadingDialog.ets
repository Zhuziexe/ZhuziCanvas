@CustomDialog
export struct LoadingDialog {
  controller?: CustomDialogController;
  message: string = '正在处理...';

  build() {
    Row({ space: 12 }) {
      LoadingProgress()
        .width(56)
        .height(56)
      Text(this.message)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
    }
    .padding({left:16,right:32,top:16,bottom:16})
    .backgroundColor($r('sys.color.background_primary'))
    .borderRadius(16)
  }
}