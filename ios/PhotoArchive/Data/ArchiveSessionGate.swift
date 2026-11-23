import Foundation
import Observation

/// Identity transitions close the write entrance synchronously, then drain commands
/// that already entered before an owner migration may move their committed data.
@MainActor @Observable final class ArchiveSessionGate {
  private(set) var generation = UUID()
  private(set) var ready = false
  @ObservationIgnored private var identity: String?
  @ObservationIgnored private var writers = 0
  @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

  @discardableResult func beginTransition(identity: String? = nil) -> UUID {
    self.identity = identity
    generation = UUID(); ready = false
    return generation
  }
  /// Resolve each retry from the captured signed-in identity, never from whichever
  /// owner happened to publish successfully before a failed transition.
  func resolveOwner(exists: @Sendable (String) async throws -> Bool) async throws -> String {
    let token = generation, identity = self.identity
    let target: String
    if let identity { target = try await exists(identity) ? identity : "guest" }
    else { target = "guest" }
    guard token == generation else { throw ArchiveStorageError.identityChanged }
    return target
  }
  /// A transition's own database write must also drain before a later identity
  /// lookup reads its target. Generation checks alone only suppress UI callbacks.
  func withTransitionWrite<Value>(token: UUID, _ work: @MainActor () async throws -> Value) async throws -> Value {
    guard token == generation, !ready else { throw ArchiveStorageError.identityChanged }
    writers += 1
    defer { leaveWrite() }
    return try await work()
  }
  @discardableResult func complete(_ token: UUID) -> Bool {
    guard token == generation else { return false }
    ready = true
    return true
  }
  func close() { ready = false }
  func enterWrite() throws -> UUID {
    guard ready else { throw ArchiveStorageError.identityChanged }
    writers += 1
    return generation
  }
  func leaveWrite() {
    writers -= 1
    if writers == 0 {
      let pending = waiters; waiters = []
      for continuation in pending { continuation.resume() }
    }
  }
  func waitForWrites() async {
    guard writers > 0 else { return }
    await withCheckedContinuation { waiters.append($0) }
  }
}
