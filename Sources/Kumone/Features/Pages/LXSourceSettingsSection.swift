import SwiftUI

// MARK: - LX 自定义音源设置区
//
// 导入 pdone/lx-music-source 等仓库的音源脚本（latest.js 原文或在线 URL），
// 启用后当官方接口拿不到播放地址时用它解析。可对每个音源做可用性实测。

struct LXSourceSettingsSection: View {
    @StateObject private var manager = LXSourceManager.shared
    @State private var showImport = false
    @State private var importText = ""
    @State private var importURL = ""
    @State private var importing = false
    @State private var testingKey: String?
    @State private var testResults: [LXSourceManager.TestResult] = []
    @State private var showTestResult = false
    @State private var isTestingAll = false
    @State private var isImportingAll = false
    @State private var importAllResult: String?
    @State private var showImportAllResult = false

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
                    Button {
                        Task { await test(source.key) }
                    } label: {
                        if testingKey == source.key {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(testingKey != nil)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        manager.removeSource(source.key)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }

            if !manager.sources.isEmpty {
                Button {
                    Task { await testAll() }
                } label: {
                    if isTestingAll {
                        ProgressView("测试中…")
                    } else {
                        Label("测试全部音源", systemImage: "checkmark.circle")
                    }
                }
                .disabled(isTestingAll || testingKey != nil)
            }

            Button {
                Task { await importAll() }
            } label: {
                if isImportingAll {
                    ProgressView("正在从 GitHub 批量导入…")
                } else {
                    Label("一键导入全部音源", systemImage: "square.stack.3d.down.forward")
                }
            }
            .disabled(isImportingAll)

            Button {
                showImport = true
            } label: {
                Label("手动导入单个音源", systemImage: "plus.circle")
            }

            if let err = manager.lastError, !err.isEmpty {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            Text("用《晴天》实测每个音源能否解析播放地址。绿色✓可用，红色✗不可用。仅导入可信来源。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("LX 自定义音源")
        } footer: {
            Text("播放选源规则：网易云官方拿不到地址时，按下方启用顺序从上到下逐个尝试 LX 音源，第一个解析成功的生效；LX 全失败再用内置解锁源（酷狗/酷我）。测试✓的音源才可靠。每个音源最多 8 秒，避免卡住。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .sheet(isPresented: $showImport) {
            importSheet
        }
        .sheet(isPresented: $showTestResult) {
            testResultSheet
        }
        .sheet(isPresented: $showImportAllResult) {
            importAllResultSheet
        }
    }

    private var importAllResultSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(importAllResult ?? "")
                    .font(.system(size: 14))
                Text("已导入的音源可逐个点波形图标测试可用性；不可用的可左滑删除。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
            .navigationTitle("批量导入结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showImportAllResult = false }
                }
            }
        }
    }

    private func importAll() async {
        await MainActor.run { isImportingAll = true }
        let result = await manager.importAllFromGitHub()
        let text = "成功导入 \(result.ok) / \(result.total) 个音源"
            + (result.failures.isEmpty ? "" : "\n失败：\n" + result.failures.prefix(10).joined(separator: "\n"))
        await MainActor.run {
            isImportingAll = false
            importAllResult = text
            showImportAllResult = true
        }
    }

    // MARK: - 测试结果弹窗

    private var testResultSheet: some View {
        NavigationStack {
            List {
                ForEach(testResults) { r in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(r.name).font(.system(size: 14, weight: .medium))
                            Text("\(r.ok ? "可用" : "不可用") · 耗时 \(String(format: "%.1f", r.elapsed))s"
                                 + (r.platform.map { " · 平台 \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(r.message)
                                .font(.caption2).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("音源测试结果")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTestResult = false }
                }
            }
        }
    }

    private func test(_ key: String) async {
        await MainActor.run { testingKey = key }
        let result = await manager.testSource(key)
        await MainActor.run {
            testingKey = nil
            testResults = [result]
            showTestResult = true
        }
    }

    private func testAll() async {
        await MainActor.run { isTestingAll = true }
        var results: [LXSourceManager.TestResult] = []
        for source in manager.sources {
            results.append(await manager.testSource(source.key))
        }
        await MainActor.run {
            isTestingAll = false
            testResults = results
            showTestResult = true
        }
    }

    // MARK: - 导入

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
