import { KeyCode } from "@kit.InputKit";

@CustomDialog
export struct PickColorDialog {
  controller: CustomDialogController;
  currentColor: string = '#FFFFFF';
  onColorSelected: (color: string) => void = () => {};

  @State selectedColor: string = '#FFFFFF';
  @State tabindex: number = 0;
  @State r: number = 255;
  @State g: number = 255;
  @State b: number = 255;
  @State rText: string = '255';
  @State gText: string = '255';
  @State bText: string = '255';
  @State hexInput: string = 'FFFFFF';
  @State hexError: string = '';

  @State colorGradientR: LinearGradient = new LinearGradient([{ color: "#FF000000", offset: 0 }, { color: "#FFFF0000", offset: 1 }])
  @State colorGradientG: LinearGradient = new LinearGradient([{ color: "#FF000000", offset: 0 }, { color: "#FF00FF00", offset: 1 }])
  @State colorGradientB: LinearGradient = new LinearGradient([{ color: "#FF000000", offset: 0 }, { color: "#FF0000FF", offset: 1 }])

  private gridColors: string[] = [
    '#FFFFFF', '#F0F0F0', '#D0D0D0', '#909090', '#505050', '#000000',
    '#FF0000', '#FF6600', '#FFAA00', '#FFDD00', '#FFEEAA', '#FFC0CB',
    '#0066FF', '#00AAFF', '#00DDDD', '#99CCFF', '#6666CC', '#000080',
    '#00CC00', '#66CC00', '#CCFF00', '#009900', '#66AA66', '#336633',
    '#FF99CC', '#CC99FF', '#AACCFF', '#99FFCC', '#FFFF99', '#FFCC99'
  ];

  aboutToAppear(): void {
    const hex = this.normalizeHex(this.currentColor);
    this.selectedColor = hex;
    this.applyHexToRgb(hex);
    this.hexInput = hex.substring(1);
    this.rText = this.r.toString();
    this.gText = this.g.toString();
    this.bText = this.b.toString();
  }

  private normalizeHex(hex: string): string {
    const h = hex.replace('#', '').toUpperCase();
    if (h.length !== 6) return '#FFFFFF';
    for (let i = 0; i < 6; i++) {
      const c = h.charAt(i);
      if ((c < '0' || c > '9') && (c < 'A' || c > 'F')) return '#FFFFFF';
    }
    return '#' + h;
  }

  private applyHexToRgb(hex: string): void {
    const h = hex.replace('#', '');
    this.r = parseInt(h.substring(0, 2), 16);
    this.g = parseInt(h.substring(2, 4), 16);
    this.b = parseInt(h.substring(4, 6), 16);
  }

  private rgbToHex(): string {
    const rh = Math.round(this.r).toString(16).padStart(2, '0');
    const gh = Math.round(this.g).toString(16).padStart(2, '0');
    const bh = Math.round(this.b).toString(16).padStart(2, '0');
    return `#${rh}${gh}${bh}`.toUpperCase();
  }

  private applyColor(hex: string): void {
    this.selectedColor = hex;
    this.applyHexToRgb(hex);
    this.hexInput = hex.substring(1);
    this.hexError = '';
    this.rText = this.r.toString();
    this.gText = this.g.toString();
    this.bText = this.b.toString();
  }

  private isHexChar(c: string): boolean {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || (c >= 'a' && c <= 'f');
  }

  private onHexInput(v: string): void {
    let filtered = '';
    for (let i = 0; i < v.length && filtered.length < 6; i++) {
      const c = v.charAt(i);
      if (this.isHexChar(c)) filtered += c.toUpperCase();
    }
    this.hexInput = filtered;

    if (filtered.length === 6) {
      this.applyColor('#' + filtered);
    } else if (filtered.length === 0) {
      this.hexError = '';
    } else {
      this.hexError = '需要 6 位字符';
    }
  }

  private confirm(): void {
    this.onColorSelected(this.selectedColor);
    this.controller.close();
  }

  private cancel(): void {
    this.controller.close();
  }

  @Builder
  TabButton(label: string, idx: number) {
    Text(label)
      .fontSize(14)
      .fontColor(this.tabindex === idx
        ? $r('sys.color.font_primary')
        : $r('sys.color.font_secondary'))
      .fontWeight(this.tabindex === idx ? FontWeight.Medium : FontWeight.Normal)
      .textAlign(TextAlign.Center)
      .layoutWeight(1)
      .height(32)
      .borderRadius(8)
      .backgroundColor(this.tabindex === idx
        ? $r('sys.color.background_primary')
        : Color.Transparent)
      .onClick(() => {
        this.tabindex = idx;
      })
  }

  @Builder
  GridTab() {
    Grid() {
      ForEach(this.gridColors, (color: string) => {
        GridItem() {
          Column()
            .width('100%')
            .height('100%')
            .borderRadius(6)
            .backgroundColor(color)
            .border({
              width: this.selectedColor === color ? 2 : 0.5,
              color: this.selectedColor === color
                ? $r('app.color.brand')
                : '#20000000'
            })
            .onClick(() => {
              this.applyColor(color);
            })
        }
      }, (color: string) => color)
    }
    .columnsTemplate('repeat(6, 1fr)')
    .rowsTemplate('repeat(5, 1fr)')   // 关键：固定 5 行，禁止内部滚动
    .columnsGap(6)
    .rowsGap(6)
    .width('100%')
    .height(200)
  }

  @Builder
  SliderRow(label: string, idx: number, endColor: string) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .width(16)

      Stack({ alignContent: Alignment.Center }) {
        Row()
          .width('100%')
          .height(20)
          .borderRadius(10)
          .linearGradient({
            angle: 90,
            colors: [['#000000', 0.0], [endColor, 1.0]]
          })

        Slider({
          value: idx === 0 ? this.r : (idx === 1 ? this.g : this.b),
          min: 0,
          max: 255,
          step: 1,
          style: SliderStyle.InSet
        })
          .trackColor(Color.Transparent)
          .selectedColor(Color.Transparent)
          .blockColor('#FFFFFF')
          .width('100%')
          .onChange((v: number) => {
            const n = Math.round(v);
            if (idx === 0) {
              this.r = n;
              this.rText = n.toString();
            } else if (idx === 1) {
              this.g = n;
              this.gText = n.toString();
            } else {
              this.b = n;
              this.bText = n.toString();
            }
            this.applyColor(this.rgbToHex());
          })
      }
      .layoutWeight(1)
      .height(40)

      TextInput({
        text: idx === 0 ? this.rText : (idx === 1 ? this.gText : this.bText)
      })
        .type(InputType.Number)
        .maxLength(3)
        .width(56)
        .height(32)
        .textAlign(TextAlign.Center)
        .fontSize(14)
        .padding({ left: 4, right: 4 })
        .onChange((v: string) => {
          if (idx === 0) {
            this.rText = v;
          } else if (idx === 1) {
            this.gText = v;
          } else {
            this.bText = v;
          }

          const n = parseInt(v);
          if (!isNaN(n) && n >= 0 && n <= 255) {
            if (idx === 0) {
              this.r = n;
            } else if (idx === 1) {
              this.g = n;
            } else {
              this.b = n;
            }
            this.applyColor(this.rgbToHex());
          }
        })
    }
    .width('100%')
    .height(40)
  }

  @Builder
  SliderTab() {
    Column({ space: 8 }) {
      this.SliderRow('R', 0, '#FF0000')
      this.SliderRow('G', 1, '#00FF00')
      this.SliderRow('B', 2, '#0000FF')
    }
    .width('100%')
    .height(200)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  HexTab() {
    Column({ space: 12 }) {
      Text('输入十六进制颜色代码')
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .width('100%')

      Row({ space: 8 }) {
        Text('#')
          .fontSize(20)
          .fontColor($r('sys.color.font_secondary'))
        TextInput({ text: this.hexInput, placeholder: 'FFFFFF' })
          .type(InputType.Normal)
          .maxLength(6)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.onHexInput(v);
          })
      }
      .width('100%')

      if (this.hexError.length > 0) {
        Text(this.hexError)
          .fontSize(12)
          .fontColor($r('sys.color.warning'))
          .width('100%')
      }
    }
    .width('100%')
    .height(200)
    .padding({ top: 16 })
  }

  build() {
    Column({ space: 16 }) {
      Text('选择颜色')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')

      Row({ space: 12 }) {
        Column()
          .width(48)
          .height(48)
          .borderRadius(8)
          .backgroundColor(this.selectedColor)
          .border({ width: 1, color: '#20000000' })
        Column({ space: 2 }) {
          Text('当前')
            .fontSize(11)
            .fontColor($r('sys.color.font_secondary'))
          Text(this.selectedColor)
            .fontSize(15)
            .fontColor($r('sys.color.font_primary'))
            .fontWeight(FontWeight.Medium)
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
      }
      .width('100%')

      Row() {
        this.TabButton('网格', 0)
        this.TabButton('滑块', 1)
        this.TabButton('代码', 2)
      }
      .width('100%')
      .padding(3)
      .backgroundColor($r('sys.color.background_tertiary'))
      .borderRadius(10)

      if (this.tabindex === 0) {
        this.GridTab()
      } else if (this.tabindex === 1) {
        this.SliderTab()
      } else {
        this.HexTab()
      }

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontColor($r('app.color.brand'))
          .onClick(() => this.cancel())

        Button('完成')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => this.confirm())
          .defaultFocus(true)
      }
      .width('100%')
    }
    .onKeyEvent((e: KeyEvent) => {
      if (e.type === KeyType.Down &&
        (e.keyCode === KeyCode.KEYCODE_ENTER ||
          e.keyCode === KeyCode.KEYCODE_NUMPAD_ENTER)) {
        this.confirm();
        return true;
      }
      return false;
    })
    .width('100%')
    .padding(20)
  }
}