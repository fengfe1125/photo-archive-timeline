# 摄影档案

[English](README.md) · [简体中文](README.zh-CN.md)

面向 iPhone 的本地优先照片档案，也提供网页时间线，可手动导入你选定的照片和视频。

- **整理成故事：** 从系统照片图库选片，在本机创建和编辑故事；断网也能使用。
- **按需同步：** 故事资料同步与原片上传是两个独立开关；原片上传默认关闭，需主动开启。
- **网页导入：** 只处理你在命令中指定目录里的媒体。

iPhone 的档案资料同步不会上传原片、预览图、PhotoKit 本地标识、本机路径或完整 EXIF。单独开启原片上传后，原片仍可能带有嵌入的 EXIF。

## 开始使用

- iPhone App：[配置与运行](ios/README.md)（iOS 18+）
- 网页导入：先在 ios/Local.xcconfig 中配置 Supabase URL 和 publishable key，再运行：

~~~sh
npm install
npm run cloud:import -- --dir /path/to/photos
~~~

导入前会向 Supabase 账号邮箱发送一次性验证码。构建网页静态文件：

~~~sh
npm run cloud:build
~~~

详见 [Supabase 配置说明](docs/ios-supabase-setup.md)。

技术栈：SwiftUI、PhotoKit、SwiftData、TypeScript、Supabase。
