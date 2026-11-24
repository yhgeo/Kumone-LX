import Foundation
import os.log

// MARK: - 每日推荐历史存档
//
// 用户核心诉求：每天把网易云每日推荐"记录"下来，可回看历史某一天推荐了什么。
// kumone 原本只展示当天推荐，这里补一层按日期的快照存档：
//   - 每天首次拉取成功后写入一份 JSON（Documents/DailyRecommendArchive/yyyy-MM-dd.json）
//   - 同一天重复拉取不覆盖（保留当天第一次快照）
//   - 支持列出所有日期、读取某天、删除某天、清理过期

struct DailySnapshot: Codable, Hashable, Identifiable {
    var id: String { dateKey }
    let dateKey: String          // yyyy-MM-dd
    let savedAt: Date
    let tracks: [ArchivedTrack]
}

struct ArchivedTrack: Codable, Hashable, Identifiable {
    var id: Int { songID }
    let songID: Int
    let name: String
    let artists: String
    let album: String
    let picURL: String?
    let reason: String?
    let durationMS: Int
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

    /// 当天首次拉取成功时调用；同一天不覆盖。
    @discardableResult
    func saveToday(_ tracks: [Track]) async throws -> DailySnapshot? {
        guard !tracks.isEmpty else { return nil }
        let key = Self.key(for: Date())
        if fm.fileExists(atPath: fileURL(for: key).path) {
            return try? load(dateKey: key)
        }
        let archived = tracks.map { t in
            ArchivedTrack(
                songID: t.id,
                name: t.name,
                artists: t.artists.map(\.name).joined(separator: "/"),
                album: t.album.name,
                picURL: t.album.picUrl,
                reason: t.subtitle?.nilIfEmpty,
                durationMS: t.durationMS
            )
        }
        let snapshot = DailySnapshot(dateKey: key, savedAt: Date(), tracks: archived)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL(for: key), options: .atomic)
        log.info("saved daily archive \(key, privacy: .public) count=\(archived.count)")
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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
