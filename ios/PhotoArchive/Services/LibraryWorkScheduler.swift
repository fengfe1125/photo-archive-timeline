import Foundation
import Observation
import UIKit

/// A single foreground worker. Interaction invalidates the current lease before cancelling work.
@MainActor @Observable final class LibraryWorkScheduler {
  struct Conditions: Equatable, Sendable {
    var foreground = false
    var scrolling = false
    var detailPresented = false
    var paused = false
    var lowPower = false
    var batteryLevel: Float = -1
    var charging = false
    var thermalAllowed = true
    var permitsWork: Bool {
      foreground && !scrolling && !detailPresented && !paused && !lowPower && thermalAllowed && (charging || batteryLevel < 0 || batteryLevel > 0.2)
    }
  }
  private(set) var conditions = Conditions()
  private(set) var running = false
  @ObservationIgnored private var pending: Task<Void, Never>?
  @ObservationIgnored private var lease = UUID()
  @ObservationIgnored private let idleDelay: Duration
  @ObservationIgnored private var work: (@MainActor () async -> Bool)?
  @ObservationIgnored private var cancellation: (@MainActor () -> Void)?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  init(idleDelay: Duration = .seconds(2), observeSystem: Bool = true) {
    self.idleDelay = idleDelay
    if observeSystem {
      UIDevice.current.isBatteryMonitoringEnabled = true
      for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.readSystemConditions() }
        })
      }
      readSystemConditions()
    }
  }
  func configure(work: @escaping @MainActor () async -> Bool, cancel: @escaping @MainActor () -> Void) {
    self.work = work; self.cancellation = cancel
  }
  func update(_ change: (inout Conditions) -> Void) {
    let old = conditions; change(&conditions)
    guard old != conditions else { return }
    restart()
  }
  func userDidInteract() { restart() }
  func requestWork() { guard pending == nil else { return }; restart() }
  func invalidate() { lease = UUID(); pending?.cancel(); pending = nil; running = false; cancellation?() }
  private func readSystemConditions() {
    update {
      $0.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
      $0.thermalAllowed = ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair
      $0.batteryLevel = UIDevice.current.batteryLevel
      $0.charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }
  }
  private func restart() {
    invalidate()
    guard conditions.permitsWork, work != nil else { return }
    let token = lease, delay = idleDelay
    pending = Task { [weak self] in
      do { try await Task.sleep(for: delay) } catch { return }
      guard let self, self.lease == token, self.conditions.permitsWork else { return }
      self.running = true
      while !Task.isCancelled && self.lease == token && self.conditions.permitsWork {
        guard await self.work?() == true else { break }
        await Task.yield()
      }
      guard self.lease == token else { return }
      self.running = false; self.pending = nil
    }
  }
}
