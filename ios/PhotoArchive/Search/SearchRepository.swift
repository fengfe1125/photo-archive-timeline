import Foundation

/// One atomic file per photo: analysis never rewrites the archive or a whole-library JSON blob.
struct SearchRepository: Sendable {
  let directory: URL
  init(base: URL, owner: String) throws {
    directory = base.appendingPathComponent(SearchDigest.of(Data(owner.utf8)), isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues(); values.isExcludedFromBackup = true
    var path = directory; try path.setResourceValues(values)
  }
  private func path(_ id: String) -> URL { directory.appendingPathComponent(SearchDigest.of(Data(id.utf8)) + ".json") }
  func read<T: Decodable>(_ type: T.Type, id: String) throws -> T? {
    let url = path(id); guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  func write<T: Encodable>(_ value: T, id: String) throws {
    try JSONEncoder.sorted.encode(value).write(to: path(id), options: [.atomic, .completeFileProtection])
  }
}
