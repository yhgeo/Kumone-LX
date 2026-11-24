# Kumone-LX 定制版说明

本仓库基于 [missuo/kumone](https://github.com/missuo/kumone) 复刻改造，面向 iOS 16.6 巨魔（TrollStore）免签名安装。原项目说明见 [README.md](README.md) / [README_CN.md](README_CN.md)。

## 在本定制版中新增的功能

### 1. 每日推荐历史存档（核心诉求）
- 每次成功拉取「每日推荐」后，自动按日期保存一份快照到
  `Documents/DailyRecommendArchive/yyyy-MM-dd.json`，同一天不覆盖。
- 首屏「推荐」页新增「推荐历史」入口，按日期回看每天推荐了哪些歌，可滑动删除。
- 自动清理 90 天前的存档。
- 相关代码：
  - `Sources/Kumone/Core/Storage/DailyRecommendArchive.swift`
  - `Sources/Kumone/Features/Pages/DailyArchiveView.swift`

### 2. LX 自定义音源（kumone 原本不支持自定义音源）
- 在 JavaScriptCore 中复刻了 LX Music 的 user-api 宿主协议（`request / on / send / EVENT_NAMES / setTimeout / atob / btoa`），
  可直接运行 `pdone/lx-music-source` 等仓库的 `latest.js` 音源脚本。
- 播放解析链：官方接口 → 内置解锁源（pyncmd/酷狗/酷我）→ **LX 自定义音源**（新增兜底）。
- 设置页 →「LX 自定义音源」可粘贴脚本原文或输入在线 URL 导入，支持启用/删除。
- 相关代码：
  - `Sources/Kumone/Core/LXSource/LXSourceEngine.swift`（JS 宿主 + 网络桥）
  - `Sources/Kumone/Core/LXSource/LXSourceManager.swift`（脚本持久化与解析入口）
  - `Sources/Kumone/Features/Pages/LXSourceSettingsSection.swift`

### 3. 扫码登录（沿用 kumone，已验证可用）
- kumone 原生实现 weapi（双重 AES-CBC + RSA）与 eapi（AES-ECB + MD5），
  官方 App 扫码登录，cookie 本地持久化并自动刷新。这是本 App 的主登录方式，
  替代了此前自研版本点击登录闪退的问题。

## 构建与安装

- GitHub Actions（`.github/workflows/trollstore.yml`）：`push` 到 main 或手动触发，
  在 macOS runner 上 `xcodebuild`（不签名）→ `ldid` 伪签名 → 打包 TrollStore IPA，上传 Artifact。
- 打 tag（`v*`）时额外发布到 GitHub Release。
- 安装：用 TrollStore 打开生成的 `Kumone-LX-trollstore.ipa`（TrollStore → Settings → Install IPA）。

## 音源来源

- LX 音源脚本：`https://github.com/pdone/lx-music-source`
- 导入方式：设置 → LX 自定义音源 → 导入，填 `https://raw.githubusercontent.com/pdone/lx-music-source/main/<source>/latest.js`。
- 注意：仅导入可信来源的脚本；脚本在本机 JS 沙箱运行。

## 已知限制

- VIP / 版权歌曲能否播放取决于官方接口与所导入音源的实际可用性。
- JavaScriptCore 不支持 Node 的 `require`/`fs` 等能力；依赖 Node 原生模块的音源脚本不可用（绝大多数 lx 音源只依赖 `request`，可正常运行）。
