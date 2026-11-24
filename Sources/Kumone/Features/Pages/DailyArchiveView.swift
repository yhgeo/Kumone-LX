import SwiftUI

// MARK: - 每日推荐历史存档页
// 按日期回看已保存的每日推荐快照。数据在 DailySongsView 拉取成功后写入。

struct DailyArchiveView: View {
    @State private var dates: [String] = []
    @State private var selected: DailySnapshot?
    @State private var loadError: String?

    private var store: DailyRecommendArchive { .shared }

    var body: some View {
        Group {
            if dates.isEmpty {
                EmptyStateView(
                    icon: "calendar.badge.clock",
                    title: "暂无历史记录",
                    subtitle: "打开「每日推荐」后，当天的推荐会自动存档到这里"
                )
            } else {
                List {
                    ForEach(dates, id: \.self) { key in
                        NavigationLink {
                            ArchiveDayView(dateKey: key)
                        } label: {
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(Theme.accent)
                                VStack(alignment: .leading) {
                                    Text(displayDate(key))
                                        .font(.system(size: 15, weight: .medium))
                                    Text("点击查看当天推荐")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { store.remove(dateKey: dates[i]) }
                        dates = store.listDateKeys()
                    }
                }
            }
        }
        .navigationTitle("推荐历史")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { dates = store.listDateKeys() }
        .refreshable { dates = store.listDateKeys() }
    }

    private func displayDate(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return key }
        f.dateFormat = "yyyy年M月d日 EEEE"
        return f.string(from: d)
    }
}

private struct ArchiveDayView: View {
    let dateKey: String
    @State private var snapshot: DailySnapshot?
    @EnvironmentObject private var player: PlayerService

    var body: some View {
        Group {
            if let snapshot {
                List {
                    Section {
                        Text("存档于 \(snapshot.savedAt.formatted(.dateTime.year().month().day().hour().minute()))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("共 \(snapshot.tracks.count) 首")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("歌曲") {
                        ForEach(snapshot.tracks) { t in
                            HStack(spacing: 10) {
                                if let pic = t.picURL, let url = pic.resizedImageURL(120) {
                                    CachedAsyncImage(url: url)
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.system(size: 14, weight: .medium))
                                    Text(t.artists).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } else {
                ProgressView().onAppear {
                    snapshot = try? DailyRecommendArchive.shared.load(dateKey: dateKey)
                }
            }
        }
        .navigationTitle(dateKey)
        .navigationBarTitleDisplayMode(.inline)
    }
}
