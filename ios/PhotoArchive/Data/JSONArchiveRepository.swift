import Foundation

actor JSONArchiveRepository: ArchiveRepository {
  let directory: URL
  private var file: URL { directory.appendingPathComponent("archive-v1.json") }
  init(directory: URL) { self.directory = directory }
  func load() throws -> ArchiveSnapshot {
    guard FileManager.default.fileExists(atPath: file.path) else {
      try save(SampleLibrary.seed)
      return SampleLibrary.seed
    }
    let snapshot = try JSONDecoder().decode(ArchiveSnapshot.self, from: Data(contentsOf: file))
    try snapshot.validate(mediaIDs: Set(SampleLibrary().media.map(\.id)))
    return snapshot
  }
  func save(_ snapshot: ArchiveSnapshot) throws {
    try snapshot.validate(mediaIDs: Set(SampleLibrary().media.map(\.id)))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(snapshot).write(to: file, options: .atomic)
  }
  func reset() throws -> ArchiveSnapshot {
    // Preserve the previous bytes, including corrupt data, before an explicit reset.
    if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.copyItem(
        at: file, to: directory.appendingPathComponent("backup-\(UUID().uuidString).json"))
    }
    try save(SampleLibrary.seed)
    return SampleLibrary.seed
  }
}
