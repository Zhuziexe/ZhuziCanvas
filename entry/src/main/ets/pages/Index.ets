import { common } from '@kit.AbilityKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { componentSnapshot, LengthMetrics, promptAction } from '@kit.ArkUI';
import {
  HdsNavigation, hdsMaterial, ScrollEffectType, TextStyleMode,
  HdsNavigationTitleMode
} from '@kit.UIDesignKit';
import { ProjectStore, DrawProject } from '../common/ProjectStore';
import { EditorPage } from './EditorPage';
import { getMenuOptions } from '../common/UIUtils';
import { NewProjectDialog } from '../dialogs/NewProjectDialog';
import { RenameProjectDialog } from '../dialogs/RenameProjectDialog';
import { PrivacyConsent } from './PrivacyConsent';
import { DialogType, TextType } from '../common/CustomTypes';
import { PrivacyConsentVM } from '../viewmodels/PrivacyConsentVM';
import { PrivacyFullPage } from './PrivacyFullPage';
import { preferences, unifiedDataChannel } from '@kit.ArkData';
import { AboutPage } from './AboutPage';
import { uniformTypeDescriptor, uniformDataStruct } from '@kit.ArkData';
import { ImageOverlayPage, ImageOverlayParam } from './ImageOverlayPage';
import { TextPage, TextParam } from './TextPage';
import { deviceInfo } from '@kit.BasicServicesKit';

type SortBy = 'time' | 'name';
type ViewMode = 'list' | 'grid';

const THUMB_MAX_SIDE = 256;
const PREF_NAME = 'app_settings';
const KEY_PRIVACY_AGREED = 'privacy_agreed';
const KEY_VIEW_MODE = 'project_view_mode';

class ProjectDataSource implements IDataSource {
  private projects: DrawProject[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.projects.length;
  }

  getData(index: number): DrawProject {
    return this.projects[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const pos = this.listeners.indexOf(listener);
    if (pos >= 0) {
      this.listeners.splice(pos, 1);
    }
  }

  setProjects(projects: DrawProject[]): void {
    this.projects = projects;
    this.listeners.forEach((l: DataChangeListener) => l.onDataReloaded());
  }

  getAllNames(): string[] {
    return this.projects.map((p: DrawProject) => p.name);
  }
}

@Entry
@Component
struct Index {
  private dataSource: ProjectDataSource = new ProjectDataSource();
  @State sortBy: SortBy = 'time';
  @State viewMode: ViewMode = 'list';
  @State projectCount: number = 0;
  @State thumbVersion: number = 0;
  @State isShowingPrivacy: boolean = false;
  @State isShowingFullPrivacy: boolean = false;
  @State isShowingAbout: boolean = false;
  @State isDragHover: boolean = false;
  @State contextMenuProject: DrawProject | null = null;
  @State draggingProjectId: string = '';

  private privacyVM: PrivacyConsentVM = new PrivacyConsentVM();

  @StorageProp('windowWidth') windowWidth: number = 0;
  @StorageLink('projectsRefreshToken') @Watch('onProjectsChanged')
  projectsRefreshToken: number = 0;

  private pathStack: NavPathStack = new NavPathStack();
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private newProjectDialogController: CustomDialogController | null = null;
  private renameDialogController: CustomDialogController | null = null;
  private scroller: Scroller = new Scroller();
  private gridscroller:Scroller = new Scroller();

  onProjectsChanged(): void {
    this.loadProjects();
  }

  aboutToAppear(): void {
    ProjectStore.init(this.context);
    if (AppStorage.get<number>('projectsRefreshToken') === undefined) {
      AppStorage.setOrCreate('projectsRefreshToken', 0);
    }
    this.restoreViewMode();
    this.loadProjects();
    this.generateMissingThumbs();
    this.cleanOrphanImages();
    this.initPrivacyVM();
    this.checkPrivacyConsent();
  }

  private restoreViewMode(): void {
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      this.viewMode = pref.getSync(KEY_VIEW_MODE, 'list') as ViewMode;
    } catch (e) {
      this.viewMode = 'list';
    }
  }

  private toggleView(): void {
    this.viewMode = this.viewMode === 'list' ? 'grid' : 'list';
    preferences.getPreferences(this.context, PREF_NAME).then((pref) => {
      pref.put(KEY_VIEW_MODE, this.viewMode);
      pref.flush();
    }).catch(() => {});
  }

  private getColumnsTemplate(): string {
    const w = this.windowWidth;
    let n: number;
    if (w < 600) n = 2;
    else if (w < 840) n = 3;
    else if (w < 1200) n = 4;
    else n = 5;
    return Array(n).fill('1fr').join(' ');
  }

  private checkPrivacyConsent() {
    if (!this.hasAgreedPrivacy()) {
      this.isShowingPrivacy = true;
    }
  }

  private hasAgreedPrivacy(): boolean {
    try {
      const pref = preferences.getPreferencesSync(this.context, { name: PREF_NAME });
      return pref.getSync(KEY_PRIVACY_AGREED, false) as boolean;
    } catch (e) {
      return false;
    }
  }

  private async markPrivacyAgreed(): Promise<void> {
    try {
      const pref = await preferences.getPreferences(this.context, PREF_NAME);
      await pref.put(KEY_PRIVACY_AGREED, true);
      await pref.flush();
    } catch (e) {
      console.error('写入隐私同意状态失败:', e);
    }
  }

  private initPrivacyVM() {
    this.privacyVM.dialogType = DialogType.SHEET;
    this.privacyVM.sheetType = SheetType.BOTTOM;
    this.privacyVM.appName = '竹子画板';
    this.privacyVM.appDescription = '一个只属于你自己的开源画板';

    this.privacyVM.document = [
      {
        text: '本应用',
        type: TextType.PLAIN
      },
      {
        text: '无需联网、不申请任何需要您手动授权的系统权限、也不会收集任何个人信息',
        type: TextType.PLAIN,
        color: $r('sys.color.font_primary'),
        fontWeight: FontWeight.Medium
      },
      {
        text: '。您的所有画作、项目、缩略图都保存在手机本地，' +
          '不会上传到任何服务器。\n竹子画板是一个开源项目。\n' +
          '点击"同意"即表示您已知悉以上说明。个人信息处理详情，请参阅',
        type: TextType.PLAIN
      },
      {
        text: '关于竹子画板与隐私的说明',
        type: TextType.ACTION,
        color: $r('app.color.brand'),
        onAction: () => {
          this.isShowingFullPrivacy = true;
        }
      },
      { text: '，', type: TextType.PLAIN },
      {
        text: '权限使用说明',
        type: TextType.ACTION,
        color: $r('app.color.brand'),
        onAction: () => {
          this.showPermissionInfo();
        }
      },
      { text: '。', type: TextType.PLAIN }
    ];

    this.privacyVM.onAccept = async () => {
      this.isShowingPrivacy = false;
      await this.markPrivacyAgreed();
    };

    this.privacyVM.onReject = async () => {
      try {
        await this.context.terminateSelf();
      } catch {}
    };
  }

  private showPermissionInfo(): void {
    AlertDialog.show({
      title: '权限使用说明',
      message: '竹子画板不申请任何需要您手动授权的系统权限。\n\n' +
        '基于安全访问机制，竹子画板只能访问你主动选择的图片，看不到相册里的其他内容。\n\n' +
        '应用不会读取你的通讯录、位置、麦克风、摄像头或任何其他个人信息。\n\n' +
        '应用声明了“预关闭动作”权限（ohos.permission.PREPARE_APP_TERMINATE），' +
        '用于在电脑端关闭应用时弹出“是否保存”确认提示。该权限系统自动授予，不涉及任何数据收集。',
      confirm: {
        value: '知道了',
        action: () => {},
        fontColor: $r('app.color.brand')
      }
    });
  }

  private sortProjects(list: DrawProject[], by: SortBy): DrawProject[] {
    const arr = [...list];
    if (by === 'time') {
      arr.sort((a: DrawProject, b: DrawProject) => b.updatedAt - a.updatedAt);
    } else {
      arr.sort((a: DrawProject, b: DrawProject) => a.name.localeCompare(b.name));
    }
    return arr;
  }

  private toggleSort(): void {
    this.sortBy = this.sortBy === 'time' ? 'name' : 'time';
    this.loadProjects();
  }

  async loadProjects(): Promise<void> {
    const list = await ProjectStore.list();
    const sorted = this.sortProjects(list, this.sortBy);
    this.dataSource.setProjects(sorted);
    this.projectCount = sorted.length;
  }

  openProject(project: DrawProject): void {
    this.pathStack.pushPathByName('EditorPage', project);
  }

  private getThumbUri(id: string): string {
    const p = ProjectStore.getThumbPath(id);
    try {
      if (fileIo.accessSync(p)) {
        return fileUri.getUriFromPath(p);
      }
    } catch (error) {
      return '';
    }
    return '';
  }

  async generateMissingThumbs(): Promise<void> {
    try {
      const projects = await ProjectStore.list();
      let generated = 0;
      for (const p of projects) {
        const thumbPath = ProjectStore.getThumbPath(p.id);
        if (fileIo.accessSync(thumbPath)) continue;

        const srcPath = ProjectStore.getImagePath(p.id);
        if (!fileIo.accessSync(srcPath)) continue;

        try {
          const file = fileIo.openSync(srcPath, fileIo.OpenMode.READ_ONLY);
          const imageSource = image.createImageSource(file.fd);
          const pixelMap = await imageSource.createPixelMap();

          const info = await pixelMap.getImageInfo();
          const maxSide = Math.max(info.size.width, info.size.height);
          if (maxSide > THUMB_MAX_SIDE) {
            const s = THUMB_MAX_SIDE / maxSide;
            await pixelMap.scale(s, s);
          }

          const packer = image.createImagePacker();
          const buf = await packer.packing(pixelMap, {
            format: 'image/png',
            quality: 80
          });
          const out = fileIo.openSync(thumbPath,
            fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          fileIo.writeSync(out.fd, buf);
          fileIo.closeSync(out);

          await packer.release();
          await pixelMap.release();
          await imageSource.release();
          fileIo.closeSync(file);

          generated++;
        } catch (e) {
          console.warn(`生成缩略图失败: ${p.id}`, e);
        }
      }
      if (generated > 0) {
        console.info(`补齐缩略图完成，共 ${generated} 个`);
        this.thumbVersion++;
        await this.loadProjects();
      }
    } catch (e) {
      console.error('补齐缩略图失败:', e);
    }
  }

  createProject(): void {
    this.newProjectDialogController = new CustomDialogController({
      builder: NewProjectDialog({
        existingNames: this.dataSource.getAllNames(),
        onConfirm: async (name: string, w: number, h: number) => {
          const id = Date.now().toString(36) + Math.random().toString(36).substring(2, 8);
          const project: DrawProject = {
            id: id,
            name: name,
            width: w,
            height: h,
            createdAt: Date.now(),
            updatedAt: Date.now()
          };
          await ProjectStore.upsert(project);
          await this.loadProjects();
          this.openProject(project);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.newProjectDialogController.open();
  }

  showRenameDialog(project: DrawProject): void {
    this.renameDialogController = new CustomDialogController({
      builder: RenameProjectDialog({
        currentName: project.name,
        existingNames: this.dataSource.getAllNames(),
        onConfirm: async (newName: string) => {
          await this.doRename(project, newName);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.renameDialogController.open();
  }

  async doRename(project: DrawProject, newName: string): Promise<void> {
    try {
      const list = await ProjectStore.list();
      const target = list.find((p: DrawProject) => p.id === project.id);
      if (!target) {
        promptAction.openToast({ message: '项目不存在' }).catch(() => {});
        return;
      }
      target.name = newName;
      target.updatedAt = Date.now();
      await ProjectStore.save(list);
      await this.loadProjects();
      promptAction.openToast({ message: '已重命名' }).catch(() => {});
    } catch (e) {
      console.error('重命名失败:', e);
      promptAction.openToast({ message: '重命名失败' }).catch(() => {});
    }
  }

  deleteProject(project: DrawProject): void {
    AlertDialog.show({
      title: '确认删除',
      message: `确定要删除项目"${project.name}"吗？`,
      buttons: [
        { value: '取消', action: () => {}, fontColor: $r('app.color.brand') },
        {
          value: '确定',
          fontColor: $r('sys.color.warning'),
          action: async () => {
            await ProjectStore.remove(project.id);
            await this.loadProjects();
            promptAction.openToast({ message: '已删除' }).catch(() => {});
          }
        }
      ]
    });
  }

  async cleanOrphanImages(): Promise<void> {
    try {
      const projects = await ProjectStore.list();
      const validNames = new Set<string>();
      projects.forEach((p: DrawProject) => {
        validNames.add(`${p.id}.png`);
        validNames.add(`${p.id}_thumb.png`);
      });
      const filesDir = this.context.filesDir;
      const files = fileIo.listFileSync(filesDir);
      let count = 0;
      for (const f of files) {
        if (f.endsWith('.png') && !validNames.has(f)) {
          try {
            fileIo.unlinkSync(`${filesDir}/${f}`);
            count++;
          } catch (e) {
            console.warn(`删除孤立 PNG 失败: ${f}`, e);
          }
        }
      }
      if (count > 0) {
        console.info(`清理孤立 PNG 完成，共 ${count} 个`);
      }
    } catch (e) {
      console.error('清理孤立 PNG 失败:', e);
    }
  }

  private async importImagesFromUris(uris: string[]): Promise<number> {
    if (!uris || uris.length === 0) return 0;
    let successCount = 0;

    const usedNames = new Set<string>(this.dataSource.getAllNames());

    for (const sourceUri of uris) {
      try {
        const srcFile = fileIo.openSync(sourceUri, fileIo.OpenMode.READ_ONLY);
        const stat = fileIo.statSync(srcFile.fd);
        const buffer = new ArrayBuffer(stat.size);
        fileIo.readSync(srcFile.fd, buffer);
        fileIo.closeSync(srcFile);

        let imgW = 1280;
        let imgH = 720;
        let pixelMap: image.PixelMap | null = null;

        try {
          const imageSource = image.createImageSource(buffer);
          const info = await imageSource.getImageInfo();
          imgW = info.size.width;
          imgH = info.size.height;
          pixelMap = await imageSource.createPixelMap();
          imageSource.release();
        } catch (e) {
          console.warn('读取图片失败,使用默认尺寸');
        }

        let baseName = '导入项目';
        let finalName = baseName;
        let counter = 2;
        while (usedNames.has(finalName)) {
          finalName = `${baseName}(${counter})`;
          counter++;
        }
        usedNames.add(finalName);

        const newId = Date.now().toString(36) + Math.random().toString(36).substring(2, 8);
        const destPath = ProjectStore.getImagePath(newId);

        let pngBuffer: ArrayBuffer | null = null;

        if (pixelMap) {
          const maxSide = Math.max(imgW, imgH);
          if (maxSide > 2560) {
            const s = 2560 / maxSide;
            await pixelMap.scale(s, s);
            imgW = Math.max(1, Math.round(imgW * s));
            imgH = Math.max(1, Math.round(imgH * s));
          }

          const packer = image.createImagePacker();
          try {
            pngBuffer = await packer.packing(pixelMap, {
              format: 'image/png',
              quality: 100
            });
          } finally {
            await packer.release();
          }
        }

        if (!pngBuffer) {
          pngBuffer = buffer;
        }

        const destFile = fileIo.openSync(destPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        try {
          fileIo.writeSync(destFile.fd, pngBuffer);
        } finally {
          fileIo.closeSync(destFile);
        }

        if (pixelMap) {
          try {
            const thumbPath = ProjectStore.getThumbPath(newId);
            const thumbInfo = await pixelMap.getImageInfo();
            const thumbMaxSide = Math.max(thumbInfo.size.width, thumbInfo.size.height);
            if (thumbMaxSide > THUMB_MAX_SIDE) {
              const s = THUMB_MAX_SIDE / thumbMaxSide;
              await pixelMap.scale(s, s);
            }
            const packer = image.createImagePacker();
            const tb = await packer.packing(pixelMap, { format: 'image/png', quality: 80 });
            const tf = fileIo.openSync(thumbPath,
              fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
            try {
              fileIo.writeSync(tf.fd, tb);
            } finally {
              fileIo.closeSync(tf);
            }
            await packer.release();
          } catch (e) {
            console.warn('导入时生成缩略图失败:', e);
          } finally {
            await pixelMap.release();
          }
        }

        const project: DrawProject = {
          id: newId,
          name: finalName,
          width: imgW,
          height: imgH,
          createdAt: Date.now(),
          updatedAt: Date.now()
        };
        await ProjectStore.upsert(project);
        successCount++;
      } catch (e) {
        console.error('导入单张图片失败:', e);
      }
    }

    if (successCount > 0) {
      await this.loadProjects();
    }
    return successCount;
  }

  async importPng(): Promise<void> {
    try {
      const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
      photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;

      const photoPicker = new photoAccessHelper.PhotoViewPicker();
      const result = await photoPicker.select(photoSelectOptions);

      if (!result || !result.photoUris || result.photoUris.length === 0) {
        return;
      }

      const ok = await this.importImagesFromUris(result.photoUris);
      promptAction.openToast({ message: ok > 0 ? '导入成功' : '导入失败' }).catch(() => {});
    } catch (e) {
      console.error('导入失败:', e);
      promptAction.openToast({ message: '导入失败' }).catch(() => {});
    }
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

  private async handleImageDrop(event: DragEvent): Promise<void> {
    if (this.draggingProjectId != '') {
      console.info('忽略本应用自己拖出的数据');
      return;
    }
    const uris = this.extractImageUris(event);
    if (uris.length === 0) {
      promptAction.openToast({ message: '只能拖入图片文件' }).catch(() => {});
      return;
    }
    const ok = await this.importImagesFromUris(uris);
    promptAction.openToast({ message: `已导入 ${ok} 张图片` }).catch(() => {});
  }

  private buildDragData(event: DragEvent, project: DrawProject): void {
    const imagePath = ProjectStore.getImagePath(project.id);
    const uri = fileUri.getUriFromPath(imagePath);

    const imageRecord = new unifiedDataChannel.Image();
    imageRecord.imageUri = uri;

    const unifiedData = new unifiedDataChannel.UnifiedData(imageRecord);
    event.setData(unifiedData);
  }

  @Builder
  PageMap(name: string, param: object) {
    if (name === 'EditorPage') {
      EditorPage({ project: param as DrawProject })
    } else if (name === 'ImageOverlayPage') {
      ImageOverlayPage({
        project: (param as ImageOverlayParam).project,
        overlayUri: (param as ImageOverlayParam).overlayUri
      })
    } else if (name === 'TextPage') {
      TextPage({ project: (param as TextParam).project })
    }
  }

  @Builder
  EmptyState() {
    Column() {
      SymbolGlyph($r('sys.symbol.paintpalette'))
        .fontSize(64)
        .fontColor([$r('sys.color.font_tertiary')])
      Text('还没有项目')
        .fontSize(18)
        .fontColor($r('sys.color.font_primary'))
        .margin({ top: 16 })
      Text('点击右上角 + 创建新项目')
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .margin({ top: 8 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ bottom: 80 })
  }

  @Builder
  projectContextMenu(): void {
    Menu() {
      MenuItem({ content: '重命名' })
        .onClick(() => {
          if (this.contextMenuProject) this.showRenameDialog(this.contextMenuProject);
        })
      MenuItem({ content: '删除' })
        .onClick(() => {
          if (this.contextMenuProject) this.deleteProject(this.contextMenuProject);
        })
        .contentFontColor($r('sys.color.warning'))
    }
  }

  @Builder
  ProjectListCard(project: DrawProject) {
    Row() {
      Image(this.getThumbUri(project.id))
        .width(48)
        .height(48)
        .borderRadius(8)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('sys.color.background_tertiary'))
        .alt($r('app.media.startIcon'))
        .draggable(false)
        .id(`thumb_${project.id}`)
        .interpolation(ImageInterpolation.Low)

      Column({ space: 4 }) {
        Text(project.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${project.width} × ${project.height}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ left: 12 })

      Button() {
        SymbolGlyph($r('sys.symbol.dot_grid_1x2'))
          .fontSize(24)
          .fontColor([$r('sys.color.font_primary')])
      }
      .buttonStyle(ButtonStyleMode.TEXTUAL)
      .width(40)
      .height(40)
      .bindMenu([
        { value: '重命名', action: () => this.showRenameDialog(project) },
        { value: '删除', action: () => this.deleteProject(project) }
      ], getMenuOptions())
      .draggable(false)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.listitem'))
    .borderRadius(12)
    .hoverEffect(HoverEffect.Highlight)
    .draggable(true)
    .onDragStart((event: DragEvent) => {
      this.draggingProjectId = project.id;
      this.buildDragData(event, project);
      try {
        const pm = componentSnapshot.getSync(`thumb_${project.id}`);
        return { pixelMap: pm } as DragItemInfo;
      } catch (e) {
        console.warn('获取缩略图快照失败，回退默认预览', e);
        return {} as DragItemInfo;
      }
    })
    .onDragEnd(() => {
      this.draggingProjectId = '';
    })
    .onClick(() => {
      if (this.draggingProjectId === project.id) return;
      this.openProject(project);
    })
    .onMouse((event: MouseEvent) => {
      if (event.button === MouseButton.Right) {
        this.contextMenuProject = project;
      }
    })
    .bindContextMenu(this.projectContextMenu, ResponseType.RightClick)
  }

  @Builder
  ProjectGridCard(project: DrawProject) {
    Column({ space: 8 }) {
      Image(this.getThumbUri(project.id))
        .width('100%')
        .aspectRatio(1)
        .borderRadius(12)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('sys.color.background_tertiary'))
        .alt($r('app.media.startIcon'))
        .draggable(false)
        .id(`thumb_${project.id}`)
        .interpolation(ImageInterpolation.Low)

      Text(project.name)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .padding(8)
    .backgroundColor($r('app.color.listitem'))
    .borderRadius(12)
    .hoverEffect(HoverEffect.Highlight)
    .draggable(true)
    .onDragStart((event: DragEvent) => {
      this.draggingProjectId = project.id;
      this.buildDragData(event, project);
      try {
        const pm = componentSnapshot.getSync(`thumb_${project.id}`);
        return { pixelMap: pm } as DragItemInfo;
      } catch (e) {
        console.warn('获取缩略图快照失败，回退默认预览', e);
        return {} as DragItemInfo;
      }
    })
    .onDragEnd(() => {
      this.draggingProjectId = '';
    })
    .onClick(() => {
      if (this.draggingProjectId === project.id) return;
      this.openProject(project);
    })
    .onTouch((e: TouchEvent) => {
      if (e.type === TouchType.Down) {
        this.contextMenuProject = project;
      }
    })
    .onMouse((event: MouseEvent) => {
      if (event.button === MouseButton.Right) {
        this.contextMenuProject = project;
      }
    })
    .bindContextMenu(this.projectContextMenu, ResponseType.RightClick)
    .bindContextMenu(this.projectContextMenu, ResponseType.LongPress)
  }

  @Builder
  ProjectList() {
    List({ space: 8, scroller: this.scroller }) {
      LazyForEach(this.dataSource, (project: DrawProject) => {
        ListItem() {
          this.ProjectListCard(project)
        }
        .padding({ left: 16, right: 16 })
      }, (project: DrawProject) => `${project.id}_${project.updatedAt}_${this.thumbVersion}`)
    }
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .padding({ top: 8, bottom: 16 })
    .edgeEffect(EdgeEffect.Spring)
    .contentEndOffset(24)
    .cachedCount(3)
    .clip(false)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  ProjectGrid() {
    Grid(this.gridscroller) {
      LazyForEach(this.dataSource, (project: DrawProject) => {
        GridItem() {
          this.ProjectGridCard(project)
        }
      }, (project: DrawProject) => `${project.id}_${project.updatedAt}_${this.thumbVersion}`)
    }
    .columnsTemplate(this.getColumnsTemplate())
    .columnsGap(12)
    .rowsGap(12)
    .padding({ left: 16, right: 16, top: 8, bottom: 16 })
    .width('100%')
    .height('100%')
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring)
    .cachedCount(3)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .clip(false)
  }

  @Builder
  buildPrivacy() {
    PrivacyConsent({ model: this.privacyVM, windowWidth: this.windowWidth })
  }

  @Builder
  buildFullPrivacy() {
    PrivacyFullPage()
  }

  @Builder
  buildAbout() {
    AboutPage({
      onPermission: () => { this.showPermissionInfo(); },
      onPrivacy: () => { this.isShowingFullPrivacy = true; },
      onCode: () => {
        try {
          this.context.startAbility({
            action: 'ohos.want.action.viewData',
            uri: 'https://github.com/Zhuziexe/ZhuziCanvas'
          }).catch((err: BusinessError) => {
            console.error('打开浏览器失败:', err);
          });
        } catch (e) {
          console.error('打开浏览器异常:', e);
        }
      },
      windowWidth: this.windowWidth
    })
  }

  build() {
    HdsNavigation(this.pathStack) {
      Column()
        .width(0)
        .height(0)
        .bindSheet($$this.isShowingAbout, this.buildAbout, {
          detents: [SheetSize.LARGE], dragBar: false, preferType: SheetType.CENTER
        })
      Column() {
        if (!this.isShowingPrivacy) {
          if (this.projectCount === 0) {
            this.EmptyState()
          } else if (this.viewMode === 'grid') {
            this.ProjectGrid()
          } else {
            this.ProjectList()
          }
        }
      }
      .clip(false)
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.background_secondary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .border({
        width: this.isDragHover ? (this.draggingProjectId == '' ? 2 : 0) : 0,
        color: $r('app.color.brand'),
        radius: 12
      })
      .allowDrop(this.draggingProjectId == '' ? [uniformTypeDescriptor.UniformDataType.IMAGE] : [])
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
      .bindSheet($$this.isShowingPrivacy, this.buildPrivacy, {
        detents: [SheetSize.LARGE],
        dragBar: false,
        showClose: false,
        preferType: SheetType.CENTER,
        onWillDismiss: (action: DismissSheetAction) => {
          if (action.reason === DismissReason.PRESS_BACK) {
            this.privacyVM.onReject();
            return;
          }
        }
      })
    }
    .bindSheet($$this.isShowingFullPrivacy, this.buildFullPrivacy, {
      detents: [SheetSize.LARGE],
      dragBar: false,
      preferType: SheetType.CENTER
    })
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
    .titleBar({
      content: {
        title: {
          mainTitle: $r('app.string.EntryAbility_label')
        },
        menu: {
          value: [
            {
              content: {
                label: '新建项目',
                icon: $r('sys.symbol.plus'),
                action: () => this.createProject()
              }
            },
            {
              content: {
                label: this.sortBy === 'time' ? '按时间' : '按名称',
                icon: this.sortBy === 'time' ? $r('sys.symbol.clock') : $r('sys.symbol.textformat'),
                action: () => this.toggleSort(),
                type: TextStyleMode.NORMAL
              }
            },
            {
              content: {
                label: this.viewMode === 'list' ? '宫格视图' : '列表视图',
                icon: this.viewMode === 'list' ? $r('sys.symbol.grid') : $r('sys.symbol.list_bullet'),
                action: () => this.toggleView()
              }
            },
            {
              content: {
                label: '导入图片',
                icon: $r('sys.symbol.picture'),
                action: () => this.importPng()
              }
            },
            {
              content: {
                label: '关于',
                icon: $r('sys.symbol.info_circle'),
                action: () => {
                  this.isShowingAbout = true;
                }
              }
            }
          ]
        }
      },
      enableComponentSafeArea: true,
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR,
          blurEffectiveStartOffset: LengthMetrics.vp(0),
          blurEffectiveEndOffset: LengthMetrics.vp(28)
        },
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary')
            },
            menuStyle: {
              iconColor: $r('sys.color.font_primary'),
              textColor: $r('sys.color.font_primary')
            }
          }
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    })
    .titleMode(deviceInfo.deviceType == deviceInfo.DeviceTypes.TYPE_2IN1 ? HdsNavigationTitleMode.MINI : HdsNavigationTitleMode.FREE)
    .hideBackButton(true)
    .bindToScrollable([this.scroller,this.gridscroller])
    .backgroundColor($r('sys.color.background_secondary'))
  }
}