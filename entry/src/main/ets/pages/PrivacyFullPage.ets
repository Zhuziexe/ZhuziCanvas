@Component
export struct PrivacyFullPage {
  build() {
    Scroll() {
      Column({ space: 16 }) {
        Image($r('app.media.ic_security_shield'))
          .width(40)
          .height(40)

        Text('隐私说明')
          .fontSize(24)
          .fontWeight(FontWeight.Medium)
          .margin({ top: 24, bottom: 8 })

        Text('更新日期：2026年9月15日')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))

        this.Section('一、引言',
          '竹子画板（以下简称"本应用"）是一个完全离线的绘图工具。本说明用于告知您本应用如何处理（以及不处理）您的信息。\n' +
            '本应用不联网、不收集、不上传。')

        this.Section('二、我们不收集任何信息',
          '本应用没有账号系统、没有数据统计、没有崩溃上报、没有广告 SDK，也不会读取设备标识符。\n' +
            '我们无法看到您画了什么，也无从得知您如何使用本应用。')

        this.Section('三、您的数据存放在哪里',
          '所有画作、项目、缩略图都保存在本应用的沙箱目录中。\n' +
            '卸载本应用会一并删除所有数据，数据不会离开您的设备。')

        this.Section('四、系统权限说明',
          '本应用不申请任何需要您手动授权的系统权限。以下为已声明的权限：\n' +
            'ohos.permission.PREPARE_APP_TERMINATE（预关闭动作）\n' +
            '用途：在电脑端关闭应用时弹出"是否保存"确认提示。该权限由系统自动授予，不涉及任何数据收集。')

        this.Section('五、图片的读取与导出',
          '导入图片、叠加图片、保存到相册均通过系统提供的安全控件完成。\n' +
            '基于安全访问机制，本应用只能访问您选择的图片，无法读取相册中的其他内容；保存到相册时同样由系统代为写入，本应用不会获得相册的完整访问权限。')

        this.Section('六、第三方服务',
          '本应用不集成任何第三方 SDK，不与任何第三方共享数据。\n' +
            '"分享"功能调用系统分享面板，是否分享、分享给谁完全由您决定。')

        this.Section('七、儿童隐私',
          '本应用不收集任何用户信息，因此也不涉及儿童个人信息的收集。')

        this.Section('八、本说明的更新',
          '如果本说明发生变更，我们会在应用内以显著方式提示。继续使用即表示您接受更新后的说明。')

        this.Section('九、联系我们',
          '本项目为开源项目，如有疑问或建议，欢迎在代码仓库提交 Issue。\n' +
            'https://github.com/Zhuziexe/ZhuziCanvas')
      }
      .padding(24)
      .width('100%')
    }
    .contentStartOffset(12)
    .contentEndOffset(12)
    .width('100%')
    .height('100%')
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  Section(title: string, content: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      Text(content)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
        .lineHeight(22)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}