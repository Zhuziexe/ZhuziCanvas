import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { CursorController, LengthMetricsUnit, promptAction } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { ProjectStore, DrawProject } from '../common/ProjectStore';
import { hdsMaterial, HdsNavDestination } from '@kit.UIDesignKit';
import { PickColorComponent } from '../components/PickColorComponent';
import { KeyCode, pointer } from '@kit.InputKit';

export interface TextParam {
  project: DrawProject;
}

@Concurrent
async function encodeTextToPng(
  pixels: Uint8ClampedArray,
  width: number,
  height: number,
  filePath: string,
  thumbPath: string
): Promise<boolean> {
  try {
    const bgra = new Uint8ClampedArray(pixels.length);
    for (let i = 0; i < pixels.length; i += 4) {
      bgra[i] = pixels[i + 2];
      bgra[i + 1] = pixels[i + 1];
      bgra[i + 2] = pixels[i];
      bgra[i + 3] = pixels[i + 3];
    }

    const pm = await image.createPixelMap(bgra.buffer as ArrayBuffer, {
      size: { width, height },
      srcPixelFormat: image.PixelMapFormat.BGRA_8888,
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      editable: true
    });

    const packer = image.createImagePacker();
    const pngBuffer: ArrayBuffer = await packer.packing(pm, {
      format: 'image/png',
      quality: 100
    });
    const file = fileIo.openSync(filePath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, pngBuffer);
    fileIo.closeSync(file);

    const thumbPm = await image.createPixelMap(bgra.buffer as ArrayBuffer, {
      size: { width, height },
      srcPixelFormat: image.PixelMapFormat.BGRA_8888,
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      editable: true
    });
    const maxSide = Math.max(width, height);
    if (maxSide > 256) {
      const s = 256 / maxSide;
      await thumbPm.scale(s, s);
    }
    const thumbBuffer: ArrayBuffer = await packer.packing(thumbPm, {
      format: 'image/png',
      quality: 80
    });
    const thumbFile = fileIo.openSync(thumbPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(thumbFile.fd, thumbBuffer);
    fileIo.closeSync(thumbFile);

    await packer.release();
    await pm.release();
    await thumbPm.release();
    return true;
  } catch (e) {
    console.error('encodeTextToPng 失败:', e);
    return false;
  }
}

const MAX_OFFSCREEN_SIDE = 4096;

@Component
export struct TextPage {
  @State showColorSheet: boolean = false;
  cursorController: CursorController = this.getUIContext().getCursorController();

  @Prop project: DrawProject;

  @State text: string = '文字';
  @State fontSizePx: number = 64;
  @State color: string = '#FF0000';
  @State textopacity: number = 1.0;
  @State textX: number = 0;
  @State textY: number = 0;
  @State isBusy: boolean = false;
  @State baseUri: string = '';
  @State dispW: number = 0;
  @State dispH: number = 0;
  @State pixelCanvasReady: boolean = false;

  private canvasW: number = 0;
  private canvasH: number = 0;

  private dragBaseX: number = 0;
  private dragBaseY: number = 0;

  private pathStack: NavPathStack = new NavPathStack();

  private offCanvas: OffscreenCanvas | null = null;
  private pixelCtx: OffscreenCanvasRenderingContext2D | null = null;

  aboutToAppear(): void {
    this.canvasW = this.project.width;
    this.canvasH = this.project.height;

    this.initOffscreenCanvas();
    this.loadBaseUri();
  }

  aboutToDisappear(): void {
    this.pixelCtx = null;
    this.offCanvas = null;
    this.pixelCanvasReady = false;
  }

  @Builder
  buildColorSheet(): void {
    PickColorComponent({
      currentColor: this.color,
      onColorSelected: (c: string) => {
        this.color = c;
      },
      onClose:()=>{
        this.showColorSheet = false;
      }
    })
  }

  private initOffscreenCanvas(): void {
    if (this.canvasW <= 0 || this.canvasH <= 0) {
      this.pixelCanvasReady = false;
      return;
    }
    if (this.canvasW > MAX_OFFSCREEN_SIDE || this.canvasH > MAX_OFFSCREEN_SIDE) {
      console.error(`画布尺寸超限: ${this.canvasW}x${this.canvasH}`);
      this.pixelCanvasReady = false;
      return;
    }

    try {
      this.offCanvas = new OffscreenCanvas(
        this.canvasW,
        this.canvasH,
        LengthMetricsUnit.PX
      );
      this.pixelCtx = this.offCanvas.getContext('2d',
        new RenderingContextSettings(false));
      this.pixelCanvasReady = this.pixelCtx !== null;
    } catch (e) {
      console.error('创建离屏画布失败:', e);
      this.offCanvas = null;
      this.pixelCtx = null;
      this.pixelCanvasReady = false;
    }
  }

  private loadBaseUri(): void {
    try {
      const path = ProjectStore.getImagePath(this.project.id);
      if (fileIo.accessSync(path)) {
        this.baseUri = fileUri.getUriFromPath(path);
      } else {
        this.baseUri = '';
      }
    } catch (e) {
      this.baseUri = '';
    }
  }

  private openColorPicker(): void {
    this.showColorSheet =true;
  }

  private clampTextPosition(): void {
    const maxX = Math.max(0, this.dispW - 30);
    const maxY = Math.max(0, this.dispH - 30);
    this.textX = Math.max(0, Math.min(maxX, this.textX));
    this.textY = Math.max(0, Math.min(maxY, this.textY));
  }

  private async confirm(): Promise<void> {
    if (this.isBusy) return;
    if (this.text.length === 0) {
      promptAction.openToast({ message: '请输入文字' }).catch(() => {});
      return;
    }
    if (!this.pixelCanvasReady || this.dispW <= 0) {
      promptAction.openToast({ message: '画布未就绪' }).catch(() => {});
      return;
    }

    const ctx = this.pixelCtx;
    if (!ctx) {
      promptAction.openToast({ message: '画布未就绪' }).catch(() => {});
      return;
    }

    this.isBusy = true;
    try {
      const path = ProjectStore.getImagePath(this.project.id);
      ctx.clearRect(0, 0, this.canvasW, this.canvasH);

      if (fileIo.accessSync(path)) {
        const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        const imageSource = image.createImageSource(file.fd);
        const pixelMap = await imageSource.createPixelMap();
        ctx.drawImage(pixelMap, 0, 0, this.canvasW, this.canvasH);
        await pixelMap.release();
        await imageSource.release();
        fileIo.closeSync(file);
      } else {
        ctx.fillStyle = '#FFFFFF';
        ctx.fillRect(0, 0, this.canvasW, this.canvasH);
      }

      const ratio = this.canvasW / this.dispW;
      const px = this.textX * ratio;
      const py = this.textY * ratio;

      ctx.save();
      ctx.globalAlpha = this.textopacity;
      ctx.fillStyle = this.color;
      ctx.font = `${this.fontSizePx}px sans-serif`;
      ctx.textBaseline = 'top';
      ctx.fillText(this.text, px, py);
      ctx.restore();

      const data = ctx.getImageData(0, 0, this.canvasW, this.canvasH);
      const pixels = new Uint8ClampedArray(data.data);

      const thumbPath = ProjectStore.getThumbPath(this.project.id);
      const task = new taskpool.Task(
        encodeTextToPng, pixels, this.canvasW, this.canvasH, path, thumbPath
      );
      const ok = await taskpool.execute(task) as boolean;

      if (ok) {
        const updated: DrawProject = {
          id: this.project.id,
          name: this.project.name,
          width: this.canvasW,
          height: this.canvasH,
          createdAt: this.project.createdAt,
          updatedAt: Date.now()
        };
        await ProjectStore.upsert(updated);
        AppStorage.setOrCreate('projectsRefreshToken', Date.now());
        promptAction.openToast({ message: '已添加文字' }).catch(() => {});
        this.pathStack.pop();
      } else {
        promptAction.openToast({ message: '保存失败' }).catch(() => {});
      }
    } catch (e) {
      console.error('添加文字失败:', e);
      promptAction.openToast({ message: '添加失败' }).catch(() => {});
    } finally {
      this.isBusy = false;
    }
  }

  private handleArrowKey(event: KeyEvent): void {
    if (event.type !== KeyType.Down) return;
    if (this.dispW <= 0 || this.dispH <= 0) return;

    let step = 1;
    try {
      if (event.getModifierKeyState && event.getModifierKeyState(['Shift'])) {
        step = 10;
      }
    }catch(err){
      console.error('无法getModifierKeyState');
    }

    switch (event.keyCode) {
      case KeyCode.KEYCODE_DPAD_LEFT:
        this.textX -= step;
        break;
      case KeyCode.KEYCODE_DPAD_RIGHT:
        this.textX += step;
        break;
      case KeyCode.KEYCODE_DPAD_UP:
        this.textY -= step;
        break;
      case KeyCode.KEYCODE_DPAD_DOWN:
        this.textY += step;
        break;
      default:
        return;
    }
    this.clampTextPosition();
    event.stopPropagation();
  }

  @Builder
  PreviewArea() {
    Stack({ alignContent: Alignment.TopStart }) {
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.baseUri.length > 0) {
          Image(this.baseUri)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
            .draggable(false)
        } else {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#FFFFFF')
        }
      }
      .width(this.dispW > 0 ? `${this.dispW}vp` : '100%')
      .height(this.dispH > 0 ? `${this.dispH}vp` : '100%')
      .clip(true)
      .backgroundColor('#FFFFFF')
      .border({ width: 1, color: '#10000000' })
      .shadow({
        radius: 16,
        color: 'rgba(0, 0, 0, 0.10)',
        offsetX: 0,
        offsetY: 4
      })

      if (this.text.length > 0 && this.dispW > 0) {
        Text(this.text)
          .fontSize(this.fontSizePx * this.dispW / this.canvasW)
          .fontColor(this.color)
          .opacity(this.textopacity)
          .position({ x: this.textX, y: this.textY })
          .draggable(false)
          .border({ width: 2, color: $r('app.color.brand') })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.None })
          .gesture(
            PanGesture({ fingers: 1 })
              .onActionStart(() => {
                this.dragBaseX = this.textX;
                this.dragBaseY = this.textY;
              })
              .onActionUpdate((e: GestureEvent) => {
                this.textX = this.dragBaseX + e.offsetX;
                this.textY = this.dragBaseY + e.offsetY;
                this.clampTextPosition();
              })
          )
          .onHover((isHover: boolean) => {
            if (isHover) {
              this.cursorController.setCursor(pointer.PointerStyle.MOVE);
            } else {
              this.cursorController.restoreDefault();
            }
          })

          .focusable(true)
          .focusOnTouch(true)
          .id('overlayText')
          .onAppear(() => {
            setTimeout(() => {
              try {
                this.getUIContext()
                  .getFocusController()
                  .requestFocus('overlayText');
              } catch (error) {
                console.error(`无法requestFocus: ${error}`)
              }
            }, 50);
          })
          .onKeyEvent((event: KeyEvent) => {
            this.handleArrowKey(event);
          })
      }
    }
    .width(this.dispW > 0 ? `${this.dispW}vp` : '100%')
    .height(this.dispH > 0 ? `${this.dispH}vp` : '100%')
  }

  @Builder
  buildControls(): void {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text('文字')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .width(48)
        TextInput({ text: this.text, placeholder: '输入要添加的文字' })
          .layoutWeight(1)
          .onChange((v: string) => {
            this.text = v;
          })
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('大小')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .width(48)
        Slider({ value: this.fontSizePx, min: 12, max: 400, step: 1 })
          .selectedColor($r('app.color.brand'))
          .layoutWeight(1)
          .onChange((v: number) => {
            this.fontSizePx = Math.round(v);
          })
        Text(`${this.fontSizePx}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('不透明')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .width(48)
        Slider({ value: this.textopacity * 100, min: 10, max: 100, step: 1 })
          .selectedColor($r('app.color.brand'))
          .layoutWeight(1)
          .onChange((v: number) => {
            this.textopacity = v / 100;
          })
        Text(`${Math.round(this.textopacity * 100)}%`)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
          .width(40)
          .textAlign(TextAlign.End)
      }
      .width('100%')

      Row({ space: 8 }) {
        Text('颜色')
          .fontSize(14)
          .fontColor($r('sys.color.font_primary'))
          .width(48)
        Button() {
          Row({ space: 10 }) {
            Column()
              .height(28)
              .borderRadius(14)
              .backgroundColor(this.color)
              .border({ width: 1, color: '#20000000' })
              .layoutWeight(1)
            Text(this.color)
              .fontSize(13)
              .fontColor($r('sys.color.font_secondary'))
          }
          .width('100%')
        }
        .padding(4)
        .layoutWeight(1)
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .onClick(() => {
          this.openColorPicker();
        })
        .bindSheet(this.showColorSheet,this.buildColorSheet(),{
          preferType: SheetType.POPUP,
          height: SheetSize.FIT_CONTENT,
          enableOutsideInteractive:false,
          dragBar: false,
          showClose: false,
          backgroundColor: $r('sys.color.background_primary'),
          onDisappear: () => {
            this.showColorSheet = false;
          }
        })
      }
      .width('100%')

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontColor($r('app.color.brand'))
          .onClick(() => this.pathStack.pop())

        Button('添加')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
          .backgroundColor($r('app.color.brand'))
          .enabled(!this.isBusy)
          .onClick(() => this.confirm())
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .backgroundColor($r('sys.color.background_primary'))
  }

  build() {
    HdsNavDestination() {
        Column() {
          Column() {
            if (this.dispW > 0) {
              this.PreviewArea()
            }
          }
          .width('100%')
          .layoutWeight(1)
          .padding(16)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .onAreaChange((_o: Area, n: Area) => {
            const availW = Number(n.width) - 32;
            const availH = Number(n.height) - 32;
            if (availW <= 0 || availH <= 0) return;

            const canvasRatio = this.canvasW / this.canvasH;
            const availRatio = availW / availH;
            if (availRatio > canvasRatio) {
              this.dispH = availH;
              this.dispW = availH * canvasRatio;
            } else {
              this.dispW = availW;
              this.dispH = availW / canvasRatio;
            }

            if (this.textX === 0 && this.textY === 0 && this.dispW > 0) {
              this.textX = this.dispW / 4;
              this.textY = this.dispH / 2 - 20;
            }
          })

          this.buildControls();
        }
        .width('100%')
        .height('100%')
    }
    .titleBar({
      style: {
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: { mainTitle: '添加文字' }
      },
      enableComponentSafeArea: true
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}