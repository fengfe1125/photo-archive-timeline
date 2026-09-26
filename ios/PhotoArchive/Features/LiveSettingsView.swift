import SwiftUI
import Photos
import PhotosUI

struct PhotoPermissionSection: View {
  let live: LiveArchiveController
  @State private var limited = false
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(live.photos.permissionLabel, systemImage: "photo.on.rectangle")
      if live.photos.authorization == .notDetermined {
        Text("选择允许访问的照片。无需登录，也能在本机整理；不会修改系统照片。").font(.footnote)
        Button("选择照片访问范围") { Task { await live.authorize() } }.buttonStyle(.borderedProminent)
      } else if live.photos.authorization == .limited {
        Button("管理可访问的照片") { limited = true }
      } else if live.photos.authorization == .denied || live.photos.authorization == .restricted {
        Text("故事和档案仍然保留。允许访问后即可继续查看照片。").font(.footnote)
        Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
      }
      if live.photos.scanning { ProgressView("正在读取 \(live.photos.scanned) 张照片") }
      if let error = live.error { Text(error).font(.footnote).foregroundStyle(.red) }
    }
    .sheet(isPresented: $limited, onDismiss: { Task { await live.refreshPhotos() } }) { NavigationStack { LimitedPhotoAccess().toolbar { Button("完成") { limited = false } } } }
  }
}
struct LimitedPhotoAccess: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> UIViewController { Controller() }
  func updateUIViewController(_ controller: UIViewController, context: Context) {}
  final class Controller: UIViewController {
    private var shown = false
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      guard !shown else { return }; shown = true
      PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
    }
  }
}

struct LiveSettingsView: View {
  let live: LiveArchiveController
  @State private var email = ""
  @State private var token = ""
  @State private var codeSent = false
  @State private var busy = false
  @State private var resendAt = Date.distantPast
  @State private var enable = false
  @State private var enableMedia = false
  @State private var signOut = false
  @State private var delete = false
  var body: some View {
    Form {
      Section("照片访问") { PhotoPermissionSection(live: live) }
      Section("账号") {
        if let accountEmail = live.account.email {
          LabeledContent("已登录", value: accountEmail)
          Button("退出登录") { signOut = true }.disabled(busy)
        } else {
          TextField("邮箱", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
            .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(codeSent)
          if codeSent {
            TextField("邮箱验证码", text: $token).keyboardType(.numberPad).textContentType(.oneTimeCode)
            Button("验证并登录") {
              perform { try await live.account.verify(email: email, token: token); token = ""; codeSent = false }
            }.disabled(token.isEmpty || busy)
            Button("换一个邮箱") { codeSent = false; token = "" }.disabled(busy)
          }
          TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(resendAt.timeIntervalSince(context.date))))
            Button(remaining > 0 ? "\(remaining) 秒后可重发" : (codeSent ? "重新发送验证码" : "发送验证码")) {
              perform {
                try await live.account.signIn(email: email)
                codeSent = true; resendAt = .now.addingTimeInterval(60)
              }
            }.disabled(busy || remaining > 0 || !email.contains("@") || live.account.client == nil)
          }
          if live.account.client == nil { Text("云端连接尚未配置，本机功能仍可使用。").foregroundStyle(.secondary) }
          if codeSent { Text("验证码错误或过期时，可重新发送。首次验证会创建账号。").font(.footnote) }
        }
        if busy { ProgressView("处理中") }
      }
      Section("整理信息同步") {
        Text(live.status).accessibilityIdentifier("live-sync-status")
        LabeledContent("待同步操作", value: String(live.document.outbox.count))
        if let date = live.document.lastSync { LabeledContent("最近同步") { Text(date, style: .relative) } }
        if live.document.syncEnabled {
          Button("立即同步／重试") { live.requestSync() }.disabled(live.syncing)
          Button("暂停同步") { live.disableSync() }
        } else {
          Button("开启同步") { enable = true }.disabled(live.account.userID == nil || busy)
        }
        if live.syncing { ProgressView("正在同步整理信息") }
        if !live.document.conflicts.isEmpty {
          NavigationLink("处理 \(live.document.conflicts.count) 项冲突") { ConflictListView(live: live) }
        }
      }
      Section("原片同步") {
        Text("单独控制。只上传已加入故事或明确修正的原片，不扫描上传整个图库。")
          .font(.footnote)
        if live.mediaUploadEnabled {
          Button("立即上传／重试") { live.requestSync() }.disabled(live.syncing)
          Button("暂停原片上传") { live.disableMediaUpload() }
        } else {
          Button("开启原片同步") { enableMedia = true }
            .disabled(!live.document.syncEnabled || live.account.userID == nil)
        }
        if !live.mediaUploadProgress.isEmpty { ProgressView(live.mediaUploadProgress) }
        if !live.mediaUploadErrors.isEmpty {
          Text("\(live.mediaUploadErrors.count) 个原片尚未上传")
          ForEach(live.mediaUploadErrors.keys.sorted(), id: \.self) { id in
            Text("\(live.item(id)?.title ?? "照片")：\(live.mediaUploadErrors[id] ?? "")")
              .font(.footnote)
          }
        }
        Text("当前 Free 方案单文件上限 50 MB。超限文件保留在设备，云端会显示原片尚未上传。")
          .font(.footnote)
      }
      Section("隐私") {
        Text("整理信息同步、原片同步和云端 AI 分别开启。原片同步默认关闭；开启后原片包含其嵌入的 EXIF 信息。")
        Text("未上传的原片不属于云端备份。系统照片仍留在设备；分享会生成去除位置等元数据的副本。")
      }
      if live.account.userID != nil {
        Section { Button("删除账号与云端档案", role: .destructive) { delete = true }.disabled(busy || live.syncing) }
      }
    }.navigationTitle("设置")
      .confirmationDialog("将本机整理归入这个账号并开启同步？", isPresented: $enable, titleVisibility: .visible) {
        Button("确认开启同步") { Task { await live.enableSync() } }
      } message: { Text("上传包括你主动填写的日期、地点和描述。原片由下方独立开关控制，默认关闭。迁移前会保留本地备份。") }
      .confirmationDialog("把已整理照片与视频的原片上传到私人云端？", isPresented: $enableMedia, titleVisibility: .visible) {
        Button("确认开启原片同步") { live.enableMediaUpload() }
      } message: { Text("只上传加入故事或有明确修正的媒体。原片可能包含 EXIF；超过 50 MB 的文件会留在设备。") }
      .confirmationDialog("退出后切回独立的本地档案。此账号未同步的修改会保留，重新登录可继续。", isPresented: $signOut, titleVisibility: .visible) {
        Button("退出登录") { Task { await live.signOut() } }
      }
      .confirmationDialog("永久删除账号与云端整理？", isPresented: $delete, titleVisibility: .visible) {
        Button("确认删除账号", role: .destructive) { Task { await live.deleteAccount() } }
      } message: { Text("同时删除该账号的云端原片、预览和本机档案缓存。系统照片不会删除；历史导出不受影响。") }
  }
  private func perform(_ work: @escaping @MainActor () async throws -> Void) {
    busy = true; live.error = nil
    Task {
      defer { busy = false }
      do { try await work() } catch { live.error = error.localizedDescription }
    }
  }
}

struct ConflictListView: View {
  let live: LiveArchiveController
  var body: some View {
    List {
      if live.document.conflicts.isEmpty { Text("没有待处理的冲突") }
      ForEach(live.document.conflicts) { conflict in
        Section {
          ConflictVersionView(title: "本机修改", record: localVersion(conflict))
          ConflictVersionView(title: "云端版本", record: conflict.remote)
          Button("保留本机版") { live.resolve(conflict, keepLocal: true) }
          Button("保留云端版") { live.resolve(conflict, keepLocal: false) }
        }.disabled(live.syncing || live.document.outbox.contains { $0.resolving == conflict.id })
      }
      if let error = live.error { Text(error).foregroundStyle(.red) }
    }.navigationTitle("同步冲突")
  }
  private func localVersion(_ conflict: SyncConflict) -> SyncRecord {
    var record = conflict.local
    if let pending = live.document.outbox.last(where: { $0.key == conflict.key && $0.resolving == nil }) {
      record.payload = pending.payload; record.deleted = pending.deleted
    }
    return record
  }
}
struct ConflictVersionView: View {
  let title: String
  let record: SyncRecord
  @Environment(ArchiveStore.self) private var store
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.headline)
      if record.deleted { Text("已删除／恢复原始信息") }
      else if record.entity == "story" {
        Text(record.payload.title ?? "故事")
        Text(record.payload.description ?? "")
        Text("照片顺序：" + (record.payload.mediaIDs ?? []).map { store.item($0)?.title ?? "未关联照片" }.joined(separator: "、"))
          .font(.caption)
        Text("封面：\(record.payload.coverID.flatMap { store.item($0)?.title } ?? "未关联照片")").font(.caption)
      } else {
        Text(record.payload.description ?? "")
        Text("日期：\(record.payload.day?.label ?? (record.payload.dayMode == .clear ? "清空" : "使用原始值"))")
        Text("地点：\(record.payload.place?.name ?? (record.payload.placeMode == .clear ? "清空" : "使用原始值"))")
      }
    }
  }
}
