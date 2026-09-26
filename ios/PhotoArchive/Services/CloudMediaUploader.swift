import Foundation
import Photos
import CryptoKit
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
import Supabase
import UIKit

struct CloudAssetRow: Decodable, Sendable {
  let mediaID: String
  let objectPath: String
  let previewPath: String?
  let status: String
  let duplicate: Bool
}
struct CloudAssetLookup: Decodable, Sendable {
  let mediaID: String
  let objectPath: String
  let previewPath: String?
  let status: String
  enum CodingKeys: String, CodingKey { case mediaID = "media_id", objectPath = "object_path", previewPath = "preview_path", status }
}
struct CloudTimeSource: Decodable, Sendable { let value: String }
struct CloudAssetMetadata: Decodable, Sendable {
  let mediaID: String
  let displayName: String
  let capturedAt: String?
  let latitude: Double?
  let longitude: Double?
  let timeSources: [CloudTimeSource]
  let status: String
  enum CodingKeys: String, CodingKey {
    case mediaID = "media_id", displayName = "display_name", capturedAt = "captured_at"
    case latitude, longitude, timeSources = "time_sources", status
  }
}
struct CloudPrepareParameters: Encodable, Sendable {
  let p_media_id: String
  let p_sha256: String
  let p_bytes: Int64
  let p_mime_type: String
  let p_display_name: String
  let p_captured_at: String?
  let p_latitude: Double?
  let p_longitude: Double?
}
struct CloudCompleteParameters: Encodable, Sendable { let p_media_id: String; let p_preview: Bool }

enum CloudMediaError: LocalizedError {
  case missingAsset, oversized, invalidResponse, checksum, uploadFailed(Int)
  var errorDescription: String? {
    switch self {
    case .missingAsset: "这张照片在本机不可读取，云端原片尚未上传。"
    case .oversized: "原片超过当前云端 50 MB 上限，已留在设备。"
    case .invalidResponse: "云端上传响应无效，请重试。"
    case .checksum: "云端原片校验失败，已保留本机原片。"
    case .uploadFailed(let code): "原片上传失败（\(code)），稍后可重试。"
    }
  }
}

@MainActor struct CloudMediaUploader {
  let client: SupabaseClient
  let accountID: String
  private let chunkSize = 6 * 1024 * 1024

  func upload(item: MediaItem, asset: PHAsset) async throws -> String {
    guard let resource = chosenResource(for: asset) else { throw CloudMediaError.missingAsset }
    let file = URL.temporaryDirectory.appendingPathComponent("archive-original-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      PHAssetResourceManager.default().writeData(for: resource, toFile: file, options: options) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
    let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 ?? 0
    guard size > 0 else { throw CloudMediaError.missingAsset }
    guard size <= 50 * 1024 * 1024 else { throw CloudMediaError.oversized }
    let hash = try sha256(file)
    let mime = UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? (item.kind == .video ? "video/mp4" : "image/jpeg")
    let params = CloudPrepareParameters(p_media_id: item.id, p_sha256: hash, p_bytes: size,
      p_mime_type: mime, p_display_name: resource.originalFilename,
      p_captured_at: item.captureDate.map { ISO8601DateFormatter().string(from: $0) },
      p_latitude: item.originalPlace?.latitude, p_longitude: item.originalPlace?.longitude)
    let prepared: CloudAssetRow = try await client.rpc("archive_prepare_asset", params: params).execute().value
    if prepared.status == "ready" { return prepared.mediaID }
    let path = prepared.objectPath
    // A previous attempt may have uploaded the object before it was marked ready.
    if try await !matchesRemote(path: path, hash: hash) {
      try await resumableUpload(file: file, size: size, mime: mime, path: path, hash: hash)
    }
    var hasPreview = false
    if let jpeg = makePreview(file: file, video: item.kind == .video) {
      let previewPath = "\(accountID)/\(prepared.mediaID)/preview.jpg"
      do {
        try await client.storage.from("archive-previews").upload(previewPath, data: jpeg,
          options: FileOptions(contentType: "image/jpeg"))
        hasPreview = true
      } catch {
        // Already uploaded in an earlier attempt; the completion RPC checks existence.
        hasPreview = true
      }
    }
    let signed = try await client.storage.from("archive-originals").createSignedURL(path: path, expiresIn: 600)
    let (downloaded, response) = try await URLSession.shared.download(from: signed)
    defer { try? FileManager.default.removeItem(at: downloaded) }
    guard (response as? HTTPURLResponse)?.statusCode == 200, try sha256(downloaded) == hash else { throw CloudMediaError.checksum }
    try await complete(mediaID: prepared.mediaID, preview: hasPreview)
    return prepared.mediaID
  }

  func url(for mediaID: String, preview: Bool = false) async throws -> URL? {
    let assets: [CloudAssetLookup] = try await client.from("archive_media_assets")
      .select("media_id,object_path,preview_path,status").eq("media_id", value: mediaID).execute().value
    guard let row = assets.first, row.status == "ready" else { return nil }
    if preview, let path = row.previewPath { return try await client.storage.from("archive-previews").createSignedURL(path: path, expiresIn: 900) }
    return try await client.storage.from("archive-originals").createSignedURL(path: row.objectPath, expiresIn: 900)
  }

  private func matchesRemote(path: String, hash: String) async throws -> Bool {
    guard let signed = try? await client.storage.from("archive-originals").createSignedURL(path: path, expiresIn: 300),
      let (file, response) = try? await URLSession.shared.download(from: signed) else { return false }
    defer { try? FileManager.default.removeItem(at: file) }
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
    guard try sha256(file) == hash else { throw CloudMediaError.checksum }
    return true
  }

  private func complete(mediaID: String, preview: Bool) async throws {
    _ = try await client.rpc("archive_complete_asset", params: CloudCompleteParameters(p_media_id: mediaID, p_preview: preview)).execute()
  }
  private func chosenResource(for asset: PHAsset) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)
    let wanted: [PHAssetResourceType] = asset.mediaType == .video ? [.video, .fullSizeVideo] : [.photo, .fullSizePhoto]
    return resources.first { wanted.contains($0.type) } ?? resources.first
  }
  private func sha256(_ file: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func makePreview(file: URL, video: Bool) -> Data? {
    let image: CGImage?
    if video {
      let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
      generator.appliesPreferredTrackTransform = true
      image = try? generator.copyCGImage(at: .zero, actualTime: nil)
    } else if let source = CGImageSourceCreateWithURL(file as CFURL, nil) {
      image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 640
      ] as CFDictionary)
    } else { image = nil }
    guard let image else { return nil }
    return UIImage(cgImage: image).jpegData(compressionQuality: 0.82)
  }
  private func resumableUpload(file: URL, size: Int64, mime: String, path: String, hash: String) async throws {
    let session = try await client.auth.session
    let host = (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String).flatMap { URL(string: $0)?.host }
    let endpoint = host.map { "https://\($0.replacingOccurrences(of: ".supabase.co", with: ".storage.supabase.co"))/storage/v1/upload/resumable" } ?? ""
    guard let endpointURL = URL(string: endpoint) else { throw CloudMediaError.invalidResponse }
    let key = "archive.tus.\(accountID).\(hash)"
    var uploadURL = UserDefaults.standard.string(forKey: key).flatMap(URL.init(string:))
    var offset: Int64 = 0
    if let previous = uploadURL, let resumed = try? await currentOffset(previous, token: session.accessToken) { offset = resumed }
    else { uploadURL = nil; UserDefaults.standard.removeObject(forKey: key) }
    if uploadURL == nil {
      var request = request(endpointURL, method: "POST", token: session.accessToken)
      request.setValue(String(size), forHTTPHeaderField: "Upload-Length")
      let values = ["bucketName": "archive-originals", "objectName": path, "contentType": mime, "cacheControl": "3600"]
      request.setValue(values.map { "\($0.key) \(Data($0.value.utf8).base64EncodedString())" }.joined(separator: ","), forHTTPHeaderField: "Upload-Metadata")
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 201,
        let location = http.value(forHTTPHeaderField: "Location"),
        let url = URL(string: location, relativeTo: endpointURL)?.absoluteURL else { throw CloudMediaError.invalidResponse }
      uploadURL = url
      UserDefaults.standard.set(url.absoluteString, forKey: key)
    }
    guard let uploadURL else { throw CloudMediaError.invalidResponse }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    while offset < size {
      try handle.seek(toOffset: UInt64(offset))
      guard let chunk = try handle.read(upToCount: min(chunkSize, Int(size - offset))), !chunk.isEmpty else { throw CloudMediaError.invalidResponse }
      var request = request(uploadURL, method: "PATCH", token: session.accessToken)
      request.httpBody = chunk
      request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
      request.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
      let (_, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 204 else { throw CloudMediaError.uploadFailed((response as? HTTPURLResponse)?.statusCode ?? 0) }
      offset = Int64(http.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? offset + Int64(chunk.count)
    }
    UserDefaults.standard.removeObject(forKey: key)
  }
  private func currentOffset(_ url: URL, token: String) async throws -> Int64 {
    let (_, response) = try await URLSession.shared.data(for: request(url, method: "HEAD", token: token))
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      let offset = Int64(http.value(forHTTPHeaderField: "Upload-Offset") ?? "") else { throw CloudMediaError.invalidResponse }
    return offset
  }
  private func request(_ url: URL, method: String, token: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_PUBLISHABLE_KEY") as? String {
      request.setValue(key, forHTTPHeaderField: "apikey")
    }
    return request
  }
}
