import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { taskpool } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { ProjectStore, DrawProject } from '../common/ProjectStore';
import { hdsMaterial, HdsNavDestination } from '@kit.UIDesignKit';

export interface ImageOverlayParam {
  project: DrawProject;
  overlayUri: string;
}

@Concurrent
function compositeOverlayTask(
  baseBuffer: ArrayBuffer,
  baseW: number, baseH: number,
  overlayBuffer: ArrayBuffer,
  overlayW: number, overlayH: number,
  offsetX: number, offsetY: number,
  scale: number
): ArrayBuffer {
  const base = new Uint8ClampedArray(baseBuffer);
  const overlay = new Uint8ClampedArray(overlayBuffer);
  const result = new Uint8ClampedArray(base.length);
  result.set(base);

  const drawW = overlayW * scale;
  const drawH = overlayH * scale;

  const x0 = Math.max(0, Math.floor(offsetX));
  const y0 = Math.max(0, Math.floor(offsetY));
  const x1 = Math.min(baseW, Math.ceil(offsetX + drawW));
  const y1 = Math.min(baseH, Math.ceil(offsetY + drawH));

  for (let y = y0; y < y1; y++) {
    const oy = (y + 0.5 - offsetY) / scale;
    const iy = Math.floor(oy);
    if (iy < 0 || iy >= overlayH) continue;

    for (let x = x0; x < x1; x++) {
      const ox = (x + 0.5 - offsetX) / scale;
      const ix = Math.floor(ox);
      if (ix < 0 || ix >= overlayW) continue;

      const oi = (iy * overlayW + ix) * 4;
      const oa = overlay[oi + 3] / 255;
      if (oa === 0) continue;

      const bi = (y * baseW + x) * 4;
      const ba = base[bi + 3] / 255;
      const outA = oa + ba * (1 - oa);
      if (outA === 0) continue;

      result[bi]     = Math.round((overlay[oi]     * oa + base[bi]     * ba * (1 - oa)) / outA);
      result[bi + 1] = Math.round((overlay[oi + 1] * oa + base[bi + 1] * ba * (1 - oa)) / outA);
      result[bi + 2] = Math.round((overlay[oi + 2] * oa + base[bi + 2] * ba * (1 - oa)) / outA);
      result[bi + 3] = Math.round(outA * 255);
    }
  }

  return result.buffer as ArrayBuffer;
}

@Component
export struct ImageOverlayPage {
  @Prop project: DrawProject = {
    id: '', name: '', width: 1280, height: 720,
    createdAt: 0, updatedAt: 0
  };
  @Prop overlayUri: string = '';

  @State offsetX: number = 0;      // 画板像素坐标下的偏移
  @State offsetY: number = 0;
  @State overlayScale: number = 1;
  @State overlayW: number = 0;
  @State overlayH: number = 0;
  @State displayScale: number = 1; // 画板 vp -> 屏幕 vp
  @State containerW: number = 0;
  @State containerH: number = 0;
  @State overlayReady: boolean = false;
  @State isSaving: boolean = false;

  private panBaseX: number = 0;
  private panBaseY: number = 0;

  private pathStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    this.initOverlay();
  }

  private async initOverlay(): Promise<void> {
    let file: fileIo.File | null = null;
    let src: image.ImageSource | null = null;
    try {
      file = fileIo.openSync(this.overlayUri, fileIo.OpenMode.READ_ONLY);
      src = image.createImageSource(file.fd);
      const info = await src.getImageInfo();
      this.overlayW = info.size.width;
      this.overlayH = info.size.height;

      const fit = Math.min(
        (this.project.width * 0.5) / this.overlayW,
        (this.project.height * 0.5) / this.overlayH
      );
      this.overlayScale = Math.min(1, Math.max(0.1, fit));

      const dw = this.overlayW * this.overlayScale;
      const dh = this.overlayH * this.overlayScale;
      this.offsetX = Math.round((this.project.width - dw) / 2);
      this.offsetY = Math.round((this.project.height - dh) / 2);

      this.overlayReady = true;
    } catch (e) {
      console.error('初始化叠加图片失败:', e);
      promptAction.openToast({ message: '读取图片失败' }).catch(() => {});
    } finally {
      if (src) { try { src.release(); } catch {} }
      if (file) { try { fileIo.closeSync(file); } catch {} }
    }
  }

  private getProjectImageUri(): string {
    const p = ProjectStore.getImagePath(this.project.id);
    try {
      if (fileIo.accessSync(p)) {
        return fileUri.getUriFromPath(p);
      }
    } catch {}
    return '';
  }

  private updateDisplayScale(): void {
    if (this.containerW <= 0 || this.containerH <= 0) return;
    const cw = px2vp(this.project.width);
    const ch = px2vp(this.project.height);
    const availW = this.containerW - 32;
    const availH = this.containerH - 32;
    this.displayScale = Math.min(availW / cw, availH / ch);
  }

  private async loadPngAsRgba(path: string, w: number, h: number): Promise<ArrayBuffer | null> {
    let file: fileIo.File | null = null;
    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;
    try {
      file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      src = image.createImageSource(file.fd);
      pm = await src.createPixelMap();

      const info = await pm.getImageInfo();
      if (info.size.width !== w || info.size.height !== h) {
        await pm.scale(w / info.size.width, h / info.size.height);
      }

      const buf = new ArrayBuffer(w * h * 4);
      await pm.readPixelsToBuffer(buf);
      return buf;
    } catch (e) {
      console.error('加载图片失败:', e);
      return null;
    } finally {
      if (pm) { try { pm.release(); } catch {} }
      if (src) { try { src.release(); } catch {} }
      if (file) { try { fileIo.closeSync(file); } catch {} }
    }
  }

  private async saveRgbaToPng(buf: ArrayBuffer, w: number, h: number, path: string): Promise<boolean> {
    let pm: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const rgba = new Uint8ClampedArray(buf);
      const bgra = new Uint8ClampedArray(rgba.length);
      for (let i = 0; i < rgba.length; i += 4) {
        bgra[i]     = rgba[i + 2];
        bgra[i + 1] = rgba[i + 1];
        bgra[i + 2] = rgba[i];
        bgra[i + 3] = rgba[i + 3];
      }

      pm = await image.createPixelMap(bgra.buffer as ArrayBuffer, {
        size: { width: w, height: h },
        srcPixelFormat: image.PixelMapFormat.BGRA_8888,
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        editable: false
      });

      packer = image.createImagePacker();
      const png = await packer.packing(pm, { format: 'image/png', quality: 100 });
      const f = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, png);
      fileIo.closeSync(f);
      return true;
    } catch (e) {
      console.error('保存 PNG 失败:', e);
      return false;
    } finally {
      if (packer) { try { await packer.release(); } catch {} }
      if (pm) { try { await pm.release(); } catch {} }
    }
  }

  private async updateThumb(buf: ArrayBuffer, w: number, h: number): Promise<void> {
    let pm: image.PixelMap | null = null;
    let packer: image.ImagePacker | null = null;
    try {
      const rgba = new Uint8ClampedArray(buf);
      const bgra = new Uint8ClampedArray(rgba.length);
      for (let i = 0; i < rgba.length; i += 4) {
        bgra[i]     = rgba[i + 2];
        bgra[i + 1] = rgba[i + 1];
        bgra[i + 2] = rgba[i];
        bgra[i + 3] = rgba[i + 3];
      }

      pm = await image.createPixelMap(bgra.buffer as ArrayBuffer, {
        size: { width: w, height: h },
        srcPixelFormat: image.PixelMapFormat.BGRA_8888,
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        editable: true
      });

      const maxSide = Math.max(w, h);
      if (maxSide > 256) {
        const s = 256 / maxSide;
        await pm.scale(s, s);
      }

      packer = image.createImagePacker();
      const tb = await packer.packing(pm, { format: 'image/png', quality: 80 });
      const thumbPath = ProjectStore.getThumbPath(this.project.id);
      const tf = fileIo.openSync(thumbPath,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(tf.fd, tb);
      fileIo.closeSync(tf);
    } catch (e) {
      console.warn('更新缩略图失败:', e);
    } finally {
      if (packer) { try { await packer.release(); } catch {} }
      if (pm) { try { await pm.release(); } catch {} }
    }
  }

  private async handleConfirm(): Promise<void> {
    if (this.isSaving || !this.overlayReady) return;
    this.isSaving = true;

    try {
      const W = this.project.width;
      const H = this.project.height;
      const basePath = ProjectStore.getImagePath(this.project.id);

      const baseBuf = await this.loadPngAsRgba(basePath, W, H);
      if (!baseBuf) {
        promptAction.openToast({ message: '读取画板失败' }).catch(() => {});
        return;
      }

      const overlayBuf = await this.loadPngAsRgba(this.overlayUri, this.overlayW, this.overlayH);
      if (!overlayBuf) {
        promptAction.openToast({ message: '读取图片失败' }).catch(() => {});
        return;
      }

      const task = new taskpool.Task(
        compositeOverlayTask,
        baseBuf, W, H,
        overlayBuf, this.overlayW, this.overlayH,
        this.offsetX, this.offsetY,
        this.overlayScale
      );
      task.setTransferList([baseBuf, overlayBuf]);

      const resultBuf = await taskpool.execute(task) as ArrayBuffer;

      const saved = await this.saveRgbaToPng(resultBuf, W, H, basePath);
      if (!saved) {
        promptAction.openToast({ message: '保存失败' }).catch(() => {});
        return;
      }

      await this.updateThumb(resultBuf, W, H);

      const updated: DrawProject = {
        id: this.project.id,
        name: this.project.name,
        width: this.project.width,
        height: this.project.height,
        createdAt: this.project.createdAt,
        updatedAt: Date.now()
      };
      await ProjectStore.upsert(updated);

      AppStorage.setOrCreate('projectsRefreshToken', Date.now());

      promptAction.openToast({ message: '已叠加' }).catch(() => {});
      this.pathStack.pop();
    } catch (e) {
      console.error('叠加失败:', e);
      promptAction.openToast({ message: '叠加失败' }).catch(() => {});
    } finally {
      this.isSaving = false;
    }
  }

  @Builder
  PreviewArea() {
    Stack() {
      Image(this.getProjectImageUri())
        .width('100%')
        .height('100%')
        .objectFit(ImageFit.Fill)
        .draggable(false)
        .interpolation(ImageInterpolation.Medium)

      if (this.overlayReady) {
        Image(this.overlayUri)
          .width(px2vp(this.overlayW * this.overlayScale) * this.displayScale)
          .height(px2vp(this.overlayH * this.overlayScale) * this.displayScale)
          .position({ x: 0, y: 0 })
          .translate({
            x: px2vp(this.offsetX) * this.displayScale,
            y: px2vp(this.offsetY) * this.displayScale
          })
          .border({
            width:2,
            color:$r('app.color.brand')
          })
          .draggable(false)
          .interpolation(ImageInterpolation.Medium)
          .gesture(
            PanGesture({ fingers: 1 })
              .onActionStart(() => {
                this.panBaseX = this.offsetX;
                this.panBaseY = this.offsetY;
              })
              .onActionUpdate((e: GestureEvent) => {
                this.offsetX = this.panBaseX + vp2px(e.offsetX) / this.displayScale;
                this.offsetY = this.panBaseY + vp2px(e.offsetY) / this.displayScale;
              })
              .onActionEnd(() => {
                this.panBaseX = this.offsetX;
                this.panBaseY = this.offsetY;
              })
          )
      }
    }
    .width(px2vp(this.project.width) * this.displayScale)
    .height(px2vp(this.project.height) * this.displayScale)
    .clip(true)
    .backgroundColor($r('sys.color.background_tertiary'))
  }

  build() {
    HdsNavDestination() {
      Column() {
        Column() {
          if (this.overlayReady && this.displayScale > 0) {
            this.PreviewArea()
          }
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding(16)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.containerW = Number(newArea.width);
          this.containerH = Number(newArea.height);
          this.updateDisplayScale();
        })

        Column({ space: 16 }) {
          Row({ space: 12 }) {
            Text('大小')
              .fontSize(14)
              .fontColor($r('sys.color.font_secondary'))
              .width(40)
            Slider({
              min: 10,
              max: 500,
              value: Math.round(this.overlayScale * 100),
              step: 1,
              style: SliderStyle.InSet
            })
              .selectedColor($r('app.color.brand'))
              .layoutWeight(1)
              .onChange((v: number) => {
                const newScale = v / 100;
                const oldDw = this.overlayW * this.overlayScale;
                const oldDh = this.overlayH * this.overlayScale;
                const cx = this.offsetX + oldDw / 2;
                const cy = this.offsetY + oldDh / 2;
                this.overlayScale = newScale;
                const newDw = this.overlayW * newScale;
                const newDh = this.overlayH * newScale;
                this.offsetX = cx - newDw / 2;
                this.offsetY = cy - newDh / 2;
              })
            Text(`${Math.round(this.overlayScale * 100)}%`)
              .fontSize(12)
              .fontColor($r('app.color.brand'))
              .width(48)
              .textAlign(TextAlign.End)
          }
          .width('100%')

          Row({ space: 12 }) {
            Button('取消')
              .layoutWeight(1)
              .buttonStyle(ButtonStyleMode.NORMAL)
              .fontColor($r('app.color.brand'))
              .enabled(!this.isSaving)
              .onClick(() => {
                this.pathStack.pop();
              })
            Button(this.isSaving ? '保存中…' : '确定')
              .layoutWeight(1)
              .buttonStyle(ButtonStyleMode.EMPHASIZED)
              .backgroundColor($r('app.color.brand'))
              .enabled(!this.isSaving && this.overlayReady)
              .onClick(() => {
                this.handleConfirm();
              })
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 24, right: 24, top: 16, bottom: 16 })
        .backgroundColor($r('sys.color.background_primary'))
        .borderRadius({ topLeft: 16, topRight: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_primary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .titleBar({
      content: {
        title: {
          mainTitle: '叠加图片'
        }
      },
      enableComponentSafeArea: true,
      style:{
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
  }
}