import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { curves, LengthMetricsUnit, promptAction } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { ProjectStore, DrawProject } from '../common/ProjectStore';
import { hdsMaterial, HdsNavDestination } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { PickColorDialog } from '../dialogs/PickColorDialog';
import { LoadingDialog } from '../dialogs/LoadingDialog';

type ToolMode = 'brush' | 'eraser' | 'picker' | 'fill' | 'pan';

const MAX_UNDO = 5;
const MAX_REDO = 5;

interface UndoPatch {
  x: number;
  y: number;
  w: number;
  h: number;
  oldPixels: Uint8ClampedArray;
  newPixels: Uint8ClampedArray;
}

@Concurrent
async function encodePixelsToPng(
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
      size: { width: width, height: height },
      srcPixelFormat: image.PixelMapFormat.BGRA_8888,
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      editable: true
    });

    const packer = image.createImagePacker();
    const packOpts: image.PackingOption = {
      format: 'image/png',
      quality: 100
    };
    const pngBuffer: ArrayBuffer = await packer.packing(pm, packOpts);
    const file = fileIo.openSync(filePath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, pngBuffer);
    fileIo.closeSync(file);

    const thumbPm = await image.createPixelMap(bgra.buffer as ArrayBuffer, {
      size: { width: width, height: height },
      srcPixelFormat: image.PixelMapFormat.BGRA_8888,
      pixelFormat: image.PixelMapFormat.BGRA_8888,
      editable: true
    });
    const maxSide = Math.max(width, height);
    if (maxSide > 256) {
      const s = 256 / maxSide;
      await thumbPm.scale(s, s);
    }
    const thumbOpts: image.PackingOption = {
      format: 'image/png',
      quality: 80
    };
    const thumbBuffer: ArrayBuffer = await packer.packing(thumbPm, thumbOpts);
    const thumbFile = fileIo.openSync(thumbPath,
      fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(thumbFile.fd, thumbBuffer);
    fileIo.closeSync(thumbFile);

    await packer.release();
    await pm.release();
    await thumbPm.release();
    return true;
  } catch (e) {
    console.error('encodePixelsToPng 失败:', e);
    return false;
  }
}

@Concurrent
function floodFillTask(
  pixelBuffer: ArrayBuffer,
  width: number,
  height: number,
  startLx: number,
  startLy: number,
  fillR: number,
  fillG: number,
  fillB: number,
  tol: number
): ArrayBuffer {
  const src = new Uint8ClampedArray(pixelBuffer);
  const W = width;
  const H = height;

  if (startLx < 0 || startLy < 0 || startLx >= W || startLy >= H) {
    const out = new ArrayBuffer(src.length);
    new Uint8ClampedArray(out).set(src);
    return out;
  }

  const startIdx = (startLy * W + startLx) * 4;
  const tR = src[startIdx];
  const tG = src[startIdx + 1];
  const tB = src[startIdx + 2];
  const tA = src[startIdx + 3];

  if (Math.abs(tR - fillR) <= tol &&
    Math.abs(tG - fillG) <= tol &&
    Math.abs(tB - fillB) <= tol &&
    tA === 255) {
    const out = new ArrayBuffer(src.length);
    new Uint8ClampedArray(out).set(src);
    return out;
  }

  const visited = new Uint8Array(W * H);

  const STACK_SIZE = W * 16;
  let stack = new Int32Array(STACK_SIZE);
  let sp = 0;

  const push = (x: number, y: number): void => {
    if (sp + 2 > stack.length) {
      const bigger = new Int32Array(stack.length * 2);
      bigger.set(stack);
      stack = bigger;
    }
    stack[sp++] = x;
    stack[sp++] = y;
  };

  push(startLx, startLy);

  while (sp > 0) {
    sp--;
    const y = stack[sp];
    sp--;
    let x = stack[sp];

    while (x >= 0 && visited[y * W + x] === 0) {
      const idx = (y * W + x) * 4;
      if (Math.abs(src[idx] - tR) > tol ||
        Math.abs(src[idx + 1] - tG) > tol ||
        Math.abs(src[idx + 2] - tB) > tol ||
        Math.abs(src[idx + 3] - tA) > tol) {
        break;
      }
      x--;
    }
    x++;

    let spanAbove = false;
    let spanBelow = false;

    while (x < W && visited[y * W + x] === 0) {
      const idx = (y * W + x) * 4;
      if (Math.abs(src[idx] - tR) > tol ||
        Math.abs(src[idx + 1] - tG) > tol ||
        Math.abs(src[idx + 2] - tB) > tol ||
        Math.abs(src[idx + 3] - tA) > tol) {
        break;
      }
      visited[y * W + x] = 1;

      if (y > 0) {
        const aboveIdx = (y - 1) * W + x;
        if (visited[aboveIdx] === 0) {
          const ai = aboveIdx * 4;
          const match = Math.abs(src[ai] - tR) <= tol &&
            Math.abs(src[ai + 1] - tG) <= tol &&
            Math.abs(src[ai + 2] - tB) <= tol &&
            Math.abs(src[ai + 3] - tA) <= tol;
          if (match && !spanAbove) {
            push(x, y - 1);
            spanAbove = true;
          } else if (!match) {
            spanAbove = false;
          }
        } else {
          spanAbove = false;
        }
      }

      if (y < H - 1) {
        const belowIdx = (y + 1) * W + x;
        if (visited[belowIdx] === 0) {
          const bi = belowIdx * 4;
          const match = Math.abs(src[bi] - tR) <= tol &&
            Math.abs(src[bi + 1] - tG) <= tol &&
            Math.abs(src[bi + 2] - tB) <= tol &&
            Math.abs(src[bi + 3] - tA) <= tol;
          if (match && !spanBelow) {
            push(x, y + 1);
            spanBelow = true;
          } else if (!match) {
            spanBelow = false;
          }
        } else {
          spanBelow = false;
        }
      }

      x++;
    }
  }

  const outBuffer = new ArrayBuffer(src.length);
  const out = new Uint8ClampedArray(outBuffer);
  out.set(src);

  for (let i = 0; i < W * H; i++) {
    if (visited[i] === 1) {
      const di = i * 4;
      out[di] = fillR;
      out[di + 1] = fillG;
      out[di + 2] = fillB;
      out[di + 3] = 255;
    }
  }

  return outBuffer;
}

@Component
export struct EditorPage {
  @Prop project: DrawProject = {
    id: '', name: '', width: 1280, height: 720,
    createdAt: 0, updatedAt: 0
  };

  @StorageProp('windowWidth') windowWidth: number = 0;

  @State isPressingTool: boolean = false;
  @State isPressingDoBar: boolean = false;
  @State toolMode: ToolMode = 'brush';
  @State userScale: number = 1;
  @State pinchBase: number = 1;
  @State displayScale: number = 1;
  @State strokeWidth: number = 10;
  @State fillTol: number = 32;
  @State color: string = '#000000';
  @State isPinching: boolean = false;
  @State isDirty: boolean = false;
  @State isFilling: boolean = false;
  @State canUndo: boolean = false;
  @State canRedo: boolean = false;
  @State isBusy: boolean = false;

  @State pickerX: number = 0;
  @State pickerY: number = 0;
  @State showPickerPreview: boolean = false;

  @State outerW: number = 0;
  @State outerH: number = 0;

  @State offsetX: number = 0;
  @State offsetY: number = 0;

  private masterBuffer: ArrayBuffer | null = null;
  private masterReady: boolean = false;

  private undoStack: UndoPatch[] = [];
  private redoStack: UndoPatch[] = [];

  private brushMinX: number = 0;
  private brushMinY: number = 0;
  private brushMaxX: number = 0;
  private brushMaxY: number = 0;

  private pickerHideTimer: number = -1;
  private panBaseX: number = 0;
  private panBaseY: number = 0;

  private panStartX: number = 0;
  private panStartY: number = 0;
  private isPanning: boolean = false;

  private pathStack: NavPathStack = new NavPathStack();
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private setting: RenderingContextSettings = new RenderingContextSettings(false);
  private canvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.setting, LengthMetricsUnit.PX);

  private lastX: number = 0;
  private lastY: number = 0;
  private isStroking: boolean = false;
  private curColor: string = '#000000';
  private curWidth: number = 10;
  private curIsEraser: boolean = false;

  private fillDownX: number = 0;
  private fillDownY: number = 0;
  private fillDownValid: boolean = false;

  private colorDialogController: CustomDialogController | null = null;
  private loadingDialogController: CustomDialogController | null = null;
  private isImageLoaded: boolean = false;

  aboutToAppear(): void {
    this.colorDialogController = new CustomDialogController({
      builder: PickColorDialog({
        currentColor: this.color,
        onColorSelected: (color: string) => {
          this.color = color;
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Bottom
    });
  }

  aboutToDisappear(): void {
    console.info('[EditorPage] aboutToDisappear triggered');
    if (this.pickerHideTimer !== -1) {
      clearTimeout(this.pickerHideTimer);
      this.pickerHideTimer = -1;
    }
    this.masterBuffer = null;
    this.undoStack = [];
    this.redoStack = [];
    AppStorage.setOrCreate('projectsRefreshToken', Date.now());
  }

  private isWideScreen(): boolean {
    return this.windowWidth >= 600;
  }

  private showLoading(message: string): void {
    this.loadingDialogController = new CustomDialogController({
      builder: LoadingDialog({ message: message }),
      autoCancel: false,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    this.loadingDialogController.open();
  }

  private hideLoading(): void {
    if (this.loadingDialogController) {
      this.loadingDialogController.close();
      this.loadingDialogController = null;
    }
  }

  private hexToRgb(hex: string): number[] {
    const h = hex.replace('#', '');
    if (h.length !== 6) {
      return [0, 0, 0];
    }
    return [
      parseInt(h.substring(0, 2), 16),
      parseInt(h.substring(2, 4), 16),
      parseInt(h.substring(4, 6), 16)
    ];
  }

  private rgbToHex(r: number, g: number, b: number): string {
    const rh = r.toString(16).padStart(2, '0');
    const gh = g.toString(16).padStart(2, '0');
    const bh = b.toString(16).padStart(2, '0');
    return `#${rh}${gh}${bh}`.toUpperCase();
  }

  private clampScale(s: number): number {
    return Math.max(0.2, Math.min(8, s));
  }

  private clampOffset(): void {
    const scale = this.displayScale * this.userScale;
    const cw = px2vp(this.project.width) * scale;
    const ch = px2vp(this.project.height) * scale;
    const margin = 80;
    const maxX = Math.max(0, (cw + this.outerW) / 2 - margin);
    const maxY = Math.max(0, (ch + this.outerH) / 2 - margin);
    this.offsetX = Math.max(-maxX, Math.min(maxX, this.offsetX));
    this.offsetY = Math.max(-maxY, Math.min(maxY, this.offsetY));
  }

  private readCanvasRegion(
    lx: number, ly: number, lw: number, lh: number
  ): Uint8ClampedArray | null {
    try {
      const imgData: ImageData = this.canvasCtx.getImageData(lx, ly, lw, lh);
      return new Uint8ClampedArray(imgData.data);
    } catch (e) {
      console.error('读区域失败:', e);
      return null;
    }
  }

  private async renderMasterToCanvas(): Promise<boolean> {
    if (!this.masterBuffer) return false;
    try {
      const W = this.project.width;
      const H = this.project.height;

      const rgba = new Uint8ClampedArray(this.masterBuffer);
      const bgra = new Uint8ClampedArray(rgba.length);
      for (let i = 0; i < rgba.length; i += 4) {
        bgra[i] = rgba[i + 2];
        bgra[i + 1] = rgba[i + 1];
        bgra[i + 2] = rgba[i];
        bgra[i + 3] = rgba[i + 3];
      }

      const pm = await image.createPixelMap(bgra.buffer as ArrayBuffer, {
        size: { width: W, height: H },
        srcPixelFormat: image.PixelMapFormat.BGRA_8888,
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        editable: false
      });

      this.canvasCtx.save();
      this.canvasCtx.globalCompositeOperation = 'source-over';
      this.canvasCtx.globalAlpha = 1;
      this.canvasCtx.clearRect(0, 0, W, H);
      this.canvasCtx.drawImage(pm, 0, 0, W, H);
      this.canvasCtx.restore();

      await pm.release();
      return true;
    } catch (e) {
      console.error('重绘失败:', e);
      return false;
    }
  }

  private commitPatch(
    lx: number, ly: number, lw: number, lh: number,
    oldPixels: Uint8ClampedArray,
    newPixels: Uint8ClampedArray
  ): void {
    if (!this.masterBuffer) return;
    const W = this.project.width;
    const master = new Uint8ClampedArray(this.masterBuffer);

    for (let row = 0; row < lh; row++) {
      const dstOff = ((ly + row) * W + lx) * 4;
      const srcOff = row * lw * 4;
      master.set(newPixels.subarray(srcOff, srcOff + lw * 4), dstOff);
    }

    let hasChange = false;
    for (let i = 0; i < newPixels.length; i++) {
      if (newPixels[i] !== oldPixels[i]) {
        hasChange = true;
        break;
      }
    }
    if (!hasChange) return;

    this.undoStack.push({ x: lx, y: ly, w: lw, h: lh, oldPixels, newPixels });
    while (this.undoStack.length > MAX_UNDO) {
      this.undoStack.shift();
    }
    this.redoStack = [];

    this.canUndo = true;
    this.canRedo = false;
  }

  private writeRegionToMaster(
    master: Uint8ClampedArray,
    lx: number, ly: number, lw: number, lh: number,
    pixels: Uint8ClampedArray
  ): void {
    const W = this.project.width;
    for (let row = 0; row < lh; row++) {
      const dstOff = ((ly + row) * W + lx) * 4;
      const srcOff = row * lw * 4;
      master.set(pixels.subarray(srcOff, srcOff + lw * 4), dstOff);
    }
  }

  private async undo(): Promise<void> {
    if (this.undoStack.length === 0 || this.isBusy || !this.masterBuffer) return;

    this.isBusy = true;
    try {
      const patch = this.undoStack[this.undoStack.length - 1];
      const master = new Uint8ClampedArray(this.masterBuffer);

      this.writeRegionToMaster(master, patch.x, patch.y, patch.w, patch.h, patch.oldPixels);

      const ok = await this.renderMasterToCanvas();
      if (!ok) {
        this.writeRegionToMaster(master, patch.x, patch.y, patch.w, patch.h, patch.newPixels);
        console.warn('撤销失败：重绘未成功，已回滚 master');
        return;
      }

      this.undoStack.pop();
      this.redoStack.push(patch);
      while (this.redoStack.length > MAX_REDO) {
        this.redoStack.shift();
      }
      this.canUndo = this.undoStack.length > 0;
      this.canRedo = this.redoStack.length > 0;
      this.isDirty = true;
    } catch (e) {
      console.error('撤销失败:', e);
    } finally {
      this.isBusy = false;
    }
  }

  private async redo(): Promise<void> {
    if (this.redoStack.length === 0 || this.isBusy || !this.masterBuffer) return;

    this.isBusy = true;
    try {
      const patch = this.redoStack[this.redoStack.length - 1];
      const master = new Uint8ClampedArray(this.masterBuffer);

      this.writeRegionToMaster(master, patch.x, patch.y, patch.w, patch.h, patch.newPixels);

      const ok = await this.renderMasterToCanvas();
      if (!ok) {
        this.writeRegionToMaster(master, patch.x, patch.y, patch.w, patch.h, patch.oldPixels);
        console.warn('重做失败：重绘未成功，已回滚 master');
        return;
      }

      this.redoStack.pop();
      this.undoStack.push(patch);
      while (this.undoStack.length > MAX_UNDO) {
        this.undoStack.shift();
      }
      this.canUndo = this.undoStack.length > 0;
      this.canRedo = this.redoStack.length > 0;
      this.isDirty = true;
    } catch (e) {
      console.error('重做失败:', e);
    } finally {
      this.isBusy = false;
    }
  }

  private async performFill(logicalX: number, logicalY: number): Promise<void> {
    if (this.isFilling || this.isBusy || !this.masterBuffer) return;
    this.isFilling = true;
    this.isBusy = true;

    this.showLoading('正在填充...');
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 60));

    try {
      const W = this.project.width;
      const H = this.project.height;

      const oldPixels = new Uint8ClampedArray(new Uint8ClampedArray(this.masterBuffer));

      const master = new Uint8ClampedArray(this.masterBuffer);
      const pixelBuffer = new ArrayBuffer(master.length);
      new Uint8ClampedArray(pixelBuffer).set(master);

      const rgb = this.hexToRgb(this.color);

      const task = new taskpool.Task(
        floodFillTask,
        pixelBuffer,
        W, H,
        Math.floor(logicalX), Math.floor(logicalY),
        rgb[0], rgb[1], rgb[2],
        this.fillTol
      );
      task.setTransferList([pixelBuffer]);

      const resultBuffer = await taskpool.execute(task) as ArrayBuffer;
      const newPixels = new Uint8ClampedArray(resultBuffer);

      const masterView = new Uint8ClampedArray(this.masterBuffer);
      masterView.set(newPixels);

      await this.renderMasterToCanvas();
      this.commitPatch(0, 0, W, H, oldPixels, newPixels);
      this.isDirty = true;
    } catch (e) {
      console.error('填充失败:', e);
      promptAction.openToast({ message: '填充失败' }).catch(()=>{});
    } finally {
      this.hideLoading();
      this.isFilling = false;
      this.isBusy = false;
    }
  }

  private pickColorAt(x: number, y: number): void {
    try {
      const ix = Math.floor(x);
      const iy = Math.floor(y);
      if (ix < 0 || iy < 0 || ix >= this.project.width || iy >= this.project.height) {
        return;
      }
      if (!this.masterBuffer) return;
      const W = this.project.width;
      const master = new Uint8ClampedArray(this.masterBuffer);
      const off = (iy * W + ix) * 4;
      const a = master[off + 3];
      if (a === 0) {
        this.color = '#FFFFFF';
      } else {
        this.color = this.rgbToHex(master[off], master[off + 1], master[off + 2]);
      }
    } catch (e) {
      console.error('取色失败:', e);
    }
  }

  private async doSaveToSandbox(): Promise<boolean> {
    try {
      if (!this.masterBuffer) return false;
      const W = this.project.width;
      const H = this.project.height;
      const pixels = new Uint8ClampedArray(this.masterBuffer);

      const path: string = ProjectStore.getImagePath(this.project.id);
      const thumbPath: string = ProjectStore.getThumbPath(this.project.id);
      const task = new taskpool.Task(encodePixelsToPng, pixels, W, H, path, thumbPath);
      const ok: boolean = await taskpool.execute(task) as boolean;

      if (ok) {
        const updated: DrawProject = {
          id: this.project.id,
          name: this.project.name,
          width: this.project.width,
          height: this.project.height,
          createdAt: this.project.createdAt,
          updatedAt: Date.now()
        };
        await ProjectStore.upsert(updated);
        this.isDirty = false;
      }
      return ok;
    } catch (e) {
      console.error('保存到沙箱失败:', e);
      return false;
    }
  }

  async saveToSandbox(): Promise<boolean> {
    await this.ensureMasterReady();
    this.showLoading('正在保存...');
    await new Promise<void>((resolve) => setTimeout(() => resolve(), 60));
    try {
      return await this.doSaveToSandbox();
    } finally {
      this.hideLoading();
    }
  }

  async saveToGallery(): Promise<void> {
    const ok = await this.saveToSandbox();
    if (!ok) {
      promptAction.openToast({ message: '保存到沙箱失败' }).catch(()=>{});
      return;
    }

    try {
      const sandboxPath = ProjectStore.getImagePath(this.project.id);
      const uri = fileUri.getUriFromPath(sandboxPath);

      const helper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const srcFileUris: Array<string> = [uri];
      const photoCreationConfigs: Array<photoAccessHelper.PhotoCreationConfig> = [{
        title: this.project.name,
        fileNameExtension: 'png',
        photoType: photoAccessHelper.PhotoType.IMAGE,
        subtype: photoAccessHelper.PhotoSubtype.DEFAULT
      }];

      const desFileUris = await helper.showAssetsCreationDialog(
        srcFileUris, photoCreationConfigs
      );

      if (!desFileUris || desFileUris.length === 0) return;

      let dstFile: fileIo.File | null = null;
      let srcFile: fileIo.File | null = null;
      try {
        dstFile = fileIo.openSync(desFileUris[0], fileIo.OpenMode.WRITE_ONLY);
        srcFile = fileIo.openSync(sandboxPath, fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(srcFile.fd);
        const buf = new ArrayBuffer(stat.size);
        fileIo.readSync(srcFile.fd, buf);
        fileIo.writeSync(dstFile.fd, buf);
      } finally {
        if (srcFile) { try { fileIo.closeSync(srcFile); } catch {} }
        if (dstFile) { try { fileIo.closeSync(dstFile); } catch {} }
      }

      promptAction.openToast({ message: '已保存到相册' }).catch(()=>{});
    } catch (e) {
      console.error('保存到相册失败:', e);
      promptAction.openToast({ message: '保存到相册失败' }).catch(()=>{});
    }
  }

  private async ensureMasterReady(): Promise<void> {
    if (this.masterReady) return;
    const W = this.project.width;
    const H = this.project.height;
    const region = this.readCanvasRegion(0, 0, W, H);
    if (region) {
      this.masterBuffer = region.buffer as ArrayBuffer;
      this.masterReady = true;
    }
  }

  async loadExistingImage(): Promise<void> {
    if (this.isImageLoaded) return;
    const path = ProjectStore.getImagePath(this.project.id);
    const W = this.project.width;
    const H = this.project.height;

    try {
      if (!fileIo.accessSync(path)) {
        const buf = new ArrayBuffer(W * H * 4);
        const view = new Uint8ClampedArray(buf);
        for (let i = 0; i < view.length; i += 4) {
          view[i] = 255; view[i + 1] = 255; view[i + 2] = 255; view[i + 3] = 255;
        }
        this.masterBuffer = buf;
        this.masterReady = true;
        this.isImageLoaded = true;
        return;
      }

      let file: fileIo.File | null = null;
      let imageSource: image.ImageSource | null = null;
      let pixelMap: image.PixelMap | null = null;

      try {
        file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        imageSource = image.createImageSource(file.fd);
        pixelMap = await imageSource.createPixelMap();

        const info = await pixelMap.getImageInfo();
        if (info.size.width !== W || info.size.height !== H) {
          await pixelMap.scale(W / info.size.width, H / info.size.height);
        }

        this.canvasCtx.globalCompositeOperation = 'source-over';
        this.canvasCtx.globalAlpha = 1;
        this.canvasCtx.fillStyle = '#FFFFFF';
        this.canvasCtx.fillRect(0, 0, W, H);
        this.canvasCtx.drawImage(pixelMap, 0, 0, W, H);

        const buf = new ArrayBuffer(W * H * 4);
        await pixelMap.readPixelsToBuffer(buf);

        this.masterBuffer = buf;
        this.masterReady = true;
        this.isImageLoaded = true;
      } finally {
        if (pixelMap) { try { pixelMap.release(); } catch {} }
        if (imageSource) { try { imageSource.release(); } catch {} }
        if (file) { try { fileIo.closeSync(file); } catch {} }
      }
    } catch (e) {
      console.error('加载已有图片失败:', e);
      const buf = new ArrayBuffer(W * H * 4);
      const view = new Uint8ClampedArray(buf);
      for (let i = 0; i < view.length; i += 4) {
        view[i] = 255; view[i + 1] = 255; view[i + 2] = 255; view[i + 3] = 255;
      }
      this.masterBuffer = buf;
      this.masterReady = true;
      this.isImageLoaded = true;
    }
  }

  private applyStyle(): void {
    this.canvasCtx.lineCap = 'round';
    this.canvasCtx.lineJoin = 'round';
    this.canvasCtx.lineWidth = this.curWidth;
    this.canvasCtx.globalCompositeOperation = 'source-over';
    this.canvasCtx.strokeStyle = this.curIsEraser ? '#FFFFFF' : this.curColor;
  }

  private drawSegment(x1: number, y1: number, x2: number, y2: number): void {
    this.canvasCtx.save();
    this.applyStyle();
    this.canvasCtx.beginPath();
    this.canvasCtx.moveTo(x1, y1);
    this.canvasCtx.lineTo(x2, y2);
    this.canvasCtx.stroke();
    this.canvasCtx.restore();
  }

  private onCanvasTouch(event: TouchEvent): void {
    if (this.isPinching || event.touches.length > 1) {
      this.fillDownValid = false;
      return;
    }
    if (this.isFilling || this.isBusy) return;

    const touch = event.touches[0];
    if (touch.id !== 0) return;

    if (this.toolMode === 'pan') {
      if (event.touches.length !== 1) return;
      const px = touch.x;
      const py = touch.y;
      if (event.type === TouchType.Down) {
        this.panStartX = px;
        this.panStartY = py;
        this.panBaseX = this.offsetX;
        this.panBaseY = this.offsetY;
        this.isPanning = true;
      } else if (event.type === TouchType.Move && this.isPanning) {
        const scale = this.displayScale * this.userScale;
        this.offsetX = this.panBaseX + (px - this.panStartX) * scale;
        this.offsetY = this.panBaseY + (py - this.panStartY) * scale;
        this.clampOffset();
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.isPanning = false;
      }
      return;
    }

    const x = vp2px(touch.x);
    const y = vp2px(touch.y);

    if (this.toolMode === 'picker') {
      if (event.type === TouchType.Down) {
        if (this.pickerHideTimer !== -1) {
          clearTimeout(this.pickerHideTimer);
          this.pickerHideTimer = -1;
        }
        this.pickerX = x;
        this.pickerY = y;
        this.showPickerPreview = true;
        this.pickColorAt(x, y);
      } else if (event.type === TouchType.Move) {
        this.pickerX = x;
        this.pickerY = y;
        this.pickColorAt(x, y);
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pickerHideTimer = setTimeout(() => {
          this.showPickerPreview = false;
          this.pickerHideTimer = -1;
        }, 700);
      }
      return;
    }

    if (this.toolMode === 'fill') {
      if (event.type === TouchType.Down) {
        this.fillDownX = x;
        this.fillDownY = y;
        this.fillDownValid = true;
      } else if (event.type === TouchType.Move) {
        const dx = x - this.fillDownX;
        const dy = y - this.fillDownY;
        const thresh = vp2px(20);
        if (dx * dx + dy * dy > thresh * thresh) {
          this.fillDownValid = false;
        }
      } else if (event.type === TouchType.Up) {
        if (this.fillDownValid) {
          this.performFill(this.fillDownX, this.fillDownY);
        }
        this.fillDownValid = false;
      } else if (event.type === TouchType.Cancel) {
        this.fillDownValid = false;
      }
      return;
    }

    if (event.type === TouchType.Down) {
      this.lastX = x;
      this.lastY = y;
      this.isStroking = true;
      this.curColor = this.color;
      this.curWidth = vp2px(this.strokeWidth);
      this.curIsEraser = this.toolMode === 'eraser';
      this.brushMinX = x;
      this.brushMinY = y;
      this.brushMaxX = x;
      this.brushMaxY = y;
    } else if (event.type === TouchType.Move && this.isStroking) {
      this.drawSegment(this.lastX, this.lastY, x, y);
      this.lastX = x;
      this.lastY = y;
      this.isDirty = true;
      if (x < this.brushMinX) this.brushMinX = x;
      if (y < this.brushMinY) this.brushMinY = y;
      if (x > this.brushMaxX) this.brushMaxX = x;
      if (y > this.brushMaxY) this.brushMaxY = y;
    } else if (event.type === TouchType.Up) {
      if (!this.isStroking) return;
      this.isStroking = false;
      if (!this.masterBuffer) return;

      const r = this.curWidth / 2 + 2;
      let lx = Math.max(0, Math.floor(this.brushMinX - r));
      let ly = Math.max(0, Math.floor(this.brushMinY - r));
      let lw = Math.min(this.project.width - lx,
        Math.ceil(this.brushMaxX - this.brushMinX + r * 2));
      let lh = Math.min(this.project.height - ly,
        Math.ceil(this.brushMaxY - this.brushMinY + r * 2));
      if (lw <= 0 || lh <= 0) return;

      const newPixels = this.readCanvasRegion(lx, ly, lw, lh);
      if (!newPixels) return;

      const W = this.project.width;
      const master = new Uint8ClampedArray(this.masterBuffer);
      const oldPixels = new Uint8ClampedArray(lw * lh * 4);
      for (let row = 0; row < lh; row++) {
        const srcOff = ((ly + row) * W + lx) * 4;
        const dstOff = row * lw * 4;
        oldPixels.set(master.subarray(srcOff, srcOff + lw * 4), dstOff);
      }

      this.commitPatch(lx, ly, lw, lh, oldPixels, newPixels);
    }
  }

  private clearCanvas(): void {
    AlertDialog.show({
      title: '确认清空',
      message: '确定要清空画布吗？',
      buttons: [
        { value: '取消', action: () => {} },
        {
          value: '清空',
          fontColor: $r('sys.color.warning'),
          action: async () => {
            await this.ensureMasterReady();
            if (!this.masterBuffer) return;
            const W = this.project.width;
            const H = this.project.height;

            const oldPixels = new Uint8ClampedArray(new Uint8ClampedArray(this.masterBuffer));
            const master = new Uint8ClampedArray(this.masterBuffer);
            for (let i = 0; i < master.length; i += 4) {
              master[i] = 255; master[i + 1] = 255; master[i + 2] = 255; master[i + 3] = 255;
            }
            const newPixels = new Uint8ClampedArray(master);

            await this.renderMasterToCanvas();
            this.commitPatch(0, 0, W, H, oldPixels, newPixels);
            this.isDirty = true;
            promptAction.openToast({ message: '已清空' }).catch(()=>{});
          }
        }
      ]
    });
  }

  private toOuterX(canvasX: number): number {
    const scale = this.displayScale * this.userScale;
    return this.offsetX + this.outerW / 2 + (px2vp(canvasX) - px2vp(this.project.width) / 2) * scale;
  }

  private toOuterY(canvasY: number): number {
    const scale = this.displayScale * this.userScale;
    return this.offsetY + this.outerH / 2 + (px2vp(canvasY) - px2vp(this.project.height) / 2) * scale;
  }

  @Builder
  PickerPreview() {
    Column({ space: 6 }) {
      Column()
        .width(56)
        .height(56)
        .borderRadius(28)
        .backgroundColor(this.color)
        .border({ width: 3, color: '#FFFFFF', radius: 28 })
    }
    .position({
      x: this.toOuterX(this.pickerX) - 28,
      y: this.toOuterY(this.pickerY) - 114
    })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  ToolButton(key: string, icon: Resource, label: string, onTap: () => void) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([this.toolMode === key ? $r('app.color.brand') : $r('sys.color.font_primary')])
      Text(label)
        .fontSize(10)
        .fontColor(this.toolMode === key ? $r('app.color.brand') : $r('sys.color.font_primary'))
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) this.isPressingTool = true;
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.isPressingTool = false;
    })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  UndoButton() {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.undo'))
        .fontSize(20)
        .fontColor([this.canUndo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary')])
      Text('撤销')
        .fontSize(10)
        .fontColor(this.canUndo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .enabled(this.canUndo && !this.isBusy)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) this.isPressingDoBar = true;
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.isPressingDoBar = false;
    })
    .onClick(async () => {
      await this.undo();
    })
  }

  @Builder
  RedoButton() {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.redo'))
        .fontSize(20)
        .fontColor([this.canRedo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary')])
      Text('重做')
        .fontSize(10)
        .fontColor(this.canRedo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .enabled(this.canRedo && !this.isBusy)
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) this.isPressingDoBar = true;
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.isPressingDoBar = false;
    })
    .onClick(async () => {
      await this.redo();
    })
  }

  @Builder
  ToolBarBody() {
    Column({ space: 0 }) {
      Stack() {
        Row({ space: 8 }) {
          Text('容差')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
            .width(32)
          Slider({
            min: 0,
            max: 128,
            value: this.fillTol,
            step: 1,
            style: SliderStyle.InSet
          })
            .selectedColor($r('app.color.brand'))
            .layoutWeight(1)
            .onChange((value: number) => {
              this.fillTol = Math.round(value);
            })
          Text(`${Math.round(this.fillTol)}`)
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .width(32)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)
        .opacity(this.toolMode === 'fill' ? 1 : 0)
        .translate({ y: this.toolMode === 'fill' ? 0 : -6 })
        .zIndex(this.toolMode === 'fill' ? 1 : 0)
        .hitTestBehavior(this.toolMode === 'fill' ? HitTestMode.Default : HitTestMode.None)
        .animation({ duration: 100, curve: Curve.EaseOut })

        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.dot'))
            .fontColor([$r('sys.color.font_primary')])
            .fontSize(16)
          Slider({
            min: 1,
            max: 40,
            value: this.strokeWidth,
            step: 1,
            style: SliderStyle.InSet
          })
            .selectedColor($r('app.color.brand'))
            .layoutWeight(1)
            .onChange((value: number) => {
              this.strokeWidth = value;
            })
          SymbolGlyph($r('sys.symbol.circle_fill'))
            .fontColor([$r('sys.color.font_primary')])
            .fontSize(16)
        }
        .width('100%')
        .height(40)
        .alignItems(VerticalAlign.Center)
        .opacity((this.toolMode === 'brush' || this.toolMode === 'eraser') ? 1 : 0)
        .translate({ y: (this.toolMode === 'brush' || this.toolMode === 'eraser') ? 0 : -6 })
        .zIndex((this.toolMode === 'brush' || this.toolMode === 'eraser') ? 1 : 0)
        .hitTestBehavior((this.toolMode === 'brush' || this.toolMode === 'eraser') ? HitTestMode.Default : HitTestMode.None)
        .animation({ duration: 100, curve: Curve.EaseOut })
      }
      .width('100%')
      .height((this.toolMode === 'brush' || this.toolMode === 'eraser' || this.toolMode === 'fill') ? 40 : 0)
      .clip(true)
      .margin({ bottom: (this.toolMode === 'brush' || this.toolMode === 'eraser' || this.toolMode === 'fill') ? 8 : 0 })
      .animation({ duration: 200, curve: Curve.EaseOut })

      Row({ space: 0 }) {
        this.ToolButton('brush', $r('sys.symbol.pen_tip'), '画笔', () => {
          this.toolMode = 'brush';
          this.showPickerPreview = false;
        })
        this.ToolButton('eraser', $r('sys.symbol.eraser_scribble'), '橡皮', () => {
          this.toolMode = 'eraser';
          this.showPickerPreview = false;
        })
        this.ToolButton('fill', $r('sys.symbol.color_fill'), '填充', () => {
          this.toolMode = 'fill';
          this.showPickerPreview = false;
        })
        this.ToolButton('picker', $r('sys.symbol.eyedropper'), '取色', () => {
          this.toolMode = 'picker';
          this.showPickerPreview = false;
        })
        this.ToolButton('pan', $r('sys.symbol.move'), '拖动', () => {
          this.toolMode = 'pan';
          this.showPickerPreview = false;
        })

        Column({ space: 4 }) {
          if (deviceInfo.apiAvailable('26.0.0')) {
            Circle()
              .width(20)
              .height(20)
              .fill(this.color)
              .stroke($r('sys.color.font_primary'))
              .strokeWidth(1)
          } else {
            Column()
              .width(20)
              .height(20)
              .borderRadius(10)
              .backgroundColor(this.color)
              .border({
                width: 1,
                color: $r('sys.color.font_primary'),
                radius: 10
              })
          }
          Text('颜色')
            .fontSize(10)
            .fontColor($r('sys.color.font_primary'))
        }
        .layoutWeight(1)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.colorDialogController?.open();
        })
      }
      .width('100%')
    }
    .width('100%')
    .borderRadius(30)
    .backgroundColor($r('app.color.immersive_background'))
    .backdropBlur(30)
    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
    .border({
      width: 0.5,
      color: 'rgba(255, 255, 255, 0.6)',
      radius: 30
    })
    .shadow({
      radius: 30,
      color: 'rgba(0, 0, 0, 0.15)',
      offsetX: 0,
      offsetY: 6
    })
    .scale({
      x: this.isPressingTool ? 0.98 : 1.0,
      y: this.isPressingTool ? 0.98 : 1.0
    })
    .animation({ curve: curves.springMotion(0.5, 0.8) })
  }

  @Builder
  ToolBar() {
    Column() {
      this.ToolBarBody()
    }
    .width('90%')
    .constraintSize({ maxWidth: 420 })
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  DoBarBody() {
    Row({ space: 0 }) {
      this.UndoButton()
      this.RedoButton()
    }
    .width(120)
    .borderRadius(30)
    .backgroundColor($r('app.color.immersive_background'))
    .backdropBlur(30)
    .border({
      width: 0.5,
      color: 'rgba(255, 255, 255, 0.6)',
      radius: 30
    })
    .shadow({
      radius: 30,
      color: 'rgba(0, 0, 0, 0.15)',
      offsetX: 0,
      offsetY: 6
    })
    .scale({
      x: this.isPressingDoBar ? 0.98 : 1.0,
      y: this.isPressingDoBar ? 0.98 : 1.0
    })
    .animation({ curve: curves.springMotion(0.5, 0.8) })
    .onClick(() => {})
  }

  @Builder
  DoBar() {
    Row({ space: 0 }) {
      Blank()
        .layoutWeight(1)
        .hitTestBehavior(HitTestMode.None)
      this.DoBarBody()
    }
    .padding({ left: 16, right: 16 })
    .backgroundColor(Color.Transparent)
  }

  @Builder
  BottomBars() {
    if (this.isWideScreen()) {
      Row({ space: 12 }) {
        Column() {
          this.ToolBarBody()
        }
        .width(400)

        Blank()
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.None)

        this.DoBarBody()
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 24 })
      .alignItems(VerticalAlign.Bottom)
      .hitTestBehavior(HitTestMode.None)
    } else {
      Column({ space: 6 }) {
        this.DoBar()
        this.ToolBar()
      }
      .width('100%')
      .padding({ bottom: 8 })
      .hitTestBehavior(HitTestMode.None)
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        Stack() {
          Stack() {
            Canvas(this.canvasCtx)
              .width(px2vp(this.project.width))
              .height(px2vp(this.project.height))
              .backgroundColor(Color.White)
              .onReady(() => {
                this.canvasCtx.globalCompositeOperation = 'source-over';
                this.canvasCtx.globalAlpha = 1;
                this.canvasCtx.fillStyle = '#FFFFFF';
                this.canvasCtx.fillRect(0, 0, this.project.width, this.project.height);
                this.loadExistingImage();
              })
              .onTouch((e: TouchEvent) => this.onCanvasTouch(e))
          }
          .width(px2vp(this.project.width))
          .height(px2vp(this.project.height))
          .clip(false)
          .translate({ x: this.offsetX, y: this.offsetY })
          .scale({
            x: this.displayScale * this.userScale,
            y: this.displayScale * this.userScale,
            z: 1
          })
          .gesture(
            GestureGroup(GestureMode.Parallel,
              PinchGesture()
                .onActionStart(() => {
                  this.isPinching = true;
                  this.isPanning = false;
                  this.showPickerPreview = false;
                  this.fillDownValid = false;
                })
                .onActionUpdate((e: GestureEvent) => {
                  if (e) {
                    this.userScale = this.clampScale(this.pinchBase * e.scale);
                    this.clampOffset();
                  }
                })
                .onActionEnd(() => {
                  this.pinchBase = this.userScale;
                  this.isPinching = false;
                  this.clampOffset();
                }),
              PanGesture({ fingers: 2 })
                .onActionStart(() => {
                  this.isPinching = true;
                  this.isPanning = false;
                  this.showPickerPreview = false;
                  this.fillDownValid = false;
                  this.panBaseX = this.offsetX;
                  this.panBaseY = this.offsetY;
                })
                .onActionUpdate((e: GestureEvent) => {
                  if (e) {
                    this.offsetX = this.panBaseX + e.offsetX;
                    this.offsetY = this.panBaseY + e.offsetY;
                    this.clampOffset();
                  }
                })
                .onActionEnd(() => {
                  this.panBaseX = this.offsetX;
                  this.panBaseY = this.offsetY;
                  this.isPinching = false;
                })
            )
          )

          if (this.toolMode === 'picker' && this.showPickerPreview) {
            this.PickerPreview()
          }

          Column() {
            Blank()
              .layoutWeight(1)
              .hitTestBehavior(HitTestMode.None)
            this.BottomBars()
          }
          .width('100%')
          .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .layoutWeight(1)
        .clip(true)
        .backgroundColor($r('sys.color.background_secondary'))
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.outerW = Number(newArea.width);
          this.outerH = Number(newArea.height);

          const availW = Number(newArea.width) - 32;
          const availH = Number(newArea.height) - 32;
          if (availW <= 0 || availH <= 0) return;

          const canvasVpW = px2vp(this.project.width);
          const canvasVpH = px2vp(this.project.height);
          const s = Math.min(availW / canvasVpW, availH / canvasVpH);
          this.displayScale = Math.min(s, 1);
          this.clampOffset();
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_primary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .titleBar({
      style: {
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        title: {
          mainTitle: this.project.name
        },
        menu: {
          value: [
            {
              content: {
                label: this.isDirty ? '保存' : '已保存',
                icon: $r('sys.symbol.save'),
                action: async () => {
                  const ok = await this.saveToSandbox();
                  promptAction.openToast({ message: ok ? '已保存' : '保存失败' }).catch(()=>{});
                }
              }
            },
            {
              content: {
                label: '保存到相册',
                icon: $r('sys.symbol.picture_badge_arrow_down'),
                action: () => this.saveToGallery()
              }
            },
            {
              content: {
                label: '清空画布',
                icon: $r('sys.symbol.trash'),
                action: () => this.clearCanvas()
              }
            }
          ],
          maxCount: 2
        }
      },
      enableHoverMode: true,
      enableComponentSafeArea: false
    })
    .onReady((ctx: NavDestinationContext) => {
      this.pathStack = ctx.pathStack;
    })
    .onBackPressed(() => {
      if (this.isDirty) {
        this.saveToSandbox().then((value: boolean) => {
          promptAction.openToast({ message: value ? '已保存' : '保存失败' }).catch(()=>{});
          this.pathStack.pop();
        });
        return true;
      }
      return false;
    })
  }
}