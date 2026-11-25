import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 诊断日志设置区
// 播放解析链全程记录到 PlaybackDiagnostics，可导出为文本文件排查跳过问题。

struct DiagnosticsSettingsSection: View {
    @State private var entryCount = 0
    @State private var showExport = false
    @State private var exportURL: URL?
    @State private var message = ""
    /// 预览文本只在 sheet 出现时生成一次，避免 body 重绘时反复拼接上千条日志造成卡顿。
    @State private var previewText = ""
    @State private var logFilter = "全部"
    private static let filters = ["全部", "播放", "解析", "官方", "兜底", "音源", "测试", "下载", "系统"]

    var body: some View {
        Section {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("播放诊断日志")
                    Text("已记录 \(entryCount) 条 · 导出可排查歌曲跳过原因")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button {
                refreshCount()
                buildPreview()
                showExport = true
                message = ""
            } label: {
                Label("导出诊断日志", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                PlaybackDiagnostics.shared.clear()
                refreshCount()
                message = "已清空"
            } label: {
                Label("清空日志", systemImage: "trash")
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Text("日志包含：每首歌的官方接口结果、每个音源的解析结果与耗时、最终选中的播放地址、跳过原因。不含登录 cookie。")
                .font(.caption2).foregroundStyle(.tertiary)
        } header: {
            Text("诊断")
        }
        .onAppear { refreshCount() }
        .sheet(isPresented: $showExport) {
            exportSheet
        }
    }

    private func refreshCount() {
        entryCount = PlaybackDiagnostics.shared.allEntries().count
    }

    /// 只预览最近 200 条，避免上千条日志一次性渲染卡顿；导出仍是全部。
    private func buildPreview() {
        let all = PlaybackDiagnostics.shared.allEntries()
        let filtered = logFilter == "全部" ? all : all.filter { $0.category == logFilter }
        let shown = filtered.suffix(200)
        previewText = shown.map { "[\($0.time)] [\($0.category)] \($0.message)" }
            .joined(separator: "\n")
        if shown.isEmpty {
            previewText = "（该分类暂无记录）"
        } else if filtered.count > shown.count {
            previewText = "……（仅预览最近 200 条，共 \(filtered.count) 条；导出包含全部）\n\n" + previewText
        }
    }

    private var exportSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("播放诊断日志（\(entryCount) 条）").font(.headline)
                Text("点「导出」保存到「文件」App 或分享；可发给开发者排查。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("查看分类", selection: $logFilter) {
                    ForEach(Self.filters, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                #if os(macOS)
                .onChange(of: logFilter) { _, _ in buildPreview() }
                #else
                .onChange(of: logFilter) { _ in buildPreview() }
                #endif
                ScrollView {
                    Text(previewText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 320)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    if let url = PlaybackDiagnostics.shared.exportFile() {
                        exportURL = url
                        message = "已导出：\(url.lastPathComponent)"
                        share(url)
                    } else {
                        message = "导出失败"
                    }
                } label: {
                    Label("导出到文件", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(20)
            .navigationTitle("诊断日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showExport = false }
                }
            }
        }
    }

    #if os(iOS)
    private func share(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let root = scene.keyWindow?.rootViewController else { return }
        var presenter = root
        while let next = presenter.presentedViewController { presenter = next }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            pop.sourceView = presenter.view
            pop.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                    y: presenter.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
    #else
    private func share(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif
}
