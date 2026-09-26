import Foundation
import Observation
import Supabase

struct ArchiveServiceError: LocalizedError, Sendable {
  var message: String
  var errorDescription: String? { message }
}

@MainActor @Observable final class SupabaseAccount: AccountService {
  private(set) var userID: String?
  private(set) var email: String?
  let client: SupabaseClient?
  @ObservationIgnored private var observation: Task<Void, Never>?
  @ObservationIgnored var onIdentityChange: (() -> Void)?
  init() {
    let endpoint = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
    let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String ?? ""
    if let url = URL(string: endpoint), ["https", "http"].contains(url.scheme ?? ""), key.hasPrefix("sb_publishable_"), !key.contains("$(") {
      client = SupabaseClient(supabaseURL: url, supabaseKey: key,
        options: .init(auth: .init(storage: KeychainLocalStorage(service: "\(Bundle.main.bundleIdentifier ?? "PhotoArchive").supabase.\(url.host ?? "local")"), emitLocalSessionAsInitialSession: true)))
    } else { client = nil }
  }
  func observe() {
    guard observation == nil, let client else { return }
    observation = Task { [weak self] in
      for await (_, session) in client.auth.authStateChanges {
        guard !Task.isCancelled, let self else { return }
        let id = session?.user.id.uuidString.lowercased()
        let changed = id != self.userID
        self.userID = id; self.email = session?.user.email
        if changed { self.onIdentityChange?() }
      }
    }
  }
  func signIn(email: String) async throws {
    guard let client else { throw ArchiveServiceError(message: "尚未配置云端连接。你可以继续在本机整理。") }
    try await client.auth.signInWithOTP(email: email.trimmingCharacters(in: .whitespacesAndNewlines))
  }
  func verify(email: String, token: String) async throws {
    guard let client else { throw ArchiveError.notConnected }
    let response = try await client.auth.verifyOTP(email: email.trimmingCharacters(in: .whitespacesAndNewlines), token: token.trimmingCharacters(in: .whitespacesAndNewlines), type: .email)
    // Verify that Keychain persistence succeeded before presenting a signed-in account.
    let session = try await client.auth.session
    guard session.user.id == response.user.id else { throw ArchiveServiceError(message: "登录会话保存失败，请重试。") }
    userID = session.user.id.uuidString.lowercased(); self.email = session.user.email
    onIdentityChange?()
  }
  func signOut() async throws {
    guard let client else { throw ArchiveError.notConnected }
    try await client.auth.signOut(scope: .local)
    userID = nil; email = nil; onIdentityChange?()
  }
  func deleteAccount() async throws {
    guard let client else { throw ArchiveError.notConnected }
    try await client.functions.invoke("delete-account")
    try await client.auth.signOut(scope: .local)
    userID = nil; email = nil; onIdentityChange?()
  }
}
struct SupabaseArchiveTransport: ArchiveTransport {
  let client: SupabaseClient
  private struct PullParameters: Encodable { let p_after: Int64 }
  private struct PushParameters: Encodable { let p_operation: PushOperation }
  func pull(after cursor: Int64) async throws -> PullPage {
    try await client.rpc("archive_pull", params: PullParameters(p_after: cursor)).execute().value
  }
  func push(_ operation: PushOperation) async throws -> PushResult {
    try await client.rpc("archive_push", params: PushParameters(p_operation: operation)).execute().value
  }
}
