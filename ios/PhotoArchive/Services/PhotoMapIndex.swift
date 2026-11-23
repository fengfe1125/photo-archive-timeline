import Foundation

/// Keeps unchanged map regions stable when only a few photos or corrections change.
actor PhotoMapIndex {
  private var owner = ""
  private var points: [String: PhotoMapPoint] = [:]
  private var groups: [String: [String: PhotoMapPoint]] = [:]
  private var clusters: [String: PhotoMapCluster] = [:]
  private var step = 0.02

  func update(owner: String, items: [MediaItem], corrections: [String: MetadataCorrection], limit: Int = 120) throws -> [PhotoMapCluster] {
    var nextPoints: [String: PhotoMapPoint] = [:]
    for item in items {
      try Task.checkCancellation()
      let correction = corrections[item.id]
      let place = correction?.effectivePlaceMode == .clear ? nil : correction?.effectivePlaceMode == .value ? correction?.place : item.originalPlace
      guard let latitude = place?.latitude, let longitude = place?.longitude,
        latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { continue }
      nextPoints[item.id] = PhotoMapPoint(id: item.id, latitude: latitude, longitude: longitude)
    }
    var nextStep = self.owner == owner ? step : 0.02
    var nextGroups = self.owner == owner ? groups : [:]
    var nextClusters = self.owner == owner ? clusters : [:]
    let previous = self.owner == owner ? points : [:]
    var affected = Set<String>()
    for (id, old) in previous {
      if let next = nextPoints[id], old.latitude == next.latitude, old.longitude == next.longitude { continue }
      let key = Self.key(old, step: nextStep)
      nextGroups[key]?[id] = nil
      if nextGroups[key]?.isEmpty == true { nextGroups[key] = nil }
      affected.insert(key)
    }
    for (id, point) in nextPoints {
      if let old = previous[id], old.latitude == point.latitude, old.longitude == point.longitude { continue }
      let key = Self.key(point, step: nextStep)
      nextGroups[key, default: [:]][id] = point
      affected.insert(key)
    }
    // A global resolution change is required only when the marker budget is exceeded.
    while nextGroups.count > max(1, limit) {
      try Task.checkCancellation()
      nextStep *= 2
      nextGroups = [:]
      for point in nextPoints.values { nextGroups[Self.key(point, step: nextStep), default: [:]][point.id] = point }
      affected = Set(nextGroups.keys); nextClusters = [:]
    }
    for key in affected {
      guard let members = nextGroups[key], !members.isEmpty else { nextClusters[key] = nil; continue }
      let values = members.values
      nextClusters[key] = PhotoMapCluster(id: key,
        latitude: values.reduce(0) { $0 + $1.latitude } / Double(values.count),
        longitude: values.reduce(0) { $0 + $1.longitude } / Double(values.count),
        mediaIDs: members.keys.sorted())
    }
    try Task.checkCancellation()
    self.owner = owner; points = nextPoints; groups = nextGroups; clusters = nextClusters; step = nextStep
    return nextClusters.values.sorted { $0.id < $1.id }
  }

  private static func key(_ point: PhotoMapPoint, step: Double) -> String {
    "\(Int(floor((point.latitude + 90) / step))):\(Int(floor((point.longitude + 180) / step)))"
  }
}
