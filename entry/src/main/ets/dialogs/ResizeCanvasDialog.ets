import { promptAction } from '@kit.ArkUI';

export type ResizeMode = 'stretch' | 'contain' | 'cover' | 'topLeft';

interface ModeOption {
  label: string;
  desc: string;
}

const MIN_SIZE = 32;
const MAX_SIZE = 2560;
const MAX_LEN = 4;

@CustomDialog
export struct ResizeCanvasDialog {
  controller?: CustomDialogController;
  currentWidth: number = 1280;
  currentHeight: number = 720;
  onConfirm: (newW: number, newH: number, mode: ResizeMode) => void = () => {
  };
  @State inputW: string = '';
  @State inputH: string = '';
  @State selectedMode: number = 0;
  @State sizeError: string = '';
  private modes: ModeOption[] = [
    { label: '拉伸', desc: '内容变形填满新画布，不保持比例' },
    { label: '等比缩放 + 居中', desc: '完整内容缩放到新画布内，周边留白' },
    { label: '居中裁切', desc: '等比放大填满画布，超出部分裁掉' },
    { label: '左上角对齐', desc: '内容不缩放，左上角对齐，超出裁掉不足留白' }
  ];

  aboutToAppear(): void {
    this.inputW = this.currentWidth.toString();
    this.inputH = this.currentHeight.toString();
  }

  private filterDigits(input: string): string {
    let r = '';
    for (let i = 0; i < input.length; i++) {
      const ch = input.charAt(i);
      if (ch >= '0' && ch <= '9') r += ch;
    }
    return r;
  }

  private validateSize(value: string, label: string): string {
    const t = value.trim();
    if (t.length === 0) return `${label}不能为空`;
    for (let i = 0; i < t.length; i++) {
      const ch = t.charAt(i);
      if (ch < '0' || ch > '9') return `${label}只能输入数字`;
    }
    const n = Number(t);
    if (!Number.isFinite(n) || Number.isNaN(n)) return `${label}格式不正确`;
    if (n < MIN_SIZE) return `${label}不能小于 ${MIN_SIZE}`;
    if (n > MAX_SIZE) return `${label}不能大于 ${MAX_SIZE}`;
    return '';
  }

  private getMode(): ResizeMode {
    switch (this.selectedMode) {
      case 1:
        return 'contain';
      case 2:
        return 'cover';
      case 3:
        return 'topLeft';
      default:
        return 'stretch';
    }
  }

  build() {
    Column() {
      // 内容区：可滚动
      Column({ space: 16 }) {
        Text('调整画布尺寸')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .width('100%')

        Text(`当前尺寸：${this.currentWidth} × ${this.currentHeight}`)
          .fontSize(16)
          .fontColor($r('sys.color.font_secondary'))
          .width('100%')

        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text('新宽度')
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
            TextInput({ text: this.inputW, placeholder: '宽' })
              .maxLength(MAX_LEN)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.inputW = this.filterDigits(v);
                this.sizeError = '';
              })
          }
          .layoutWeight(1)

          Column({ space: 4 }) {
            Text('新高度')
              .fontSize(14)
              .fontColor($r('sys.color.font_primary'))
            TextInput({ text: this.inputH, placeholder: '高' })
              .maxLength(MAX_LEN)
              .type(InputType.Number)
              .onChange((v: string) => {
                this.inputH = this.filterDigits(v);
                this.sizeError = '';
              })
          }
          .layoutWeight(1)
        }
        .width('100%')

        Scroll() {
          Column({ space: 8 }) {
            Text('现有内容的处理方式')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .width('100%')

            ForEach(this.modes, (item: ModeOption, index: number) => {
              Column({ space: 2 }) {
                Text(item.label)
                  .fontSize(15)
                  .fontColor(this.selectedMode === index
                    ? $r('app.color.brand')
                    : $r('sys.color.font_primary'))
                  .width('100%')

                Text(item.desc)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%')
              }
              .width('100%')
              .padding({
                left: 14,
                right: 14,
                top: 10,
                bottom: 10
              })
              .borderRadius(10)
              .border({
                width: this.selectedMode === index ? 1.5 : 0.5,
                color: this.selectedMode === index
                  ? $r('app.color.brand')
                  : $r('sys.color.font_tertiary')
              })
              .backgroundColor(this.selectedMode === index
                ? $r('sys.color.background_tertiary')
                : Color.Transparent)
              .onClick(() => {
                this.selectedMode = index;
              })
            }, (item: ModeOption) => item.label)
          }
          .width('100%')
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .align(Alignment.Top)
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

        Button('应用')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            const wErr = this.validateSize(this.inputW, '宽度');
            if (wErr) {
              this.sizeError = wErr;
              promptAction.openToast({ message: wErr }).catch(()=>{});
              return;
            }
            const hErr = this.validateSize(this.inputH, '高度');
            if (hErr) {
              this.sizeError = hErr;
              promptAction.openToast({ message: hErr }).catch(()=>{});
              return;
            }

            this.onConfirm(Number(this.inputW), Number(this.inputH), this.getMode());
            this.controller?.close();
          })
      }
      .width('100%')
    }
    .padding({
      left: 24,
      right: 24,
      top: 12,
      bottom: 24
    })
    .width('100%')
  }
}