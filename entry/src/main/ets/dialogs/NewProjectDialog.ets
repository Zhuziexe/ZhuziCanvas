import { promptAction } from "@kit.ArkUI";

@CustomDialog
export struct NewProjectDialog {
  controller?: CustomDialogController;
  existingNames: string[] = [];
  onConfirm: (name: string, width: number, height: number) => void = () => {};

  @State name: string = '';
  @State selectedSize: number = 0;

  @State inputw: string = '720';
  @State inputh: string = '720';
  @State sizeError: string = '';

  private static readonly MIN_SIZE = 32;
  private static readonly MAX_SIZE = 2560;
  private static readonly MAX_LEN = 4;

  private sizes: Record<string, number>[] = [
    { 'w': 1280, 'h': 720 },
    { 'w': 720, 'h': 1280 }
  ];

  private options: string[] = ['横屏1280x720', '竖屏720x1280', '自定义'];

  private filterDigits(input: string): string {
    let result = '';
    for (let i = 0; i < input.length; i++) {
      const ch = input.charAt(i);
      if (ch >= '0' && ch <= '9') {
        result += ch;
      }
    }
    return result;
  }

  private validateSize(value: string, label: string): string {
    const trimmed = value.trim();
    if (trimmed.length === 0) {
      return `${label}不能为空`;
    }
    for (let i = 0; i < trimmed.length; i++) {
      const ch = trimmed.charAt(i);
      if (ch < '0' || ch > '9') {
        return `${label}只能输入数字`;
      }
    }
    const num = Number(trimmed);
    if (!Number.isFinite(num) || Number.isNaN(num)) {
      return `${label}格式不正确`;
    }
    if (num < NewProjectDialog.MIN_SIZE) {
      return `${label}不能小于 ${NewProjectDialog.MIN_SIZE}`;
    }
    if (num > NewProjectDialog.MAX_SIZE) {
      return `${label}不能大于 ${NewProjectDialog.MAX_SIZE}`;
    }
    return '';
  }

  build() {
    Scroll() {
      Column({ space: 16 }) {
        Text('新建项目')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')

        TextInput({ placeholder: '项目名称', text: this.name })
          .defaultFocus(true)
          .onChange((v: string) => {
            this.name = v;
          })

        Column({ space: 8 }) {
          Text('画布尺寸')
            .fontSize(14)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')

          Scroll() {
            Row({ space: 6 }) {
              ForEach(this.options, (label: string, index: number) => {
                Button(label)
                  .fontSize(14)
                  .fontWeight(this.selectedSize === index ? FontWeight.Medium : FontWeight.Normal)
                  .fontColor(this.selectedSize === index ? Color.White : $r('sys.color.font_primary'))
                  .backgroundColor(this.selectedSize === index
                    ? $r('app.color.brand')
                    : Color.Transparent)
                  .border({
                    width: 1,
                    color: this.selectedSize === index
                      ? $r('app.color.brand')
                      : $r('sys.color.comp_divider')
                  })
                  .onClick(() => {
                    this.selectedSize = index;
                    this.sizeError = '';
                  })
              }, (label: string) => `chipbtn_${label}`)
            }
          }
          .width('100%')
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.Start)
        }
        .width('100%')

        if (this.selectedSize === 2) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text(`宽`)
                .fontColor($r('sys.color.font_primary'))
                .fontSize(14)
              TextInput({
                text: this.inputw,
                placeholder: '宽'
              })
                .maxLength(NewProjectDialog.MAX_LEN)
                .type(InputType.Number)
                .onChange((value: string) => {
                  const filtered = this.filterDigits(value);
                  this.inputw = filtered;
                  if (filtered.length > 0) {
                    const n = Number(filtered);
                    this.sizeError = n > NewProjectDialog.MAX_SIZE
                      ? `宽不能大于 ${NewProjectDialog.MAX_SIZE}`
                      : '';
                  }
                })
            }
            .layoutWeight(1)

            Column({ space: 4 }) {
              Text(`高`)
                .fontColor($r('sys.color.font_primary'))
                .fontSize(14)
              TextInput({
                text: this.inputh,
                placeholder: '高'
              })
                .maxLength(NewProjectDialog.MAX_LEN)
                .type(InputType.Number)
                .onChange((value: string) => {
                  const filtered = this.filterDigits(value);
                  this.inputh = filtered;
                  if (filtered.length > 0) {
                    const n = Number(filtered);
                    this.sizeError = n > NewProjectDialog.MAX_SIZE
                      ? `高不能大于 ${NewProjectDialog.MAX_SIZE}`
                      : '';
                  }
                })
            }
            .layoutWeight(1)
          }
          .width('100%')

          if (this.sizeError.length > 0) {
            Text(this.sizeError)
              .fontSize(12)
              .fontColor($r('sys.color.warning'))
              .width('100%')
          }
        }

        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontColor($r('app.color.brand'))
            .onClick(() => this.controller?.close())

          Button('创建')
            .layoutWeight(1)
            .buttonStyle(ButtonStyleMode.EMPHASIZED)
            .backgroundColor($r('app.color.brand'))
            .onClick(() => {
              const name = this.name.trim();
              if (!name) {
                promptAction.openToast({ message: '请输入项目名称' }).catch(() => {
                });
                return;
              }
              if (this.existingNames.includes(name)) {
                promptAction.openToast({ message: '项目名称已存在' }).catch(() => {
                });
                return;
              }

              let w = 0;
              let h = 0;
              if (this.selectedSize === 2) {
                const wErr = this.validateSize(this.inputw, '宽');
                if (wErr) {
                  this.sizeError = wErr;
                  promptAction.openToast({ message: wErr }).catch(() => {
                  });
                  return;
                }
                const hErr = this.validateSize(this.inputh, '高');
                if (hErr) {
                  this.sizeError = hErr;
                  promptAction.openToast({ message: hErr }).catch(() => {
                  });
                  return;
                }
                w = Number(this.inputw);
                h = Number(this.inputh);
              } else {
                const size = this.sizes[this.selectedSize];
                w = size['w'] as number;
                h = size['h'] as number;
              }

              this.onConfirm(name, w, h);
              this.controller?.close();
            })
        }
        .width('100%')
      }
      .width('100%')
    }
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .padding(24)
    .width('100%')
  }
}