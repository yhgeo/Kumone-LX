import SwiftUI

// MARK: - LX 自定义音源设置区
//
// 导入 pdone/lx-music-source 等仓库的音源脚本（latest.js 原文或在线 URL），
// 启用后当官方/内置解锁源拿不到播放地址时用这些脚本解析。

struct LXSourceSettingsSection: View {
    @StateObject private var manager = LXSourceManager.shared
    @State private var showImport = false
    @State private var importText = ""
    @State private var importURL = ""
    @State private var importing = false

    var body: some View {
        Section {
            ForEach(manager.sources) { source in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(
                        get: { manager.enabledKeys.contains(source.key) },
                        set: { manager.setEnabled(source.key, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name.isEmpty ? source.key : source.name)
                                .font(.system(size: 14, weight: .medium))
                            if !source.author.isEmpty {
                                Text("by \(source.author) · v\(source.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        manager.removeSource(source.key)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            Button {
                showImport = true
            } label: {
                Label("导入音源脚本", systemImage: "plus.circle")
            }

            if let err = manager.lastError, !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Text("导入 LX Music 音源脚本（latest.js）。启用后用于解析灰色/无版权歌曲播放地址。来源：pdone/lx-music-source。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("LX 自定义音源")
        } footer: {
            Text("脚本在本机运行，请只导入可信来源。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .sheet(isPresented: $showImport) {
            importSheet
        }
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                Section("在线 URL") {
                    TextField("https://.../latest.js", text: $importURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    Button("从 URL 导入") {
                        guard let url = URL(string: importURL.trimmingCharacters(in: .whitespaces)),
                              url.scheme?.hasPrefix("http") == true else {
                            manager.lastError = "请输入有效的 http(s) 地址"
                            return
                        }
                        importing = true
                        Task {
                            let text = await fetchText(url)
                            await importRaw(text, key: suggestedKey(from: url))
                        }
                    }
                    .disabled(importing || importURL.isEmpty)
                }
                Section("粘贴脚本原文") {
                    TextEditor(text: $importText)
                        .frame(minHeight: 160)
                        .font(.system(size: 12, design: .monospaced))
                    Button("导入脚本") {
                        importing = true
                        Task { await importRaw(importText) }
                    }
                    .disabled(importing || importText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if importing {
                    ProgressView("导入中…")
                }
            }
            .navigationTitle("导入 LX 音源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showImport = false }
                }
            }
        }
    }

    private func fetchText(_ url: URL) async -> String {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        } catch {
            await MainActor.run { manager.lastError = "下载失败：\(error.localizedDescription)" }
            return ""
        }
    }

    private func importRaw(_ raw: String, key: String? = nil) async {
        await manager.importScript(raw, key: key)
        await MainActor.run {
            importing = false
            if manager.lastError == nil {
                importText = ""
                showImport = false
            }
        }
    }

    private func suggestedKey(from url: URL) -> String {
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty ? "source" : last
    }
}
