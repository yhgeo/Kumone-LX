import Foundation
import os.log

// MARK: - 每日推荐历史存档
//
// 用户核心诉求：每天把网易云每日推荐"记录"下来，可回看历史某一天推荐了什么。
// kumone 原本只展示当天推荐，这里补一层按日期的快照存档：
//   - 每天首次拉取成功后写入一份 JSON（Documents/DailyRecommendArchive/yyyy-MM-dd.json）
//   - 同一天重复拉取不覆盖（保留当天第一次快照）
//   - 支持列出所有日期、读取某天、删除某天、清理过期

/// 旧版存档的精简歌曲结构（2026-11-24 之前的格式），用于兼容解码。
private struct LegacyArchivedTrack: Codable {
    let songID: Int
    let name: String
    let artists: String
    let album: String
    let picURL: String?
    let durationMS: Int
}

struct DailySnapshot: Codable, Hashable, Identifiable {
    var id: String { dateKey }
    let dateKey: String          // yyyy-MM-dd
    let savedAt: Date
    /// 存完整 Track，历史页可直接重建播放上下文。
    let tracks: [Track]

    private enum CodingKeys: String, CodingKey {
        case dateKey, savedAt, tracks
    }

    init(dateKey: String, savedAt: Date, tracks: [Track]) {
        self.dateKey = dateKey
        self.savedAt = savedAt
        self.tracks = tracks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateKey = try c.decode(String.self, forKey: .dateKey)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        // 新格式：完整 Track 数组
        if let full = try? c.decode([Track].self, forKey: .tracks) {
            tracks = full
            return
        }
        // 旧格式：精简结构，重建为可播放的 Track
        let legacy = try c.decode([LegacyArchivedTrack].self, forKey: .tracks)
        // 用 JSON 重建以带上 album/picUrl/duration（Track 只有 decode 初始化器）
        tracks = legacy.compactMap { t in
            let artistNames = t.artists.split(separator: "/").map(String.init)
            var albumDict: [String: Any] = ["id": 0, "name": t.album]
            if let pic = t.picURL { albumDict["picUrl"] = pic }
            let json: [String: Any] = [
                "id": t.songID,
                "name": t.name,
                "ar": artistNames.map { ["id": 0, "name": $0] },
                "al": albumDict,
                "dt": t.durationMS,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  let track = try? JSONDecoder().decode(Track.self, from: data)
            else { return nil }
            return track
        }
    }
}

enum DailyRecommendArchiveError: LocalizedError {
    case emptyTracks
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTracks: return "推荐列表为空，未写入存档"
        case .readFailed(let m): return "读取存档失败：\(m)"
        }
    }
}

final class DailyRecommendArchive {
    static let shared = DailyRecommendArchive()

    private let log = Logger(subsystem: "sb.moe.kumone", category: "daily-archive")
    private let root: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        root = docs.appendingPathComponent("DailyRecommendArchive", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        root.appendingPathComponent("\(key).json")
    }

    private static func key(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 按网易云更新时间（每天 6:00）归档：6 点前拉到的是昨天的推荐，归到昨天。
    static func archiveDateKey(for date: Date = Date()) -> String {
        let cal = Calendar.current
        let hour = cal.component(.hour, from: date)
        let effective = hour < 6 ? (cal.date(byAdding: .day, value: -1, to: date) ?? date) : date
        return key(for: effective)
    }

    /// 拉取成功后归档。规则：
    ///  - 归档日按 6:00 分界（6 点前算昨天）。
    ///  - 同一归档日首次写入后不覆盖；但若旧存档是 6 点前写的（凌晨拉到的
    ///    昨日内容），6 点后的新数据会覆盖它——因为日推 6:00 才更新。
    @discardableResult
    func saveToday(_ tracks: [Track]) async throws -> DailySnapshot? {
        guard !tracks.isEmpty else { return nil }
        let key = Self.archiveDateKey()
        if fm.fileExists(atPath: fileURL(for: key).path),
           let existing = try? load(dateKey: key) {
            let savedHour = Calendar.current.component(.hour, from: existing.savedAt)
            let nowHour = Calendar.current.component(.hour, from: Date())
            let isStalePre6 = savedHour < 6 && nowHour >= 6
            if !isStalePre6 { return existing }
        }
        let snapshot = DailySnapshot(dateKey: key, savedAt: Date(), tracks: tracks)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(for: key), options: .atomic)
        log.info("saved daily archive \(key, privacy: .public) count=\(tracks.count)")
        return snapshot
    }

    /// 所有已存档日期，倒序（最近在前）。
    func listDateKeys() -> [String] {
        (try? fm.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted(by: >) ?? []
    }

    func load(dateKey: String) throws -> DailySnapshot {
        let data = try Data(contentsOf: fileURL(for: dateKey))
        return try decoder.decode(DailySnapshot.self, from: data)
    }

    func remove(dateKey: String) {
        try? fm.removeItem(at: fileURL(for: dateKey))
    }

    /// 删除 N 天前的存档（默认保留 90 天）。
    func prune(keepingDays: Int = 90) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepingDays, to: Date()) ?? Date()
        let cutoffKey = Self.key(for: cutoff)
        for key in listDateKeys() where key < cutoffKey {
            remove(dateKey: key)
        }
    }
}
