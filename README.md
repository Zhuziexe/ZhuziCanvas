# 竹子画板 (ZhuziCanvas)

> 一个只属于你自己的开源画板。

竹子画板是一个完全离线的开源绘图工具，适用于 HarmonyOS NEXT。所有画作、项目、缩略图都保存在设备本地，不会上传到任何服务器。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
## 特性

- **无广告**：没有开屏、插屏、激励视频，代码中不存在任何广告 SDK。
- **无账号**：没有登录、注册、手机号绑定，打开就能画。
- **不联网**：未申请 `ohos.permission.INTERNET` 权限，应用在代码层面不具备联网能力。
- **无水印**：导出和分享的图片不带任何水印或标识。
- **完全离线**：所有数据存放在应用沙箱，卸载即删除，数据不离开设备。
- **开源可查**：每一行代码都公开，任何人都可以审查、编译、修改。

## 功能

- 画笔、橡皮、填充、取色、拖动
- 撤销 / 重做（最多 5 步）
- 画布尺寸调整（拉伸、等比缩放、居中裁切、左上角对齐）
- 叠加图片到画板
- 添加文字
- 保存到沙箱、保存到相册、系统分享
- 支持拖拽导入图片
- 快捷键（2in1 设备）：B/E/F/I/H 切换工具，Ctrl+Z/Y 撤销重做，Ctrl+/-/0 缩放

## 构建与运行

### 环境要求

- DevEco Studio 5.0 或更高版本
- HarmonyOS SDK API 23 或更高
- 一台 HarmonyOS NEXT 设备或模拟器

### 步骤

1. 克隆仓库：
    ```bash
    git clone https://github.com/Zhuziexe/ZhuziCanvas.git
    ```
2. 使用 DevEco Studio 打开项目。
3. 配置签名（可使用自动签名）。
4. 连接设备或启动模拟器，点击运行。 

## 开源协议
本项目采用 MIT License 开源。

## 联系
- 项目地址：https://github.com/Zhuziexe/ZhuziCanvas
- 问题反馈：请提交 Issue