# iPhone 实机与 Supabase 配置

## 环境

- iOS 18+、Swift 6、Xcode；SDK 固定 Supabase Swift 2.55.2，依赖锁文件随项目保存。
- 本地开发使用 Supabase CLI 与 Docker。请使用独立的开发项目，不要在其他应用的生产数据库上试验。
- 把 `ios/Local.example.xcconfig` 复制为 `ios/Local.xcconfig`，填入开发签名、独立 Bundle ID、项目 URL 和 **publishable key**。App 会拒绝其他类型的 key。
- `Local.xcconfig` 已忽略。服务端 secret/service_role key 只由 Edge Function 环境提供，不能加入 App、Git 或文档。

## 本地数据库与邮件

```sh
supabase start -x realtime,imgproxy,studio,postgres-meta,logflare,vector,supavisor,edge-runtime
supabase db reset --local --no-seed
supabase functions serve delete-account
```

`db reset --local` 仅用于可清空的独立测试库，不能用于生产库。CLI `status` 会输出本地密钥，不要粘贴到聊天或验收文档。

模拟器地址为 `http://127.0.0.1:54321`；本地邮件由 Mailpit 捕获，界面位于 `http://127.0.0.1:54324`。邮箱验证码模板在 `supabase/templates/otp.html`；本地收信成功不代表真实 SMTP 已验收。

```sh
SUPABASE_CLI=/path/to/supabase python3 supabase/tests/integration.py
supabase db advisors --local --type security --level warn --fail-on error
```

测试脚本拒绝非 localhost 后端，创建独立临时账号并清理，验证真实 Auth、RLS、RPC、并发提交、分页和账号删除。声明式 schema 保存在 `supabase/schemas/archive.sql`；部署使用已生成并经重建验证的 migrations。CLI 2.117 的 `db diff -f` 比较 migrations 与实际数据库，不自动以 schemas 文件为差分基线。

## 独立云端项目

1. 在用户的 Supabase 组织中新建摄影档案专用开发项目，Postgres 17 或更新版本。
2. 配置 Supabase CLI 的登录与 project ref；从已验证迁移部署（先 `supabase db push --dry-run`），不在其他应用的生产库试验。
3. 部署需要的 Edge Functions，包括账号删除和搜索相关函数。相关 handler 会通过 Auth getUser 在线验证 bearer token；配置中的 verify_jwt = false 不代表允许匿名调用，不能删除 handler 内的身份检查。
4. 开启 Email 登录，配置自定义 SMTP、已验证的发信域名和发件人。将 confirmation 与 magic link 两种邮件模板都设为验证码模板；与 App 一致使用 6 位验证码、60 秒重发间隔。
5. 在 App 本地配置中填写 HTTPS 项目 URL 和 publishable key，重新构建。
6. 验证用户自己的实际邮箱收信、错误与过期验证码、退出重登、两台设备同步及删除账号。SMTP 凭证不交给客户端。

## 运行 iOS 测试

```sh
xcodebuild -project ios/PhotoArchive.xcodeproj -scheme PhotoArchive \
  -destination 'platform=iOS Simulator,name=PhotoArchive QA' \
  -derivedDataPath /private/tmp/photoarchive-live-build \
  -parallel-testing-enabled NO test -only-testing:PhotoArchiveTests
```

`SupabaseContractTests` 只在 App 配置指向 `127.0.0.1` 时执行，否则标记跳过；它通过本地 Mailpit 验证真实验证码、Swift SDK 编解码、冲突解决和账号删除。必须先运行本地函数。此测试需要模拟器本地签名以访问 Keychain，不要使用 `CODE_SIGNING_ALLOWED=NO`。

原有 UI 测试使用 `-ui-testing`，仅访问公开样例及 `UITests` 档案。`LivePhotoUITests` 使用 `-live-ui-testing` 和独立 `LiveUITests` 档案，需要先向指定模拟器加入公开测试照片，并仅向测试 App 授予照片权限。`-reset-live-test-data` 只会清理 `LiveUITests`，不影响真实 `Live` 或旧 `Demo`。

## 数据与同步约定

- 正式档案：`Library/Application Support/PhotoArchive/Live/archive.store`，SwiftData、无 CloudKit。
- 首次开启同步：备份游客 JSON，再在一次 SwiftData 保存中归入账号并清空游客空间。账号与游客、不同账号彼此隔离。
- 网络 DTO 为 `WirePayload`，不编码 `MediaItem` 或原始修正对象。只有主动整理过的引用、故事、说明、明确覆盖值进入云端。
- 每条操作 UUID 的请求内容一旦发送即不可改变。服务端回执保障丢失响应后的重试；新编辑另排队。
- 服务端按账号锁定事务，变更序号、数据修改及回执同时提交。客户端按序号分页拉取，不以客户端时间作游标。
- 故事成员由事务一并保存；复合外键阻止跨账号关联。表只授予 authenticated 的受 RLS 限制读取，所有写入经过验证的 RPC。
- 冲突的双方版本存云端并缓存到本机；删除使用 tombstone。解决冲突也检查版本，遇到新的并发修改会重新提示。
- iCloud cloudIdentifier 只为整理过的照片按需查询。同一账号同一 cloudIdentifier 返回统一档案 ID。找不到映射时手动关联，不按文件名或日期猜测；没有 iCloud 标识的已同步引用需要在另一设备手动关联。
- 故事资料同步与原片上传使用独立设置。原片上传默认关闭，只处理已加入故事或明确修正的媒体；原片可能保留嵌入的 EXIF，不会自动备份整个系统图库。
- Supabase Storage 用于用户单独启用的原片与私有预览上传；同步由前台、编辑、网络恢复或手动重试触发，不使用 Realtime 或常驻后台服务。

## 验收边界

构建、签名、安装、真机操作、模拟器测试、本地后端和真实云端分别记录。模拟器不能验证真实 iCloud 下载、有限图库的全部行为或双真机关联；缺少 SMTP、设备连接或第二台手机时，不将对应项目标记完成。
