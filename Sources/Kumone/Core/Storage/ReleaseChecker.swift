import Foundation

/// Looks up the latest GitHub release. iOS has no Sparkle, so Settings
/// offers a manual check that links to the release page for re-sideloading.
enum ReleaseChecker {
    struct Release {
        let version: String
        /// The release page (fallback download link).
        let url: URL
        /// Direct download URL of the iOS IPA asset, when present.
        let ipaURL: URL?
    }

    static let releasesPage = URL(string: "https://github.com/yhgeo/Kumone-LX/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yhgeo/Kumone-LX/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        // 仓库还没有任何 Release 时 GitHub 返回 404：视为"已是最新"，
        // 不要弹"数据加载失败"。返回 releasesPage 作为兜底，ipaURL 为空。
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return Release(version: currentVersion, url: Self.releasesPage, ipaURL: nil)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String, let url = URL(string: html)
        else {
            return Release(version: currentVersion, url: Self.releasesPage, ipaURL: nil)
        }
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let ipa = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".ipa") == true }
        let ipaURL = (ipa?["browser_download_url"] as? String).flatMap(URL.init)
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       url: url, ipaURL: ipaURL)
    }

    /// True when `remote` is newer than `local` (numeric dotted compare).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = remote.split(separator: ".").map { Int($0) ?? 0 }
        let b = local.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
