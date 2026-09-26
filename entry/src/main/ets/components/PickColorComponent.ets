import { KeyCode } from "@kit.InputKit";

@Component
export struct PickColorComponent {
  currentColor: string = '#FFFFFF';
  onColorSelected: (color: string) => void = () => {};
  onClose: () => void = () => {};

  @State selectedColor: string = '#FFFFFF';
  @StorageLink('pickColorTabIndex') tabindex: number = 0;

  @State r: number = 255;
  @State g: number = 255;
  @State b: number = 255;
  @State rText: string = '255';
  @State gText: string = '255';
  @State bText: string = '255';

  @State hue: number = 0;
  @State sat: number = 0;
  @State val: number = 1;
  @State svW: number = 0;
  @State svH: number = 0;
  @State hueW: number = 0;
  @State hueH: number = 0;

  private originalColor: string = '#FFFFFF';

  private gridColors: string[] = [
    '#FFFFFF', '#F0F0F0', '#D0D0D0', '#909090', '#505050', '#000000',
    '#FF0000', '#FF6600', '#FFAA00', '#FFDD00', '#FFEEAA', '#FFC0CB',
    '#0066FF', '#00AAFF', '#00DDDD', '#99CCFF', '#6666CC', '#000080',
    '#00CC00', '#66CC00', '#CCFF00', '#009900', '#66AA66', '#336633',
    '#FF99CC', '#CC99FF', '#AACCFF', '#99FFCC', '#FFFF99', '#FFCC99'
  ];

  aboutToAppear(): void {
    const hex = this.normalizeHex(this.currentColor);
    this.originalColor = hex;
    this.applyColor(hex);
    this.syncHsvFromRgb();
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

  private toHex(r: number, g: number, b: number): string {
    const rh = Math.round(r).toString(16).padStart(2, '0');
    const gh = Math.round(g).toString(16).padStart(2, '0');
    const bh = Math.round(b).toString(16).padStart(2, '0');
    return `#${rh}${gh}${bh}`.toUpperCase();
  }

  private applyHexToRgb(hex: string): void {
    const h = hex.replace('#', '');
    this.r = parseInt(h.substring(0, 2), 16);
    this.g = parseInt(h.substring(2, 4), 16);
    this.b = parseInt(h.substring(4, 6), 16);
  }

  private rgbToHex(): string {
    return this.toHex(this.r, this.g, this.b);
  }

  private rgbToHsv(r: number, g: number, b: number): number[] {
    const rn = r / 255, gn = g / 255, bn = b / 255;
    const max = Math.max(rn, gn, bn);
    const min = Math.min(rn, gn, bn);
    const d = max - min;
    let h = 0;
    if (d > 0) {
      if (max === rn) h = ((gn - bn) / d) % 6;
      else if (max === gn) h = (bn - rn) / d + 2;
      else h = (rn - gn) / d + 4;
      h *= 60;
      if (h < 0) h += 360;
    }
    const s = max === 0 ? 0 : d / max;
    return [h, s, max];
  }

  private hsvToRgb(h: number, s: number, v: number): number[] {
    let hh = h % 360;
    if (hh < 0) hh += 360;
    const c = v * s;
    const x = c * (1 - Math.abs((hh / 60) % 2 - 1));
    const m = v - c;
    let r1 = 0, g1 = 0, b1 = 0;
    if (hh < 60) { r1 = c; g1 = x; b1 = 0; }
    else if (hh < 120) { r1 = x; g1 = c; b1 = 0; }
    else if (hh < 180) { r1 = 0; g1 = c; b1 = x; }
    else if (hh < 240) { r1 = 0; g1 = x; b1 = c; }
    else if (hh < 300) { r1 = x; g1 = 0; b1 = c; }
    else { r1 = c; g1 = 0; b1 = x; }
    return [
      Math.round((r1 + m) * 255),
      Math.round((g1 + m) * 255),
      Math.round((b1 + m) * 255)
    ];
  }

  private getHueHex(): string {
    const rgb = this.hsvToRgb(this.hue, 1, 1);
    return this.toHex(rgb[0], rgb[1], rgb[2]);
  }

  private applyColor(hex: string): void {
    this.selectedColor = hex;
    this.applyHexToRgb(hex);
    this.rText = this.r.toString();
    this.gText = this.g.toString();
    this.bText = this.b.toString();
    this.onColorSelected(hex);
  }

  private syncHsvFromRgb(): void {
    const hsv = this.rgbToHsv(this.r, this.g, this.b);
    this.hue = hsv[0];
    this.sat = hsv[1];
    this.val = hsv[2];
  }

  private applyHsv(h: number, s: number, v: number): void {
    this.hue = h;
    this.sat = s;
    this.val = v;

    const rgb = this.hsvToRgb(h, s, v);
    this.r = rgb[0];
    this.g = rgb[1];
    this.b = rgb[2];

    this.selectedColor = this.toHex(this.r, this.g, this.b);
    this.rText = this.r.toString();
    this.gText = this.g.toString();
    this.bText = this.b.toString();
    this.onColorSelected(this.selectedColor);
  }

  private confirm(): void {
    this.onClose();
  }

  private cancel(): void {
    this.onColorSelected(this.originalColor);
    this.onClose();
  }

  private clamp01(v: number): number {
    return Math.max(0, Math.min(1, v));
  }

  private applySvPoint(localX: number, localY: number): void {
    if (this.svW <= 0 || this.svH <= 0) return;
    const s = this.clamp01(localX / this.svW);
    const v = this.clamp01(1 - localY / this.svH);
    this.applyHsv(this.hue, s, v);
  }

  private applyHuePoint(localX: number): void {
    if (this.hueW <= 0) return;
    const h = Math.max(0, Math.min(360, localX / this.hueW * 360));
    const s = this.sat < 0.02 ? 1 : this.sat;
    this.applyHsv(h, s, this.val);
  }

  private onSvDotKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) return;

    let step = 0.01;
    try {
      if (event.getModifierKeyState && event.getModifierKeyState(['Shift'])) {
        step = 0.1;
      }
    } catch (err) {}

    let s = this.sat;
    let v = this.val;
    switch (event.keyCode) {
      case KeyCode.KEYCODE_DPAD_LEFT:
        s = this.clamp01(s - step);
        break;
      case KeyCode.KEYCODE_DPAD_RIGHT:
        s = this.clamp01(s + step);
        break;
      case KeyCode.KEYCODE_DPAD_UP:
        v = this.clamp01(v + step);
        break;
      case KeyCode.KEYCODE_DPAD_DOWN:
        v = this.clamp01(v - step);
        break;
      default:
        return;
    }
    event.stopPropagation();
    this.applyHsv(this.hue, s, v);
  }

  private onHueDotKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) return;

    let step = 1;
    try {
      if (event.getModifierKeyState && event.getModifierKeyState(['Shift'])) {
        step = 10;
      }
    } catch (err) {}

    let h = this.hue;
    switch (event.keyCode) {
      case KeyCode.KEYCODE_DPAD_LEFT:
        h = Math.max(0, h - step);
        break;
      case KeyCode.KEYCODE_DPAD_RIGHT:
        h = Math.min(360, h + step);
        break;
      default:
        return;
    }
    event.stopPropagation();
    const s = this.sat < 0.02 ? 1 : this.sat;
    this.applyHsv(h, s, this.val);
  }

  @Builder
  TabButton(label: string, idx: number) {
    Button(label)
      .fontSize(14)
      .fontColor(this.tabindex === idx
        ? $r('sys.color.font_primary')
        : $r('sys.color.font_secondary'))
      .fontWeight(this.tabindex === idx ? FontWeight.Medium : FontWeight.Normal)
      .layoutWeight(1)
      .type(ButtonType.Capsule)
      .height(32)
      .backgroundColor(this.tabindex === idx
        ? $r('sys.color.background_primary')
        : Color.Transparent)
      .onClick(() => {
        if (idx === 2) {
          this.syncHsvFromRgb();
        }
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
    .rowsTemplate('repeat(5, 1fr)')
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
            if (idx === 0) this.r = n;
            else if (idx === 1) this.g = n;
            else this.b = n;
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
          if (idx === 0) this.rText = v;
          else if (idx === 1) this.gText = v;
          else this.bText = v;

          const n = parseInt(v);
          if (!isNaN(n) && n >= 0 && n <= 255) {
            if (idx === 0) this.r = n;
            else if (idx === 1) this.g = n;
            else this.b = n;
            this.applyColor(this.rgbToHex());
          }
        })
    }
    .width('100%')
    .height(40)
  }

  @Builder
  RgbTab() {
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
  SvArea() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(8)
        .linearGradient({
          angle: 90,
          colors: [['#FFFFFF', 0.0], [this.getHueHex(), 1.0]]
        })
      Column()
        .width('100%')
        .height('100%')
        .borderRadius(8)
        .linearGradient({
          angle: 180,
          colors: [['#00000000', 0.0], ['#000000', 1.0]]
        })

      Column() {}
      .width(22)
      .height(22)
      .backgroundColor(this.selectedColor)
      .borderRadius(11)
      .border({
        width: 2,
        color: '#FFFFFF',
        radius: 11
      })
      .position({
        x: this.svW * this.sat - 11,
        y: this.svH * (1 - this.val) - 11
      })
    }
    .width('100%')
    .height(150)
    .borderRadius(8)
    .border({ width: 0.5, color: '#20000000', radius: 8 })
    .responseRegion({
      x: -11,
      y: -11,
      width: this.svW + 22,
      height: this.svH + 22
    })
    .onAreaChange((_o: Area, n: Area) => {
      this.svW = Number(n.width);
      this.svH = Number(n.height);
    })
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1 })
          .onAction((e: GestureEvent) => {
            const f = e.fingerList?.[0];
            if (!f) return;
            this.applySvPoint(f.localX, f.localY);
          }),
        PanGesture({ fingers: 1 })
          .onActionStart((e: GestureEvent) => {
            const f = e.fingerList?.[0];
            if (!f) return;
            this.applySvPoint(f.localX, f.localY);
          })
          .onActionUpdate((e: GestureEvent) => {
            const f = e.fingerList?.[0];
            if (!f) return;
            this.applySvPoint(f.localX, f.localY);
          })
      )
    )
    .focusable(true)
    .onKeyEvent((e: KeyEvent) => this.onSvDotKey(e))
    .focusOnTouch(true)
  }

  @Builder
  HueBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width('100%')
        .height('100%')
        .borderRadius(12)
        .linearGradient({
          angle: 90,
          colors: [
            ['#FF0000', 0.0],
            ['#FFFF00', 1 / 6],
            ['#00FF00', 2 / 6],
            ['#00FFFF', 3 / 6],
            ['#0000FF', 4 / 6],
            ['#FF00FF', 5 / 6],
            ['#FF0000', 1.0]
          ]
        })

      Column() {}
      .width(24)
      .height(24)
      .backgroundColor(this.getHueHex())
      .borderRadius(12)
      .border({
        width: 2,
        color: '#FFFFFF',
        radius: 12
      })
      .position({
        x: this.hueW * (this.hue / 360) - 12,
        y: (this.hueH - 24) / 2
      })
    }
    .width('100%')
    .height(28)
    .responseRegion({
      x: -12,
      y: -2,
      width: this.hueW + 24,
      height: this.hueH + 4
    })
    .onAreaChange((_o: Area, n: Area) => {
      this.hueW = Number(n.width);
      this.hueH = Number(n.height);
    })
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1 })
          .onAction((e: GestureEvent) => {
            const f = e.fingerList?.[0];
            if (!f) return;
            this.applyHuePoint(f.localX);
          }),
        PanGesture({ fingers: 1 })
          .onActionStart((e: GestureEvent) => {
            const f = e.fingerList?.[0];
            if (!f) return;
            this.applyHuePoint(f.localX);
          })
          .onActionUpdate((e: GestureEvent) => {
            const f = e.fingerList?.[0];
            if (!f) return;
            this.applyHuePoint(f.localX);
          })
      )
    )
    .focusable(true)
    .onKeyEvent((e: KeyEvent) => this.onHueDotKey(e))
    .focusOnTouch(true)
  }

  @Builder
  HsvTab() {
    Column({ space: 10 }) {
      this.SvArea()
      this.HueBar()
    }
    .width('100%')
    .height(200)
    .justifyContent(FlexAlign.Center)
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
        this.TabButton('色板', 2)
      }
      .width('100%')
      .padding(3)
      .backgroundColor($r('sys.color.background_tertiary'))
      .borderRadius(19)

      if (this.tabindex === 0) {
        this.GridTab()
      } else if (this.tabindex === 1) {
        this.RgbTab()
      } else {
        this.HsvTab()
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