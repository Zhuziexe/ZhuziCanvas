@CustomDialog
export struct PickColorDialog {
  controller: CustomDialogController;
  currentColor: string = '#FFFFFF';
  onColorSelected: (color: string) => void = () => {};

  private colors: string[] = [
    '#FFFFFF', '#000000', '#FF0000', '#00FF00',
    '#0000FF', '#FFFF00', '#FF00FF', '#00FFFF',
    '#FFA500', '#800080', '#008000', '#FFC0CB',
    '#A52A2A', '#808080', '#00BFFF'
  ];

  build() {
    Column({ space: 16 }) {
      Text('选择颜色')
        .fontSize(20)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))

      Grid() {
        ForEach(this.colors, (color: string) => {
          GridItem() {
            Button()
              .width(56)
              .height(56)
              .type(ButtonType.Normal)
              .backgroundColor(color)
              .margin(0)
              .onClick(() => {
                this.onColorSelected(color);
                this.controller.close();
              })
          }
        }, (color: string) => color)
      }
      .columnsTemplate('repeat(5, 1fr)')
      .columnsGap(0)
      .rowsGap(0)
      .padding(0)
      .width(280)
      .height(168)
      .borderRadius(12)

      Button('取消')
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .onClick(() => {
          this.controller.close();
        })
        .width('90%')
    }
    .padding({top:20,bottom:20})
  }
}