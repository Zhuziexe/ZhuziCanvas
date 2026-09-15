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

        this.Section('一、这个应用不联网',
          '竹子画板不会连接到任何服务器。你的所有画作、项目、缩略图都保存在手机本地，' +
            '不会上传到任何地方。')

        this.Section('二、这个应用不收集任何数据',
          '没有账号系统、没有数据统计、没有崩溃上报、没有广告 SDK。' +
            '应用不会读取你的通讯录、位置、设备标识符或任何其他个人信息。')

        this.Section('三、这个应用是开源的',
          '竹子画板是一个开源项目，你可以到https://github.com/Zhuziexe/ZhuziCanvas下载并编译我们的源代码。')
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