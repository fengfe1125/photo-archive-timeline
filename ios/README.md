# 摄影档案 iOS

支持 iOS 18+ 的 iPhone App。SwiftUI 管理导航与表单，图库、搜索结果和故事选片共用 UICollectionView；PhotoKit 读取系统照片，SwiftData 在本机保存整理档案，不配置云端也可离线使用。

## 运行

在 Xcode 中打开 PhotoArchive.xcodeproj，选择 PhotoArchive Scheme。将 Local.example.xcconfig 复制为 Local.xcconfig，填写自己的 Bundle ID、签名 Team 和 Supabase publishable 配置。Local.xcconfig 不会提交到 Git。

## 数据与隐私

正式档案使用 SwiftData，关闭 CloudKit。登录不会自动开始同步：档案资料同步和原片上传分别控制，原片上传默认关闭，只处理已加入故事或明确修正的媒体。原片可能包含嵌入的 EXIF。

PhotoKit 本地标识、本机路径和完整 EXIF 不进入档案资料同步。同步只发送整理过的故事、关联与明确修正。原片上传是独立功能，不会扫描并备份整个图库。地图读取照片中的位置，不请求设备实时定位；分享会生成去除私人元数据的临时 JPEG。

演示模式、UI 测试档案和真实 PhotoKit 测试档案彼此隔离。真实照片 UI 测试使用 -live-ui-testing；只有额外传入 -reset-live-test-data 才会清理该测试档案。

## 搜索与验证

搜索测试位于 Tests，UI 测试位于 UITests。SupabaseContractTests 需要本地 Supabase 与 Mailpit；条件不满足时会跳过，不代表云端联调通过。真实 PhotoKit UI 测试需先向独立模拟器导入公开测试图片并授予照片权限。

真实照片详情支持本机及云端视频；演示素材中的视频条目只是占位。资源出处和动效说明见 [ASSETS.md](ASSETS.md) 与 [MOTION.md](MOTION.md)。

## 图库与后台任务

图库每页 120 条，按有效日期降序、稳定 ID 升序读取，未知日期置后。原生单元复用，缩略图按像素尺寸与资源版本缓存，共享取消与预热能力。详情使用当前照片附近的窗口，继续翻页会取得下一页；返回保持图库滚动锚点。地图在独立 actor 中更新发生变化的区域。

首屏准备与完整档案准备分开：已有索引先返回首 120 条，完整兼容模型在后台加载，完成后开放整理、同步与搜索。数据库验证、编码、迁移和查询不在主线程执行。同步进度、游标及故事编辑不使图库查询和搜索索引失效。

本地识别在前台空闲 2 秒后串行运行；滚动、看大图、后台、低电量、过热或手动暂停时停止安排后续任务。自动识别不下载 iCloud 照片，等待下载的资源需手动处理。联网城市查询、云端 AI、原片上传分别控制。搜索模型版本变更与旧云端判断失效在同一数据库事务提交。

## 数据升级与恢复

旧 `archive.store` 只读打开，所有 owner 先导出一致逻辑备份，再导入新目录并重新打开逐项核对；最后原子写入 `archive-v2-active.json` 切换。旧库及 `migration-backups` 不自动删除。损坏、空间不足或切换前中断均不能用空档案覆盖源数据。

新版媒体、故事元数据、故事照片顺序、修正、映射、版本、同步操作及冲突分别存储。搜索索引按照片逐条存储，独立迁移所有旧账号目录，保留搜索相册、排除项和未决付费请求凭据。照片不可访问只改变可访问状态，保留整理引用。

升级后已有编辑时，必须通过 `LiveArchiveRepository.exportCompatibilitySnapshot()` 导出并核对当前所有 owner 的最新档案，同时备份当前 Search 目录及应用偏好，才能安排回退；不能直接恢复升级前备份。兼容导出本身不会切换数据库或降级 App。备份可能包含私人整理信息，应保存在受保护的本机位置。

## 可复现测试

新建独立 iPhone 模拟器并导入 `Resources/Assets.xcassets/Sample10.imageset/Sample10.jpg` 等公开素材，再执行：

```sh
xcodebuild -project ios/PhotoArchive.xcodeproj -scheme PhotoArchive \
  -destination 'platform=iOS Simulator,id=<独立模拟器 UDID>' \
  -parallel-testing-enabled NO test
```

`-ui-testing -paging-test-library` 只在 DEBUG 启用 1,000 张稳定 ID 的测试图库，使用独立 `UITestsPaging` 目录；分页 UI 测试覆盖跨页选择、详情继续翻页、返回位置、故事追加和重启。大规模 SwiftData 查询测试覆盖 1 万及 5 万条合成记录。模拟器与合成记录结果不能替代真实图库的帧率、内存和冷启动验收。

本次构建、自动测试、迁移验证和仍待真机验收的边界见 [重构验收记录](REBUILD-ACCEPTANCE.md)。
