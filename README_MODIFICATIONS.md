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
  在 macOS runner 上 `xcodebuild`（`CODE_SIGNING_ALLOWED=NO`）→ 打包 unsigned IPA，上传 Artifact。
  这与 kumone 原版 iOS 构建方式完全一致：构建端不签名、不做 ldid。
- 打 tag（`v*`）时额外发布到 GitHub Release。
- 安装：用 TrollStore 打开生成的 `Kumone-LX.ipa`（TrollStore → Settings → Install IPA）。
  TrollStore 负责在设备上用 CoreTrust 完成安装，所以 unsigned IPA 即可，无需开发者证书。

## 音源来源

- LX 音源脚本：`https://github.com/pdone/lx-music-source`
- 导入方式：设置 → LX 自定义音源 → 导入，填 `https://raw.githubusercontent.com/pdone/lx-music-source/main/<source>/latest.js`。
- 注意：仅导入可信来源的脚本；脚本在本机 JS 沙箱运行。

## 已知限制

- VIP / 版权歌曲能否播放取决于官方接口与所导入音源的实际可用性。
- JavaScriptCore 不支持 Node 的 `require`/`fs` 等能力；依赖 Node 原生模块的音源脚本不可用（绝大多数 lx 音源只依赖 `request`，可正常运行）。

## 二次定制（2026-11-24）

- **VIP 歌曲改走自定义音源**：`PlayerService.resolveSource` 先判断歌曲可播放性，VIP/付费/无版权/下架歌曲直接走 LX 自定义音源，不再请求网易云官方接口（规避"检测到您的网络环境存在风险"风控提示与自动跳过）。非 VIP 歌曲仍走官方资源，速度快。官方只给试听片段时也切自定义音源拿完整版。
- **移除 iCloud 同步**：设置页的 iCloud 区、登录页/侧栏的同步登录按钮、播放接力横幅/列表全部置空，SyncService 不再启动。TrollStore 环境无 iCloud 权限，去掉更干净。
- **修正更新地址**：`ReleaseChecker` 从 `missuo/kumone` 改为 `yhgeo/Kumone-LX`，设置页检查更新指向本定制版仓库。

## 三次修复（2026-11-24 晚）

- **普通歌误判/风控跳过**：根因是网易云 eapi 的 -460"网络环境风险"是账号/IP 级全局风控，与 VIP 无关。改为结果驱动：先试官方，拿到完整地址直接用；官方失败/风控/试听则清掉误导文案，依次用 LX 自定义音源 + 内置解锁源兜底；全失败提示"所有音源均无法解析"。已移除 VIP 预判逻辑。
- **音源可用性实测**：设置 → LX 自定义音源，每个音源右侧有测试图标（可单个测/全部测），用《晴天》探针解析，弹窗显示可用状态、耗时、命中平台与错误信息。引擎记录脚本异常与每个平台的失败原因供诊断。
- **历史存档可播放**：DailySnapshot 改存完整 `Track`（Codable），历史某天页每行可点击播放（startAt 定位），并加"播放全部"。
- **推荐历史入口**：移到「每日推荐」页 header，播放全部按钮下方，无需绕到首页卡片。
- **检查更新**：`ReleaseChecker` 对无 Release 的 404 优雅降级为"已是最新版本"，不再报"数据加载失败"；并建立 `v0.1.0` Release 带 IPA，检查更新可正常工作。
