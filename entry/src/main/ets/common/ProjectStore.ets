import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';

export interface DrawProject {
  id: string;
  name: string;
  width: number;
  height: number;
  createdAt: number;
  updatedAt: number;
}

const META_FILE = 'bamboo_projects.json';

export class ProjectStore {
  private static context: common.UIAbilityContext | null = null;

  static init(context: common.UIAbilityContext): void {
    ProjectStore.context = context;
  }

  private static metaPath(): string {
    return `${ProjectStore.context!.filesDir}/${META_FILE}`;
  }

  static getImagePath(id: string): string {
    return `${ProjectStore.context!.filesDir}/${id}.png`;
  }

  static getThumbPath(id: string): string {
    return `${ProjectStore.context!.filesDir}/${id}_thumb.png`;
  }

  static async list(): Promise<DrawProject[]> {
    try {
      const path = ProjectStore.metaPath();
      if (!fileIo.accessSync(path)) {
        return [];
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const stat = fileIo.statSync(file.fd);
      const buffer = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buffer);
      fileIo.closeSync(file);
      const decoder = new util.TextDecoder('utf-8');
      const text = decoder.decodeToString(new Uint8Array(buffer));
      return JSON.parse(text) as DrawProject[];
    } catch (e) {
      console.error('读取项目列表失败:', e);
      return [];
    }
  }

  static async save(projects: DrawProject[]): Promise<void> {
    try {
      const path = ProjectStore.metaPath();
      const file = fileIo.openSync(path,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
      const encoder = new util.TextEncoder();
      const bytes = encoder.encodeInto(JSON.stringify(projects));
      fileIo.writeSync(file.fd, bytes.buffer);
      fileIo.closeSync(file);
    } catch (e) {
      console.error('保存项目列表失败:', e);
    }
  }

  static async upsert(project: DrawProject): Promise<void> {
    const arr = await ProjectStore.list();
    const idx = arr.findIndex(p => p.id === project.id);
    if (idx >= 0) {
      arr[idx] = project;
    } else {
      arr.push(project);
    }
    await ProjectStore.save(arr);
  }

  static async remove(id: string): Promise<void> {
    const arr = await ProjectStore.list();
    const filtered = arr.filter(p => p.id !== id);
    await ProjectStore.save(filtered);
    try {
      fileIo.unlinkSync(ProjectStore.getImagePath(id));
    } catch (e) {
    }
    try {
      fileIo.unlinkSync(ProjectStore.getThumbPath(id));
    } catch (e) {
    }
  }
}