import { promptAction } from "@kit.ArkUI";

@CustomDialog
export struct RenameProjectDialog {
  controller?: CustomDialogController;
  currentName: string = '';
  existingNames: string[] = [];
  onConfirm: (newName: string) => void = () => {};

  @State name: string = '';

  aboutToAppear(): void {
    this.name = this.currentName;
  }

  build() {
    Column({ space: 16 }) {
      Text('重命名项目')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')

      TextInput({ placeholder: '项目名称', text: this.name })
        .onChange((v: string) => {
          this.name = v;
        })
        .defaultFocus(true)
        .onSubmit((enterKey,event)=>{
          const name = this.name.trim();
          if (!name) {
            promptAction.openToast({ message: '请输入项目名称' }).catch(()=>{});
            return;
          }
          if (name === this.currentName) {
            this.controller?.close();
            return;
          }
          const others = this.existingNames.filter((n: string) => n !== this.currentName);
          if (others.includes(name)) {
            promptAction.openToast({ message: '项目名称已存在' }).catch(()=>{});
            return;
          }
          this.onConfirm(name);
          this.controller?.close();
        })

      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontColor($r('app.color.brand'))
          .onClick(() => this.controller?.close())

        Button('确定')
          .layoutWeight(1)
          .buttonStyle(ButtonStyleMode.EMPHASIZED)
          .backgroundColor($r('app.color.brand'))
          .onClick(() => {
            const name = this.name.trim();
            if (!name) {
              promptAction.openToast({ message: '请输入项目名称' }).catch(()=>{});
              return;
            }
            if (name === this.currentName) {
              this.controller?.close();
              return;
            }
            const others = this.existingNames.filter((n: string) => n !== this.currentName);
            if (others.includes(name)) {
              promptAction.openToast({ message: '项目名称已存在' }).catch(()=>{});
              return;
            }
            this.onConfirm(name);
            this.controller?.close();
          })
      }
      .width('100%')
    }
    .padding(24)
    .width('100%')
  }
}