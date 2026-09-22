import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { curves, LengthMetricsUnit, promptAction } from '@kit.ArkUI';
import { taskpool } from '@kit.ArkTS';
import { ProjectStore, DrawProject } from '../common/ProjectStore';
import { hdsMaterial, HdsNavDestination, HdsNavigationBadgeIconOptions, TextStyleMode } from '@kit.UIDesignKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { PickColorComponent } from '../components/PickColorComponent';
import { LoadingDialog } from '../dialogs/LoadingDialog';
import { ResizeCanvasDialog, ResizeMode } from '../dialogs/ResizeCanvasDialog';
import { ImageOverlayParam } from './ImageOverlayPage';
import { KeyCode } from '@kit.InputKit';
import { systemShare } from '@kit.ShareKit';
import { uniformDataStruct, uniformTypeDescriptor } from '@kit.ArkData';
import { TextParam } from './TextPage';

type ToolMode = 'brush' | 'eraser' | 'picker' | 'fill' | 'pan';

const MAX_UNDO_STEPS = 100;
const MAX_UNDO_BYTES = 100 * 1024 * 1024;
const MIN_UNDO_KEEP = 3;

const MAX_REDO_STEPS = 100;
const MAX_REDO_BYTES = 64 * 1024 * 1024;
const MIN_REDO_KEEP = 2;

interface UndoPatch {
  x: number;
  y: number;
  w: number;
  h: number;
  oldPixels: Uint8ClampedArray;
  newPixels: Uint8ClampedArray;
}

interface FillPatch {
  buffer: ArrayBuffer;
  x: number;
  y: number;
  w: number;
  h: number;
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
  width: number, height: number,
  startLx: number, startLy: number,
  fillR: number, fillG: number, fillB: number,
  tol: number
): FillPatch {
  const src = new Uint8ClampedArray(pixelBuffer);
  const W = width, H = height;
  const EMPTY: FillPatch = { buffer: new ArrayBuffer(0), x: 0, y: 0, w: 0, h: 0 };

  if (startLx < 0 || startLy < 0 || startLx >= W || startLy >= H) return EMPTY;

  const si = (startLy * W + startLx) * 4;
  const tR = src[si], tG = src[si + 1], tB = src[si + 2], tA = src[si + 3];

  const rLo = tR - tol, rHi = tR + tol;
  const gLo = tG - tol, gHi = tG + tol;
  const bLo = tB - tol, bHi = tB + tol;
  const aLo = tA - tol, aHi = tA + tol;

  if (fillR >= rLo && fillR <= rHi &&
    fillG >= gLo && fillG <= gHi &&
    fillB >= bLo && fillB <= bHi && tA === 255) {
    return EMPTY;
  }

  const visited = new Uint8Array(W * H);
  let minX = W, minY = H, maxX = -1, maxY = -1;

  let stack = new Int32Array(4096);
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
    const rowOff = y * W;

    while (x >= 0 && visited[rowOff + x] === 0) {
      const i = (rowOff + x) * 4;
      const r = src[i], g = src[i + 1], b = src[i + 2], a = src[i + 3];
      if (r < rLo || r > rHi || g < gLo || g > gHi ||
        b < bLo || b > bHi || a < aLo || a > aHi) break;
      x--;
    }
    x++;

    let spanAbove = false, spanBelow = false;

    while (x < W && visited[rowOff + x] === 0) {
      const i = (rowOff + x) * 4;
      const r = src[i], g = src[i + 1], b = src[i + 2], a = src[i + 3];
      if (r < rLo || r > rHi || g < gLo || g > gHi ||
        b < bLo || b > bHi || a < aLo || a > aHi) break;

      visited[rowOff + x] = 1;

      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;

      if (y > 0) {
        const ar = (y - 1) * W;
        if (visited[ar + x] === 0) {
          const ai = (ar + x) * 4;
          const m = src[ai] >= rLo && src[ai] <= rHi &&
            src[ai + 1] >= gLo && src[ai + 1] <= gHi &&
            src[ai + 2] >= bLo && src[ai + 2] <= bHi &&
            src[ai + 3] >= aLo && src[ai + 3] <= aHi;
          if (m && !spanAbove) { push(x, y - 1); spanAbove = true; }
          else if (!m) spanAbove = false;
        } else spanAbove = false;
      }
      if (y < H - 1) {
        const br = (y + 1) * W;
        if (visited[br + x] === 0) {
          const bi = (br + x) * 4;
          const m = src[bi] >= rLo && src[bi] <= rHi &&
            src[bi + 1] >= gLo && src[bi + 1] <= gHi &&
            src[bi + 2] >= bLo && src[bi + 2] <= bHi &&
            src[bi + 3] >= aLo && src[bi + 3] <= aHi;
          if (m && !spanBelow) { push(x, y + 1); spanBelow = true; }
          else if (!m) spanBelow = false;
        } else spanBelow = false;
      }

      x++;
    }
  }

  if (maxX < 0) return EMPTY;

  const pw = maxX - minX + 1;
  const ph = maxY - minY + 1;

  for (let y = minY; y <= maxY; y++) {
    const ro = y * W;
    for (let x = minX; x <= maxX; x++) {
      if (visited[ro + x] !== 1) continue;
      const di = (ro + x) * 4;
      src[di] = fillR; src[di + 1] = fillG;
      src[di + 2] = fillB; src[di + 3] = 255;
    }
  }

  const patchBuffer = new ArrayBuffer(pw * ph * 4);
  const patch = new Uint8ClampedArray(patchBuffer);
  for (let row = 0; row < ph; row++) {
    const srcOff = ((minY + row) * W + minX) * 4;
    patch.set(src.subarray(srcOff, srcOff + pw * 4), row * pw * 4);
  }

  return { buffer: patchBuffer, x: minX, y: minY, w: pw, h: ph };
}

@Concurrent
function resizeCanvasTask(
  oldBuffer: ArrayBuffer,
  oldW: number,
  oldH: number,
  newW: number,
  newH: number,
  mode: number,
  bgR: number,
  bgG: number,
  bgB: number
): ArrayBuffer {
  const src = new Uint8ClampedArray(oldBuffer);
  const outBuf = new ArrayBuffer(newW * newH * 4);
  const out = new Uint8ClampedArray(outBuf);

  for (let i = 0; i < out.length; i += 4) {
    out[i] = bgR;
    out[i + 1] = bgG;
    out[i + 2] = bgB;
    out[i + 3] = 255;
  }

  const sample = (sx: number, sy: number, ox: number, oy: number): void => {
    if (sx < 0 || sy < 0 || sx > oldW - 1 || sy > oldH - 1) return;

    const x0 = Math.floor(sx);
    const y0 = Math.floor(sy);
    const x1 = x0 + 1 < oldW ? x0 + 1 : oldW - 1;
    const y1 = y0 + 1 < oldH ? y0 + 1 : oldH - 1;
    const fx = sx - x0;
    const fy = sy - y0;

    const i00 = (y0 * oldW + x0) * 4;
    const i10 = (y0 * oldW + x1) * 4;
    const i01 = (y1 * oldW + x0) * 4;
    const i11 = (y1 * oldW + x1) * 4;

    const w00 = (1 - fx) * (1 - fy);
    const w10 = fx * (1 - fy);
    const w01 = (1 - fx) * fy;
    const w11 = fx * fy;

    const oi = (oy * newW + ox) * 4;
    for (let c = 0; c < 4; c++) {
      out[oi + c] =
        src[i00 + c] * w00 + src[i10 + c] * w10 +
          src[i01 + c] * w01 + src[i11 + c] * w11;
    }
  };

  if (mode === 0) {
    for (let y = 0; y < newH; y++) {
      const sy = (y + 0.5) * oldH / newH - 0.5;
      for (let x = 0; x < newW; x++) {
        const sx = (x + 0.5) * oldW / newW - 0.5;
        sample(sx, sy, x, y);
      }
    }
  } else if (mode === 1) {
    const scale = Math.min(newW / oldW, newH / oldH);
    const drawW = Math.round(oldW * scale);
    const drawH = Math.round(oldH * scale);
    const offX = Math.floor((newW - drawW) / 2);
    const offY = Math.floor((newH - drawH) / 2);
    for (let dy = 0; dy < drawH; dy++) {
      const sy = (dy + 0.5) / scale - 0.5;
      for (let dx = 0; dx < drawW; dx++) {
        const sx = (dx + 0.5) / scale - 0.5;
        sample(sx, sy, offX + dx, offY + dy);
      }
    }
  } else if (mode === 2) {
    const scale = Math.max(newW / oldW, newH / oldH);
    const offX = (newW - oldW * scale) / 2;
    const offY = (newH - oldH * scale) / 2;
    for (let y = 0; y < newH; y++) {
      const sy = (y - offY + 0.5) / scale - 0.5;
      for (let x = 0; x < newW; x++) {
        const sx = (x - offX + 0.5) / scale - 0.5;
        sample(sx, sy, x, y);
      }
    }
  } else {
    const copyW = Math.min(oldW, newW);
    const copyH = Math.min(oldH, newH);
    for (let y = 0; y < copyH; y++) {
      const srcOff = y * oldW * 4;
      const dstOff = y * newW * 4;
      out.set(src.subarray(srcOff, srcOff + copyW * 4), dstOff);
    }
  }

  return outBuf;
}

@Component
export struct EditorPage {
  @Prop project: DrawProject = {
    id: '', name: '', width: 1280, height: 720,
    createdAt: 0, updatedAt: 0
  };

  @StorageProp('windowWidth') windowWidth: number = 0;
  @StorageLink('projectsRefreshToken') @Watch('onProjectsChanged')
  projectsRefreshToken: number = 0;

  @StorageLink('saveAndExitToken') @Watch('onSaveAndExitRequested')
  saveAndExitToken: number = 0;

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
  @State @Watch('syncDirtyToStorage') isDirty: boolean = false;
  @State isFilling: boolean = false;
  @State canUndo: boolean = false;
  @State canRedo: boolean = false;
  @State isBusy: boolean = false;
  @State showColorSheet: boolean = false;
  @State hoverStates: Record<string, boolean> = {
    'brush': false,
    'eraser': false,
    'fill': false,
    'picker': false,
    'pan': false,
    'color': false,
    'undo': false,
    'redo': false
  };
  @State pickerX: number = 0;
  @State pickerY: number = 0;
  @State showPickerPreview: boolean = false;

  @State outerW: number = 0;
  @State outerH: number = 0;

  @State offsetX: number = 0;
  @State offsetY: number = 0;

  @State canvasW: number = 0;
  @State canvasH: number = 0;

  @State isDragHover: boolean = false;

  private masterBuffer: ArrayBuffer | null = null;
  private masterReady: boolean = false;

  private undoStack: UndoPatch[] = [];
  private redoStack: UndoPatch[] = [];
  private undoBytes: number = 0;
  private redoBytes: number = 0;

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

  private pinchCenterBaseX: number = 0;
  private pinchCenterBaseY: number = 0;

  private mouseLeftDown: boolean = false;

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

  private loadingDialogController: CustomDialogController | null = null;
  private resizeCanvasController: CustomDialogController | null = null;
  private isImageLoaded: boolean = false;

  aboutToAppear(): void {
    this.canvasW = this.project.width;
    this.canvasH = this.project.height;

    this.resizeCanvasController = new CustomDialogController({
      builder: ResizeCanvasDialog({
        currentWidth: this.canvasW,
        currentHeight: this.canvasH,
        onConfirm: (w: number, h: number, mode: ResizeMode) => {
          this.resizeCanvas(w, h, mode);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    })
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
    this.undoBytes = 0;
    this.redoBytes = 0;
    AppStorage.setOrCreate('projectsRefreshToken', Date.now());

    AppStorage.setOrCreate('editorDirty', false);
  }

  private syncDirtyToStorage(): void {
    AppStorage.setOrCreate('editorDirty', this.isDirty);
  }

  private buildMenuItems(): Array<HdsNavigationBadgeIconOptions> {
    const items: Array<HdsNavigationBadgeIconOptions> = [
      {
        content: {
          label: this.isDirty ? '保存' : '已保存',
          icon: $r('sys.symbol.save'),
          action: async () => {
            const ok = await this.saveToSandbox();
            promptAction.openToast({ message: ok ? '已保存' : '保存失败' }).catch(() => {
            });
          },
          type: TextStyleMode.NORMAL
        }
      },
      {
        content: {
          label: '添加文字',
          icon: $r('sys.symbol.text_character_square'),
          action: async () => {
            if (this.isDirty) {
              const ok = await this.saveToSandbox();
              if (!ok) {
                promptAction.openToast({ message: '无法保存' }).catch(() => {
                });
                return;
              }
            }
            const currentProject: DrawProject = {
              id: this.project.id,
              name: this.project.name,
              width: this.canvasW,
              height: this.canvasH,
              createdAt: this.project.createdAt,
              updatedAt: this.project.updatedAt
            };
            this.pathStack.pushPathByName('TextPage', {
              project: currentProject
            } as TextParam);
          }
        }
      },
      {
        content: {
          label: '叠加图片到画板',
          icon: $r('sys.symbol.picture_on_square'),
          action: () => this.startImageOverlay()
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
          label: '分享',
          icon: $r('sys.symbol.share'),
          action: () => this.shareImage()
        }
      },
      {
        content: {
          label: '调整画布尺寸',
          icon: $r('sys.symbol.crop'),
          action: () => this.showResizeDialog()
        }
      }];
    return items;
  }

  private async onSaveAndExitRequested(): Promise<void> {
    if (this.saveAndExitToken === 0) return;
    const token = this.saveAndExitToken;

    try {
      await this.ensureMasterReady();

      let ok = true;
      if (this.isDirty) {
        ok = await this.doSaveToSandbox();
      }

      AppStorage.setOrCreate('saveAndExitResult', ok);
      AppStorage.setOrCreate('saveAndExitResultToken', token);
    } catch (e) {
      console.error('保存并退出失败:', e);
      AppStorage.setOrCreate('saveAndExitResult', false);
      AppStorage.setOrCreate('saveAndExitResultToken', token);
    }
  }

  onProjectsChanged(): void {
    if (!this.isImageLoaded) return;
    this.reloadFromDisk();
  }

  private async reloadFromDisk(): Promise<void> {
    this.isImageLoaded = false;
    this.masterReady = false;
    this.masterBuffer = null;
    this.undoStack = [];
    this.redoStack = [];
    this.undoBytes = 0;
    this.redoBytes = 0;
    this.canUndo = false;
    this.canRedo = false;
    this.isDirty = false;
    await this.loadExistingImage();
  }

  private isWideScreen(): boolean {
    return this.windowWidth >= 600;
  }

  private extractImageUris(event: DragEvent): string[] {
    const uris: string[] = [];
    try {
      const dragData = event.getData();
      if (!dragData) return uris;

      const records = dragData.getRecords();
      if (!records || records.length === 0) return uris;

      for (const record of records) {
        const types = record.getTypes();
        if (!types || !types.includes(uniformTypeDescriptor.UniformDataType.FILE_URI)) continue;

        const fileUriData = record.getEntry(
          uniformTypeDescriptor.UniformDataType.FILE_URI
        ) as uniformDataStruct.FileUri;

        if (!fileUriData?.oriUri) continue;

        const td = uniformTypeDescriptor.getTypeDescriptor(fileUriData.fileType);
        const isImage = td
          ? td.belongsTo(uniformTypeDescriptor.UniformDataType.IMAGE)
          : /\.(png|jpe?g|webp|bmp|gif|heic|heif)$/i.test(fileUriData.oriUri);

        if (isImage) {
          uris.push(fileUriData.oriUri);
        }
      }
    } catch (e) {
      console.error('解析拖放数据失败:', e);
    }
    return uris;
  }

  private async startImageOverlay(): Promise<void> {
    try {
      if (this.isDirty) {
        const ok = await this.saveToSandbox();
        if (!ok) {
          promptAction.openToast({ message: '无法保存' }).catch(() => {});
          return;
        }
      }

      const opt = new photoAccessHelper.PhotoSelectOptions();
      opt.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      opt.maxSelectNumber = 1;
      const picker = new photoAccessHelper.PhotoViewPicker();
      const result = await picker.select(opt);

      if (!result || !result.photoUris || result.photoUris.length === 0) return;

      this.openOverlayPage(result.photoUris[0]);
    } catch (e) {
      console.error('叠加图片失败:', e);
      promptAction.openToast({ message: '操作失败' }).catch(() => {});
    }
  }

  private openOverlayPage(overlayUri: string): void {
    const currentProject: DrawProject = {
      id: this.project.id,
      name: this.project.name,
      width: this.canvasW,
      height: this.canvasH,
      createdAt: this.project.createdAt,
      updatedAt: this.project.updatedAt
    };
    this.pathStack.pushPathByName('ImageOverlayPage', {
      project: currentProject,
      overlayUri: overlayUri
    } as ImageOverlayParam);
  }

  private async handleImageDrop(event: DragEvent): Promise<void> {
    const uris = this.extractImageUris(event);
    if (uris.length === 0) {
      promptAction.openToast({ message: '只能拖入图片文件' }).catch(() => {});
      return;
    }

    if (this.isDirty) {
      const ok = await this.saveToSandbox();
      if (!ok) {
        promptAction.openToast({ message: '无法保存当前画板' }).catch(() => {});
        return;
      }
    }

    this.openOverlayPage(uris[0]);
  }

  async shareImage(): Promise<void> {
    if (this.isDirty) {
      const ok = await this.saveToSandbox();
      if (!ok) {
        promptAction.openToast({ message: '无法保存' }).catch(() => {
        });
        return;
      }
    }

    try {
      const sandboxPath = ProjectStore.getImagePath(this.project.id);

      const uri = fileUri.getUriFromPath(sandboxPath);

      const shareData = new systemShare.SharedData({
        utd: uniformTypeDescriptor.UniformDataType.PNG,
        uri: uri,
        title: this.project.name,
        description: `${this.project.name} - 由竹子画板创作`
      });

      const controller = new systemShare.ShareController(shareData);

      await controller.show(this.context, {
        previewMode: systemShare.SharePreviewMode.DETAIL,
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (e) {
      console.error('分享失败:', e);
      promptAction.openToast({ message: '分享失败' }).catch(() => {});
    }
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
    const cw = px2vp(this.canvasW) * scale;
    const ch = px2vp(this.canvasH) * scale;
    const margin = 80;
    const maxX = Math.max(0, (cw + this.outerW) / 2 - margin);
    const maxY = Math.max(0, (ch + this.outerH) / 2 - margin);
    this.offsetX = Math.max(-maxX, Math.min(maxX, this.offsetX));
    this.offsetY = Math.max(-maxY, Math.min(maxY, this.offsetY));
  }

  private zoomAt(xVp: number, yVp: number, factor: number): void {
    const oldScale = this.userScale;
    const newScale = this.clampScale(oldScale * factor);
    console.info(`zoomAt: factor=${factor} old=${oldScale} new=${newScale} offset=(${this.offsetX},${this.offsetY})`);
    if (newScale === oldScale) return;

    const mx = xVp - this.outerW / 2;
    const my = yVp - this.outerH / 2;
    const r = newScale / oldScale;

    this.offsetX = mx * (1 - r) + this.offsetX * r;
    this.offsetY = my * (1 - r) + this.offsetY * r;

    this.userScale = newScale;
    this.pinchBase = newScale;
    this.clampOffset();
    console.info(`zoomAt done: offset=(${this.offsetX},${this.offsetY})`);
  }

  private resetZoom(): void {
    this.userScale = 1;
    this.pinchBase = 1;
    this.offsetX = 0;
    this.offsetY = 0;
  }

  private onCanvasAxis(event: AxisEvent): void {
    if (this.isFilling || this.isBusy) return;
    if (event.hasAxis(AxisType.PINCH_AXIS)) return; // PinchGesture会处理

    const v = event.getVerticalAxisValue();
    const h = event.getHorizontalAxisValue();
    if (v === 0 && h === 0) return;

    try {
      if (event.getModifierKeyState) {
        const ctrlPressed: boolean = event.getModifierKeyState(['Ctrl']);
        if (ctrlPressed) return; // PinchGesture会处理
      }
    }
    catch (err) {
      console.error('无法getModifierKeyState');
    }

    const SCROLL_STEP = 0.5;
    this.offsetX -= h * SCROLL_STEP;
    this.offsetY -= v * SCROLL_STEP;
    this.clampOffset();
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
      const W = this.canvasW;
      const H = this.canvasH;

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

  private readRegionFromMaster(
    master: Uint8ClampedArray,
    lx: number, ly: number, lw: number, lh: number
  ): Uint8ClampedArray {
    const W = this.canvasW;
    const out = new Uint8ClampedArray(lw * lh * 4);
    for (let row = 0; row < lh; row++) {
      const srcOff = ((ly + row) * W + lx) * 4;
      const dstOff = row * lw * 4;
      out.set(master.subarray(srcOff, srcOff + lw * 4), dstOff);
    }
    return out;
  }

  private async renderRegionToCanvas(
    lx: number, ly: number, lw: number, lh: number
  ): Promise<boolean> {
    if (!this.masterBuffer) return false;
    if (lw <= 0 || lh <= 0) return true;
    try {
      const master = new Uint8ClampedArray(this.masterBuffer);
      const rgba = this.readRegionFromMaster(master, lx, ly, lw, lh);

      const bgra = new Uint8ClampedArray(rgba.length);
      for (let i = 0; i < rgba.length; i += 4) {
        bgra[i] = rgba[i + 2];
        bgra[i + 1] = rgba[i + 1];
        bgra[i + 2] = rgba[i];
        bgra[i + 3] = rgba[i + 3];
      }

      const pm = await image.createPixelMap(bgra.buffer as ArrayBuffer, {
        size: { width: lw, height: lh },
        srcPixelFormat: image.PixelMapFormat.BGRA_8888,
        pixelFormat: image.PixelMapFormat.BGRA_8888,
        editable: false
      });

      this.canvasCtx.save();
      this.canvasCtx.globalCompositeOperation = 'source-over';
      this.canvasCtx.globalAlpha = 1;
      this.canvasCtx.drawImage(pm, lx, ly);
      this.canvasCtx.restore();

      await pm.release();
      return true;
    } catch (e) {
      console.error('局部重绘失败:', e);
      return false;
    }
  }

  private patchBytes(patch: UndoPatch): number {
    return patch.oldPixels.byteLength + patch.newPixels.byteLength;
  }

  private trimUndoStack(): void {
    while (
      this.undoStack.length > MIN_UNDO_KEEP &&
        (this.undoStack.length > MAX_UNDO_STEPS || this.undoBytes > MAX_UNDO_BYTES)
    ) {
      const removed = this.undoStack.shift();
      if (removed) this.undoBytes -= this.patchBytes(removed);
    }
  }

  private trimRedoStack(): void {
    while (
      this.redoStack.length > MIN_REDO_KEEP &&
        (this.redoStack.length > MAX_REDO_STEPS || this.redoBytes > MAX_REDO_BYTES)
    ) {
      const removed = this.redoStack.shift();
      if (removed) this.redoBytes -= this.patchBytes(removed);
    }
  }

  private commitPatch(
    lx: number, ly: number, lw: number, lh: number,
    oldPixels: Uint8ClampedArray,
    newPixels: Uint8ClampedArray
  ): void {
    if (!this.masterBuffer) return;
    const W = this.canvasW;
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
    this.undoBytes += oldPixels.byteLength + newPixels.byteLength;
    this.trimUndoStack();

    this.redoStack = [];
    this.redoBytes = 0;

    this.canUndo = true;
    this.canRedo = false;
  }

  private writeRegionToMaster(
    master: Uint8ClampedArray,
    lx: number, ly: number, lw: number, lh: number,
    pixels: Uint8ClampedArray
  ): void {
    const W = this.canvasW;
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

      const ok = await this.renderRegionToCanvas(patch.x, patch.y, patch.w, patch.h);
      if (!ok) {
        this.writeRegionToMaster(master, patch.x, patch.y, patch.w, patch.h, patch.newPixels);
        console.warn('撤销失败：重绘未成功，已回滚 master');
        return;
      }

      this.undoStack.pop();
      this.undoBytes -= this.patchBytes(patch);

      this.redoStack.push(patch);
      this.redoBytes += this.patchBytes(patch);
      this.trimRedoStack();

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

      const ok = await this.renderRegionToCanvas(patch.x, patch.y, patch.w, patch.h);
      if (!ok) {
        this.writeRegionToMaster(master, patch.x, patch.y, patch.w, patch.h, patch.oldPixels);
        console.warn('重做失败：重绘未成功，已回滚 master');
        return;
      }

      this.redoStack.pop();
      this.redoBytes -= this.patchBytes(patch);

      this.undoStack.push(patch);
      this.undoBytes += this.patchBytes(patch);
      this.trimUndoStack();

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
      const W = this.canvasW;
      const H = this.canvasH;

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

      const patch = await taskpool.execute(task) as FillPatch;
      if (!patch || patch.w <= 0 || patch.h <= 0) {
        return;
      }

      const oldPixels = this.readRegionFromMaster(
        master, patch.x, patch.y, patch.w, patch.h
      );
      const newPixels = new Uint8ClampedArray(patch.buffer);

      this.writeRegionToMaster(
        master, patch.x, patch.y, patch.w, patch.h, newPixels
      );

      await this.renderRegionToCanvas(patch.x, patch.y, patch.w, patch.h);

      this.commitPatch(patch.x, patch.y, patch.w, patch.h, oldPixels, newPixels);
      this.isDirty = true;
    } catch (e) {
      console.error('填充失败:', e);
      promptAction.openToast({ message: '填充失败' }).catch(() => {});
    } finally {
      this.hideLoading();
      this.isFilling = false;
      this.isBusy = false;
    }
  }

  private async resizeCanvas(newW: number, newH: number, mode: ResizeMode): Promise<void> {
    if (this.isBusy || !this.masterBuffer) return;
    if (newW === this.canvasW && newH === this.canvasH) {
      promptAction.openToast({ message: '尺寸未变化' }).catch(() => {});
      return;
    }

    this.isBusy = true;
    this.showLoading('正在调整画布...');
    await new Promise<void>(r => setTimeout(r, 60));

    try {
      const oldW = this.canvasW;
      const oldH = this.canvasH;

      const copyBuffer = new ArrayBuffer(this.masterBuffer.byteLength);
      new Uint8ClampedArray(copyBuffer).set(new Uint8ClampedArray(this.masterBuffer));

      const modeNum =
        mode === 'stretch' ? 0 :
          mode === 'contain' ? 1 :
            mode === 'cover' ? 2 : 3;

      const task = new taskpool.Task(
        resizeCanvasTask,
        copyBuffer, oldW, oldH, newW, newH, modeNum, 255, 255, 255
      );
      task.setTransferList([copyBuffer]);

      const resultBuffer = await taskpool.execute(task) as ArrayBuffer;

      this.canvasW = newW;
      this.canvasH = newH;
      this.masterBuffer = resultBuffer;

      this.undoStack = [];
      this.redoStack = [];
      this.undoBytes = 0;
      this.redoBytes = 0;
      this.canUndo = false;
      this.canRedo = false;

      const updated: DrawProject = {
        id: this.project.id,
        name: this.project.name,
        width: newW,
        height: newH,
        createdAt: this.project.createdAt,
        updatedAt: Date.now()
      };
      await ProjectStore.upsert(updated);

      await new Promise<void>(r => setTimeout(r, 80));
      this.resetZoom();
      await this.renderMasterToCanvas();

      this.isDirty = true;
      promptAction.openToast({ message: '画布已调整' }).catch(() => {});
    } catch (e) {
      console.error('调整画布失败:', e);
      promptAction.openToast({ message: '调整失败' }).catch(() => {});
    } finally {
      this.hideLoading();
      this.isBusy = false;
    }
  }

  private showResizeDialog(): void {
    this.resizeCanvasController?.open();
  }

  private pickColorAt(x: number, y: number): void {
    try {
      const ix = Math.floor(x);
      const iy = Math.floor(y);
      if (ix < 0 || iy < 0 || ix >= this.canvasW || iy >= this.canvasH) {
        return;
      }
      if (!this.masterBuffer) return;
      const W = this.canvasW;
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
      const W = this.canvasW;
      const H = this.canvasH;

      const pixels = new Uint8ClampedArray(this.masterBuffer).slice();

      const path: string = ProjectStore.getImagePath(this.project.id);
      const thumbPath: string = ProjectStore.getThumbPath(this.project.id);
      const task = new taskpool.Task(encodePixelsToPng, pixels, W, H, path, thumbPath);
      const ok: boolean = await taskpool.execute(task) as boolean;

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
      promptAction.openToast({ message: '保存到沙箱失败' }).catch(() => {});
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

      promptAction.openToast({ message: '已保存到相册' }).catch(() => {});
    } catch (e) {
      console.error('保存到相册失败:', e);
      promptAction.openToast({ message: '保存到相册失败' }).catch(() => {});
    }
  }

  private async ensureMasterReady(): Promise<void> {
    if (this.masterReady) return;
    const W = this.canvasW;
    const H = this.canvasH;
    const region = this.readCanvasRegion(0, 0, W, H);
    if (region) {
      this.masterBuffer = region.buffer as ArrayBuffer;
      this.masterReady = true;
    }
  }

  async loadExistingImage(): Promise<void> {
    if (this.isImageLoaded) return;
    const path = ProjectStore.getImagePath(this.project.id);
    const W = this.canvasW;
    const H = this.canvasH;

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
        this.isDirty = true;
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

        const imgData: ImageData = this.canvasCtx.getImageData(0, 0, W, H);
        const buf = new ArrayBuffer(W * H * 4);
        new Uint8ClampedArray(buf).set(imgData.data);

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

  private onPointerDown(xVp: number, yVp: number): void {
    if (this.isFilling || this.isBusy) return;

    if (this.toolMode === 'pan') {
      this.panStartX = xVp;
      this.panStartY = yVp;
      this.panBaseX = this.offsetX;
      this.panBaseY = this.offsetY;
      this.isPanning = true;
      return;
    }

    const x = vp2px(xVp);
    const y = vp2px(yVp);

    if (this.toolMode === 'picker') {
      if (this.pickerHideTimer !== -1) {
        clearTimeout(this.pickerHideTimer);
        this.pickerHideTimer = -1;
      }
      this.pickerX = x;
      this.pickerY = y;
      this.showPickerPreview = true;
      this.pickColorAt(x, y);
      return;
    }

    if (this.toolMode === 'fill') {
      this.fillDownX = x;
      this.fillDownY = y;
      this.fillDownValid = true;
      return;
    }

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
  }

  private onPointerMove(xVp: number, yVp: number): void {
    if (this.isFilling || this.isBusy) return;

    if (this.toolMode === 'pan') {
      if (!this.isPanning) return;
      const scale = this.displayScale * this.userScale;
      this.offsetX = this.panBaseX + (xVp - this.panStartX) * scale;
      this.offsetY = this.panBaseY + (yVp - this.panStartY) * scale;
      this.clampOffset();
      return;
    }

    const x = vp2px(xVp);
    const y = vp2px(yVp);

    if (this.toolMode === 'picker') {
      this.pickerX = x;
      this.pickerY = y;
      this.pickColorAt(x, y);
      return;
    }

    if (this.toolMode === 'fill') {
      if (!this.fillDownValid) return;
      const dx = x - this.fillDownX;
      const dy = y - this.fillDownY;
      const thresh = vp2px(20);
      if (dx * dx + dy * dy > thresh * thresh) {
        this.fillDownValid = false;
      }
      return;
    }

    if (!this.isStroking) return;

    this.drawSegment(this.lastX, this.lastY, x, y);
    this.lastX = x;
    this.lastY = y;
    this.isDirty = true;
    if (x < this.brushMinX) this.brushMinX = x;
    if (y < this.brushMinY) this.brushMinY = y;
    if (x > this.brushMaxX) this.brushMaxX = x;
    if (y > this.brushMaxY) this.brushMaxY = y;
  }

  private onPointerUp(xVp: number, yVp: number): void {
    if (this.isFilling || this.isBusy) return;

    if (this.toolMode === 'pan') {
      this.isPanning = false;
      return;
    }

    const x = vp2px(xVp);
    const y = vp2px(yVp);

    if (this.toolMode === 'picker') {
      this.pickerX = x;
      this.pickerY = y;
      this.pickerHideTimer = setTimeout(() => {
        this.showPickerPreview = false;
        this.pickerHideTimer = -1;
      }, 700);
      return;
    }

    if (this.toolMode === 'fill') {
      if (this.fillDownValid) {
        this.performFill(this.fillDownX, this.fillDownY);
      }
      this.fillDownValid = false;
      return;
    }

    if (!this.isStroking) return;
    this.isStroking = false;
    if (!this.masterBuffer) return;

    const r = this.curWidth / 2 + 2;
    const lx = Math.max(0, Math.floor(this.brushMinX - r));
    const ly = Math.max(0, Math.floor(this.brushMinY - r));
    const lw = Math.min(this.canvasW - lx,
      Math.ceil(this.brushMaxX - this.brushMinX + r * 2));
    const lh = Math.min(this.canvasH - ly,
      Math.ceil(this.brushMaxY - this.brushMinY + r * 2));
    if (lw <= 0 || lh <= 0) return;

    const newPixels = this.readCanvasRegion(lx, ly, lw, lh);
    if (!newPixels) return;

    const W = this.canvasW;
    const master = new Uint8ClampedArray(this.masterBuffer);
    const oldPixels = new Uint8ClampedArray(lw * lh * 4);
    for (let row = 0; row < lh; row++) {
      const srcOff = ((ly + row) * W + lx) * 4;
      const dstOff = row * lw * 4;
      oldPixels.set(master.subarray(srcOff, srcOff + lw * 4), dstOff);
    }

    this.commitPatch(lx, ly, lw, lh, oldPixels, newPixels);
  }

  private onPointerCancel(): void {
    this.isStroking = false;
    this.isPanning = false;
    this.fillDownValid = false;
    this.showPickerPreview = false;
  }

  private onCanvasTouch(event: TouchEvent): void {
    if (!event.touches || event.touches.length === 0) {
      this.fillDownValid = false;
      return;
    }
    if (this.isPinching || event.touches.length > 1) {
      this.fillDownValid = false;
      return;
    }
    if (this.isFilling || this.isBusy) return;

    const touch = event.touches[0];
    if (touch.id !== 0) return;

    if (event.type === TouchType.Down) {
      this.onPointerDown(touch.x, touch.y);
    } else if (event.type === TouchType.Move) {
      this.onPointerMove(touch.x, touch.y);
    } else if (event.type === TouchType.Up) {
      this.onPointerUp(touch.x, touch.y);
    } else if (event.type === TouchType.Cancel) {
      this.onPointerCancel();
    }
  }

  private onCanvasMouse(event: MouseEvent): void {
    const action = event.action;

    if (action === MouseAction.Press) {
      if (event.button !== MouseButton.Left) return;
      this.mouseLeftDown = true;
      this.onPointerDown(event.x, event.y);
    } else if (action === MouseAction.Move) {
      if (!this.mouseLeftDown) return;
      this.onPointerMove(event.x, event.y);
    } else if (action === MouseAction.Release) {
      if (!this.mouseLeftDown) return;
      this.mouseLeftDown = false;
      this.onPointerUp(event.x, event.y);
    }
  }

  private toOuterX(canvasX: number): number {
    const scale = this.displayScale * this.userScale;
    return this.offsetX + this.outerW / 2 + (px2vp(canvasX) - px2vp(this.canvasW) / 2) * scale;
  }

  private toOuterY(canvasY: number): number {
    const scale = this.displayScale * this.userScale;
    return this.offsetY + this.outerH / 2 + (px2vp(canvasY) - px2vp(this.canvasH) / 2) * scale;
  }

  private adjustStrokeWidth(delta: number): void {
    if (this.toolMode === 'fill') {
      const next = this.fillTol + delta;
      const clamped = Math.max(0, Math.min(128, next));
      if (clamped === this.fillTol) return;
      this.fillTol = clamped;
      return;
    }

    if (this.toolMode === 'brush' || this.toolMode === 'eraser') {
      const next = this.strokeWidth + delta;
      const clamped = Math.max(1, Math.min(40, next));
      if (clamped === this.strokeWidth) return;
      this.strokeWidth = clamped;
      return;
    }
  }

  @Builder
  ColorSheetBuilder() {
    PickColorComponent({
      currentColor: this.color,
      onColorSelected: (c: string) => {
        this.color = c;
      },
      onClose: () => {
        this.showColorSheet = false;
      }
    })
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
        .fontSize(12)
        .fontColor(this.toolMode === key ? $r('app.color.brand') : $r('sys.color.font_primary'))
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .onTouch((e: TouchEvent): boolean => {
      if (e.type === TouchType.Down) this.isPressingTool = true;
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.isPressingTool = false;
      return true;
    })
    .onClick(() => {
      onTap();
    })
    .onHover((isHover: boolean) => {
      this.hoverStates[key] = isHover;
    })
    .onMouse(() => {})
    .backgroundColor(this.hoverStates[key] ? $r('app.color.hover_color') : Color.Transparent)
    .borderRadius(12)
    .hitTestBehavior(HitTestMode.Block)
  }

  @Builder
  UndoButton() {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.undo'))
        .fontSize(20)
        .fontColor([this.canUndo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary')])
      Text('撤销')
        .fontSize(12)
        .fontColor(this.canUndo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .enabled(this.canUndo && !this.isBusy)
    .onTouch((e: TouchEvent): boolean => {
      if (e.type === TouchType.Down) this.isPressingDoBar = true;
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.isPressingDoBar = false;
      return true;
    })
    .onClick(async () => {
      await this.undo();
    })
    .onHover((isHover: boolean) => {
      this.hoverStates['undo'] = isHover;
    })
    .onMouse(() => {})
    .backgroundColor(this.hoverStates['undo'] ? $r('app.color.hover_color') : Color.Transparent)
    .borderRadius(12)
    .hitTestBehavior(HitTestMode.Block)
  }

  @Builder
  RedoButton() {
    Column({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.redo'))
        .fontSize(20)
        .fontColor([this.canRedo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary')])
      Text('重做')
        .fontSize(12)
        .fontColor(this.canRedo && !this.isBusy ? $r('sys.color.font_primary') : $r('sys.color.font_tertiary'))
    }
    .layoutWeight(1)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .enabled(this.canRedo && !this.isBusy)
    .onTouch((e: TouchEvent): boolean => {
      if (e.type === TouchType.Down) this.isPressingDoBar = true;
      else if (e.type === TouchType.Up || e.type === TouchType.Cancel) this.isPressingDoBar = false;
      return true;
    })
    .onClick(async () => {
      await this.redo();
    })
    .onHover((isHover: boolean) => {
      this.hoverStates['redo'] = isHover;
    })
    .onMouse(() => {})
    .backgroundColor(this.hoverStates['redo'] ? $r('app.color.hover_color') : Color.Transparent)
    .borderRadius(12)
    .hitTestBehavior(HitTestMode.Block)
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
            .hitTestBehavior(this.toolMode === 'fill' ? HitTestMode.Block : HitTestMode.None)
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
            .hitTestBehavior((this.toolMode === 'brush' || this.toolMode === 'eraser') ? HitTestMode.Block : HitTestMode.None)
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
            .fontSize(12)
            .fontColor($r('sys.color.font_primary'))
        }
        .layoutWeight(1)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .onClick(() => {
          this.showColorSheet = true;
        })
        .onHover((isHover: boolean) => {
          this.hoverStates['color'] = isHover;
        })
        .onTouch((_e: TouchEvent) => true)
        .onMouse(() => {})
        .backgroundColor(this.hoverStates['color'] ? $r('app.color.hover_color') : Color.Transparent)
        .borderRadius(12)
        .hitTestBehavior(HitTestMode.Block)
        .bindSheet(this.showColorSheet, this.ColorSheetBuilder(), {
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
              .width(px2vp(this.canvasW))
              .height(px2vp(this.canvasH))
              .backgroundColor(Color.White)
              .onReady(() => {
                this.canvasCtx.globalCompositeOperation = 'source-over';
                this.canvasCtx.globalAlpha = 1;
                this.canvasCtx.fillStyle = '#FFFFFF';
                this.canvasCtx.fillRect(0, 0, this.canvasW, this.canvasH);
                this.loadExistingImage();
              })
              .onTouch((e: TouchEvent) => this.onCanvasTouch(e))
              .onMouse((e: MouseEvent) => this.onCanvasMouse(e))
              .hitTestBehavior(HitTestMode.Transparent)
          }
          .width(px2vp(this.canvasW))
          .height(px2vp(this.canvasH))
          .clip(false)
          .translate({ x: this.offsetX, y: this.offsetY })
          .scale({
            x: this.displayScale * this.userScale,
            y: this.displayScale * this.userScale,
            z: 1
          })

          if (this.toolMode === 'picker' && this.showPickerPreview) {
            this.PickerPreview()
          }

          if (this.isDragHover) {
            Column({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.picture_on_square'))
                .fontSize(64)
                .fontColor([$r('app.color.brand')])
              Text('松手以叠加到画板')
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.brand'))
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
            .height('100%')
            .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
            .backgroundColor('#2243A740')
            .border({
              width: 2,
              color: $r('app.color.brand')
            })
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

          const canvasVpW = px2vp(this.canvasW);
          const canvasVpH = px2vp(this.canvasH);
          const s = Math.min(availW / canvasVpW, availH / canvasVpH);
          this.displayScale = Math.min(s, 1);
          this.clampOffset();
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onAxisEvent((e: AxisEvent) => this.onCanvasAxis(e))
        .gesture(
          PinchGesture({ fingers: 2 })
            .onActionStart((e: GestureEvent) => {
              this.isPinching = true;
              this.isPanning = false;
              this.showPickerPreview = false;
              this.fillDownValid = false;
              this.pinchBase = this.userScale;
              this.panBaseX = this.offsetX;
              this.panBaseY = this.offsetY;
              this.pinchCenterBaseX = e.pinchCenterX;
              this.pinchCenterBaseY = e.pinchCenterY;
            })
            .onActionUpdate((e: GestureEvent) => {
              if (!e) return;
              this.userScale = this.clampScale(this.pinchBase * e.scale);
              const dx = e.pinchCenterX - this.pinchCenterBaseX;
              const dy = e.pinchCenterY - this.pinchCenterBaseY;
              this.offsetX = this.panBaseX + dx;
              this.offsetY = this.panBaseY + dy;
              this.clampOffset();
            })
            .onActionEnd(() => {
              this.pinchBase = this.userScale;
              this.panBaseX = this.offsetX;
              this.panBaseY = this.offsetY;
              this.isPinching = false;
              this.clampOffset();
            })
        )
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_primary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .focusable(true)
      .defaultFocus(true)
      .keyboardShortcut('z', [ModifierKey.CTRL], () => {
        this.undo();
      })
      .keyboardShortcut('z', [ModifierKey.CTRL, ModifierKey.SHIFT], () => {
        this.redo();
      })
      .keyboardShortcut('y', [ModifierKey.CTRL], () => {
        this.redo();
      })
      .keyboardShortcut('=', [ModifierKey.CTRL], () => {
        this.zoomAt(this.outerW / 2, this.outerH / 2, 1.1);
      })
      .keyboardShortcut('=', [ModifierKey.CTRL, ModifierKey.SHIFT], () => {
        this.zoomAt(this.outerW / 2, this.outerH / 2, 1.1);
      })
      .keyboardShortcut('-', [ModifierKey.CTRL], () => {
        this.zoomAt(this.outerW / 2, this.outerH / 2, 0.9);
      })
      .keyboardShortcut('0', [ModifierKey.CTRL], () => {
        this.resetZoom();
      })
      .onKeyPreIme((event: KeyEvent): boolean => {
        if (event.type !== KeyType.Down) return false;
        switch (event.keyCode) {
          case KeyCode.KEYCODE_B:
            this.toolMode = 'brush';
            this.showPickerPreview = false;
            return true;
          case KeyCode.KEYCODE_E:
            this.toolMode = 'eraser';
            this.showPickerPreview = false;
            return true;
          case KeyCode.KEYCODE_F:
            this.toolMode = 'fill';
            this.showPickerPreview = false;
            return true;
          case KeyCode.KEYCODE_I:
            this.toolMode = 'picker';
            this.showPickerPreview = false;
            return true;
          case KeyCode.KEYCODE_H:
            this.toolMode = 'pan';
            this.showPickerPreview = false;
            return true;
          case KeyCode.KEYCODE_LEFT_BRACKET:
            this.adjustStrokeWidth(-2);
            return true;
          case KeyCode.KEYCODE_RIGHT_BRACKET:
            this.adjustStrokeWidth(2);
            return true;
          default:
            return false;
        }
      })
      .allowDrop([uniformTypeDescriptor.UniformDataType.IMAGE])
      .onDragEnter(() => {
        this.isDragHover = true;
      })
      .onDragLeave(() => {
        this.isDragHover = false;
      })
      .onDrop((event: DragEvent) => {
        this.isDragHover = false;
        this.handleImageDrop(event);
      })
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
          value: this.buildMenuItems(),
          maxCount: this.windowWidth >= 840 ? 5 :
            (this.windowWidth >= 500 ? 3 : 2)
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
          promptAction.openToast({ message: value ? '已保存' : '保存失败' }).catch(() => {});
          this.pathStack.pop();
        });
        return true;
      }
      return false;
    })
  }
}