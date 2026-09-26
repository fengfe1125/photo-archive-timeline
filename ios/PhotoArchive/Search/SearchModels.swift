import Foundation
import CryptoKit

struct PhotoSearchQuery: Codable, Equatable {
  var start: String? = nil
  var end: String? = nil
  var city: String = ""
  var include: [String] = []
  var exclude: [String] = []
  var night = false
  var needsYear = false
  var unresolved: String = ""
  var hasConditions: Bool { start != nil || end != nil || !city.isEmpty || !include.isEmpty || !exclude.isEmpty || night || !unresolved.isEmpty }
  var key: String { SearchDigest.of((try? JSONEncoder.sorted.encode(self)) ?? Data()) }
  func validate() throws {
    for value in [start, end].compactMap({ $0 }) {
      guard SearchCalendar.parse(value) != nil else { throw ArchiveServiceError(message: "日期条件无效") }
    }
    guard start == nil || end == nil || start! <= end!, city.count <= 100,
      include.count <= 20, exclude.count <= 20,
      (include + exclude).allSatisfy({ !$0.isEmpty && $0.count <= 100 }), unresolved.count <= 2000 else {
      throw ArchiveServiceError(message: "搜索条件无效，请调整后重试")
    }
  }
}
extension JSONEncoder {
  static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }
}
enum SearchDigest {
  static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
enum SearchCalendar {
  static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c }
  static func format(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
  static func parse(_ text: String) -> Date? {
    let p = text.split(separator: "-").compactMap { Int($0) }
    guard p.count == 3, let d = calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2])), format(d) == text else { return nil }
    return d
  }
  static func springFestival(_ year: Int) -> (String, String)? {
    guard (1900...2100).contains(year), let first = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else { return nil }
    var lunar = Calendar(identifier: .chinese); lunar.timeZone = calendar.timeZone
    for i in 0..<65 {
      let d = calendar.date(byAdding: .day, value: i, to: first)!
      let parts = lunar.dateComponents([.month, .day], from: d)
      if parts.month == 1 && parts.day == 1 {
        return (format(calendar.date(byAdding: .day, value: -1, to: d)!), format(calendar.date(byAdding: .day, value: 14, to: d)!))
      }
    }
    return nil
  }
}
enum LocalSearchParser {
  static let scenes: [String: [String]] = [
    "海边": ["beach", "ocean", "sea", "coast", "sand"], "江边": ["river"], "湖边": ["lake"],
    "山林": ["mountain", "forest", "tree"], "食物": ["food", "meal", "dish"],
    "聚餐": ["dining", "meal", "restaurant", "table"], "建筑": ["building", "architecture"],
    "夜景": ["night"], "日落": ["sunset"], "截图": ["screenshot"], "人物": ["person", "people", "portrait"]]
  static func parse(_ text: String, current: PhotoSearchQuery, now: Date = .now) -> PhotoSearchQuery {
    var q = current
    let yearNow = SearchCalendar.calendar.component(.year, from: now)
    func matches(_ pattern: String) -> [[String]] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
      let ns = text as NSString
      return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
        (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
      }
    }
    let explicitYear = matches("(20[0-9]{2}|19[0-9]{2})年").first.flatMap { Int($0[1]) }
    let year = explicitYear ?? (text.contains("去年") ? yearNow - 1 : text.contains("今年") ? yearNow : nil)
    if text.contains("春节") || text.contains("过年") {
      if let year, let interval = SearchCalendar.springFestival(year) { q.start = interval.0; q.end = interval.1; q.needsYear = false }
      else { q.needsYear = true }
    } else if let year {
      q.start = "\(year)-01-01"; q.end = "\(year)-12-31"
    }
    let dates = matches("(20[0-9]{2}|19[0-9]{2})[-年]([0-9]{1,2})[-月]([0-9]{1,2})日?")
    if let first = dates.first {
      q.start = String(format: "%04d-%02d-%02d", Int(first[1])!, Int(first[2])!, Int(first[3])!)
      let last = dates.last!; q.end = String(format: "%04d-%02d-%02d", Int(last[1])!, Int(last[2])!, Int(last[3])!)
    } else if let month = matches("([0-9]{1,2})月").first.flatMap({ Int($0[1]) }), (1...12).contains(month) {
      let y = year ?? q.start.flatMap { Int($0.prefix(4)) } ?? yearNow
      let d = SearchCalendar.calendar.date(from: DateComponents(year: y, month: month, day: 1))!
      q.start = SearchCalendar.format(d)
      q.end = SearchCalendar.format(SearchCalendar.calendar.date(byAdding: .day, value: -1, to: SearchCalendar.calendar.date(byAdding: .month, value: 1, to: d)!)!)
    }
    let aliases = ["武汉": "武汉", "江城": "武汉", "上海": "上海", "北京": "北京", "青岛": "青岛", "杭州": "杭州", "成都": "成都", "深圳": "深圳", "广州": "广州", "南京": "南京", "重庆": "重庆", "厦门": "厦门", "三亚": "三亚"]
    for (name, city) in aliases where text.contains(name) { q.city = city }
    if let city = matches("在([\\p{Han}]{2,8})市").first { q.city = city[1] }
    if text.contains("晚上") { q.night = true }
    if text.contains("不限时间") || text.contains("全部日期") { q.start = nil; q.end = nil; q.needsYear = false; q.night = false }
    if text.contains("不限地点") { q.city = "" }
    if text.contains("改成") && scenes.keys.contains(where: { text.contains($0) }) { q.include = [] }
    for scene in scenes.keys.sorted() where text.contains(scene) {
      let excluded = ["不要", "去掉", "排除", "不看"].contains { text.contains($0 + scene) || text.contains($0 + "只有" + scene) }
      if excluded { q.include.removeAll { $0 == scene }; if !q.exclude.contains(scene) { q.exclude.append(scene) } }
      else { q.exclude.removeAll { $0 == scene }; if !q.include.contains(scene) { q.include.append(scene) } }
    }
    if text.contains("前后") {
      let numbers = ["一": 1, "两": 2, "二": 2, "三": 3, "四": 4, "五": 5, "七": 7]
      let n = matches("前后([0-9一两二三四五七]+)天").first.flatMap { Int($0[1]) ?? numbers[$0[1]] }
      if let n, n <= 366, let s = q.start.flatMap(SearchCalendar.parse), let e = q.end.flatMap(SearchCalendar.parse) {
        q.start = SearchCalendar.format(SearchCalendar.calendar.date(byAdding: .day, value: -n, to: s)!)
        q.end = SearchCalendar.format(SearchCalendar.calendar.date(byAdding: .day, value: n, to: e)!)
      }
    }
    // Preserve unsupported semantics for explicit cloud parsing instead of silently dropping them.
    var remainder = text
    for term in Array(scenes.keys) + Array(aliases.keys) + ["找", "帮我", "拍摄", "拍", "照片", "图片", "的", "在", "去年", "今年", "春节", "过年", "只看", "不要", "去掉", "排除", "不看", "改成", "再", "和", "以及", "期间", "晚上", "前后", "扩大", "天", "不限时间", "全部日期", "不限地点"] { remainder = remainder.replacingOccurrences(of: term, with: "") }
    remainder = remainder.replacingOccurrences(of: "[0-9年月日一两二三四五七\\s，。！、到至-]", with: "", options: .regularExpression)
    if !remainder.isEmpty { q.unresolved = String((q.unresolved.isEmpty ? text : q.unresolved + "；" + text).prefix(2000)) }
    return q
  }
}
struct SearchAnalysis: Codable {
  var version: String
  var labels: [String] = []
  var state = "pending"
  var failureReason: String? = nil
  var needsLocalVision: Bool { state != "ready" }
  var city = ""
  var description = ""
  var visualModel = ""
  var decisions: [String: Double] = [:]
}
struct SearchAlbum: Codable, Identifiable {
  var id = UUID().uuidString
  var name: String
  var query: PhotoSearchQuery
  var excluded: Set<String> = []
}
struct SearchPreferences: Codable {
  var geo = false
  var ai = false
  var albums: [SearchAlbum] = []
  var pending: [String: String] = [:]
  var modelVersion: String? = nil
}
enum SearchMatch { case match, possible, excluded }
enum SearchMatcher {
  static func match(_ q: PhotoSearchQuery, day: String?, place: String, hour: Int?, analysis: SearchAnalysis?, screenshot: Bool) -> SearchMatch {
    var missing = q.needsYear
    if q.start != nil || q.end != nil {
      if let day { if let s = q.start, day < s { return .excluded }; if let e = q.end, day > e { return .excluded } }
      else { missing = true }
    }
    if !q.city.isEmpty {
      if place.isEmpty || place == "照片位置" { missing = true }
      else if !place.contains(q.city) { return .excluded }
    }
    if q.night { if let hour { if (6..<18).contains(hour) { return .excluded } } else { missing = true } }
    if q.exclude.contains("截图") && screenshot { return .excluded }
    if q.include.contains("截图") && !screenshot { return .excluded }
    let semantics = q.include.filter { $0 != "截图" } + q.exclude.filter { $0 != "截图" }
    if let p = analysis?.decisions[q.key] {
      if p <= 0.2 { return .excluded }
      return !missing && p >= 0.8 ? .match : .possible
    }
    if !q.unresolved.isEmpty { missing = true }
    let labels = analysis?.labels ?? []
    for scene in q.include where scene != "截图" {
      if !(LocalSearchParser.scenes[scene] ?? [scene]).contains(where: { term in labels.contains(where: { $0.contains(term) }) }) { missing = true }
    }
    // An uncertain negative label must not erase potentially relevant pictures.
    if q.exclude.contains(where: { $0 != "截图" }) { missing = true }
    if !semantics.isEmpty && analysis?.state != "ready" { missing = true }
    return missing ? .possible : .match
  }
}
