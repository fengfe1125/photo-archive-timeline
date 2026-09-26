# 公开样片来源

## App 图标

「暖日相册」为本项目在 Figma 绘制、经用户确认应用的图标。浅色与深色 1024×1024 母版分别来自 [浅色稿](https://www.figma.com/design/itrdhVrFzDHJeoGRWCw9Og?node-id=41-3) 和 [深色稿](https://www.figma.com/design/itrdhVrFzDHJeoGRWCw9Og?node-id=41-10)。资源位于 `AppIcon.appiconset`，不预裁圆角；由系统处理遮罩。深色外观随系统桌面图标设置选择。

## 样片

沿用已批准的 Figma 六张样片，来自 Lorem Picsum / Paul Jarvis / Unsplash（900×700）。界面中的日期和坐标全部虚构，不属于照片真实 EXIF。

| 资源 | 原始作品 |
| --- | --- |
| Sample10 湖边 | https://unsplash.com/photos/6J--NXulQCs |
| Sample11 河谷 | https://unsplash.com/photos/Cm7oKel-X2Q |
| Sample12 海风 | https://unsplash.com/photos/I_9ILwtsl_k |
| Sample13 远山 | https://unsplash.com/photos/3MtiSMdnoCo |
| Sample14 岸边 | https://unsplash.com/photos/IQ1kOQTJrOQ |
| Sample15 溪流 | https://unsplash.com/photos/NYDo21ssGao |

来源追溯保存在此文档，不嵌入用户分享的图片元数据。入库使用 ExifTool `-all=` 清除可移除元数据（包括 EXIF/GPS）；分享由 SwiftUI Image 重新导出图像，不附带档案坐标。

`sample-video` 复用 Sample15 作为类型说明图，没有视频文件或假播放按钮。未使用或上传任何私人照片。

字体使用 iOS 系统字体；SF Symbols 使用符号名称，不导入 Figma 字形图片。正式商店素材、图标及未来内容授权在发布前另行确认。
