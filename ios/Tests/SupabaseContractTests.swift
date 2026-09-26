import XCTest
@testable import PhotoArchive

@MainActor final class SupabaseContractTests: XCTestCase {
  func testRealEmailOTPAndSwiftTransportConflictRoundTrip() async throws {
    let endpoint = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String ?? ""
    guard URL(string: endpoint)?.host == "127.0.0.1" else { throw XCTSkip("Requires the isolated local Supabase stack") }
    let account = SupabaseAccount()
    let email = "swift-\(UUID().uuidString.lowercased())@example.test"
    try await account.signIn(email: email)
    let code = try await readLocalCode(for: email)
    do { try await account.verify(email: email, token: "000000"); XCTFail("Invalid OTP must fail") } catch {}
    try await account.verify(email: email, token: code)
    XCTAssertNotNil(account.userID)
    let restored = SupabaseAccount()
    let restoredClient = try XCTUnwrap(restored.client)
    let restoredSession = try await restoredClient.auth.session
    XCTAssertEqual(restoredSession.user.id.uuidString.lowercased(), account.userID, "A new client must restore the Keychain session")
    let client = try XCTUnwrap(account.client)
    let transport = SupabaseArchiveTransport(client: client)
    let mediaID = UUID().uuidString.lowercased(), storyID = UUID().uuidString.lowercased()
    let media = SyncOperation(entity: "media", entityID: mediaID, baseVersion: 0, payload: WirePayload(kind: "photo"))
    let uploaded = try await transport.push(media.wire)
    XCTAssertEqual(uploaded.status, "accepted")
    let duplicate = try await transport.push(media.wire)
    XCTAssertEqual(duplicate.record, uploaded.record)
    let story = Story(id: storyID, title: "Swift client", mediaIDs: [mediaID], coverID: mediaID)
    let created = try await transport.push(SyncOperation(entity: "story", entityID: storyID, baseVersion: 0, payload: .story(story)).wire)
    XCTAssertEqual(created.record.version, 1)
    var edit = story; edit.title = "Remote edit"
    _ = try await transport.push(SyncOperation(entity: "story", entityID: storyID, baseVersion: 1, payload: .story(edit)).wire)
    edit.title = "Offline edit"
    let collision = try await transport.push(SyncOperation(entity: "story", entityID: storyID, baseVersion: 1, payload: .story(edit)).wire)
    let conflict = try XCTUnwrap(collision.conflict)
    XCTAssertEqual(conflict.local.payload.title, "Offline edit")
    XCTAssertEqual(conflict.remote.payload.title, "Remote edit")
    var resolving = SyncOperation(entity: "story", entityID: storyID, baseVersion: 2, payload: conflict.local.payload)
    resolving.resolving = conflict.id
    let result = try await transport.push(resolving.wire)
    XCTAssertEqual(result.record.version, 3)
    let page = try await transport.pull(after: 0)
    XCTAssertEqual(page.changes.count, 4)
    XCTAssertTrue(page.conflicts.isEmpty)
    try await account.deleteAccount()
    XCTAssertNil(account.userID)
  }
  private func readLocalCode(for email: String) async throws -> String {
    for _ in 0..<30 {
      let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:54324/api/v1/messages")!)
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
      let messages = root?["messages"] as? [[String: Any]] ?? []
      if let message = messages.first(where: { message in
        (message["To"] as? [[String: Any]] ?? []).contains { $0["Address"] as? String == email }
      }), let id = message["ID"] as? String {
        let (detailData, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:54324/api/v1/message/\(id)")!)
        let detail = try JSONSerialization.jsonObject(with: detailData) as? [String: Any]
        let text = (detail?["Text"] as? String ?? "") + (detail?["HTML"] as? String ?? "")
        if let range = text.range(of: #"\b\d{6}\b"#, options: .regularExpression) { return String(text[range]) }
      }
      try await Task.sleep(for: .milliseconds(300))
    }
    throw ArchiveServiceError(message: "Local Mailpit did not receive a six-digit code")
  }
}
