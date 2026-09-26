# 摄影档案 iOS

SwiftUI iPhone App，支持 iOS 18+。通过 PhotoKit 读取系统照片图库，以 SwiftData 在本机保存整理档案；不配置云端也可离线使用。

## 运行

在 Xcode 中打开 PhotoArchive.xcodeproj，选择 PhotoArchive Scheme。将 Local.example.xcconfig 复制为 Local.xcconfig，填写自己的 Bundle ID、签名 Team 和 Supabase publishable 配置。Local.xcconfig 不会提交到 Git。

## 数据与隐私

正式档案使用 SwiftData，关闭 CloudKit。登录不会自动开始同步：档案资料同步和原片上传分别控制，原片上传默认关闭，只处理已加入故事或明确修正的媒体。原片可能包含嵌入的 EXIF。

PhotoKit 本地标识、本机路径和完整 EXIF 不进入档案资料同步。同步只发送整理过的故事、关联与明确修正。原片上传是独立功能，不会扫描并备份整个图库。地图读取照片中的位置，不请求设备实时定位；分享会生成去除私人元数据的临时 JPEG。

演示模式、UI 测试档案和真实 PhotoKit 测试档案彼此隔离。真实照片 UI 测试使用 -live-ui-testing；只有额外传入 -reset-live-test-data 才会清理该测试档案。

## 搜索与验证

搜索测试位于 Tests，UI 测试位于 UITests。SupabaseContractTests 需要本地 Supabase 与 Mailpit；条件不满足时会跳过，不代表云端联调通过。真实 PhotoKit UI 测试需先向独立模拟器导入公开测试图片并授予照片权限。

详情页的视频播放尚未接入。资源出处和动效说明见 [ASSETS.md](ASSETS.md) 与 [MOTION.md](MOTION.md)。
