# Kumone-LX 技术笔记

本文记录本定制版的关键架构、排查过程与踩坑经验，供后续维护参考。面向用户的说明见 [README.md](README.md)。

## 1. 工程结构：iOS 与 macOS 两套 PlayerService

这是本项目**最重要的架构事实**，也是多次返工的根源。

| 文件 | 平台 | 说明 |
|---|---|---|
| `Sources/Kumone/Core/Player/PlayerServiceIOS.swift` | `#if os(iOS)` | iOS 实际使用的播放器，基于 `AVPlayer`。**所有 iOS 播放改动必须改这里** |
| `Sources/Kumone/Core/Player/PlayerService.swift` | `#if os(macOS)` | macOS 播放器，双 deck `PlaybackEngine` + AutoMix + stems |

- 两个文件**都**在 `Sources/Kumone` 下，都被 `Package.swift` 的 `KumoneCore` target 收集，都会传给编译器。
- 但整文件被互斥的条件编译包裹：iOS 构建时 `PlayerService.swift` 全文被跳过，**不产生任何符号、不增加包体积、不影响运行时**。
- `RepeatMode` / `PlaySource` / `PlayContext` 等类型在两个文件各定义一份，靠条件编译互斥，不会重复定义。
- 全仓库约 61 个整文件 `#if os(macOS)`、10 个整文件 `#if os(iOS)`。

**结论**：macOS 代码对 iOS 构建零影响，不需要也不能删除（删了 macOS target 直接废）。唯一的规则是——改 iOS 播放逻辑要改 `PlayerServiceIOS.swift`。

**踩过的坑**：曾把 LX 音源兜底、播放日志、强制重试全部加到 `PlayerService.swift`（macOS），结果 iOS 完全不生效，用户连续多次反馈"改了没用"。最后逐行核对才发现改错文件。教训：改之前先确认文件的平台归属。

## 2. iOS 播放解析链

```
play(tracks:) / togglePlayPause / advanceToNext
  → startPlaying(track)
    → resolveAndLoad(track, generation)
      ├─ 离线下载租约 → playOfflineFile
      ├─ 音频缓存命中 → installResolvedAsset
      ├─ 网易云官方接口 MusicAPI.songURLRetrying(level:)
      │    ├─ 拿到完整 URL → 直接用
      │    └─ 风控/无版权/试听 → 继续
      ├─ 缓存兜底 loadFallbackCache
      ├─ LX 自定义音源 LXSourceManager.resolve(track, quality)
      │    └─ 每个音源返回 URL 后 verifyAudioURL 验证真可播
      ├─ 内置解锁源 resolveAndLoadUnblocked（pyncmd/酷狗/酷我）
      └─ 全失败 → handleUnplayable（跳过）
```

关键不变量：
- `generation` 用于丢弃过期解析任务（切歌后旧任务结果作废）。
- `itemRetryGeneration` 允许失败重载一次（签名过期/网络切换），避免死循环。
- 官方返回的 URL 若加载失败，先 CDN twin 重试，再走兜底链。

## 3. LX 音源宿主协议

`LXSourceEngine.swift` 在 JavaScriptCore 中复刻 LX Music 的 `globalThis.lx` 对象：

- `EVENT_NAMES` / `request` / `on` / `send` / `env` / `version` / `currentScriptInfo` / `utils`
- `utils`：crypto.md5（CryptoKit Insecure.MD5，`md5(encodeURIComponent(str))`）、aes/rsa、buffer.from/bufToString
- 脚本顶层常写 `let {EVENT_NAMES,request,on,send,...}=globalThis.lx` 解构，**任一字段缺失都会报 "Right side of assignment cannot be destructured"**。
- `request(url, opts, cb)` 由 Swift `URLSession` 实现，自动跟随系统代理/VPN。脚本报 "[local] 不支持" 是其自身环境检测，非代理问题。

导入 key：按音源 `@name` 生成唯一键，重名加 `-2/-3`；早期用 URL 末段 `latest.js` 导致全部音源互相覆盖。

## 4. 假 URL 问题与验证

**现象**：日志显示某音源 0.2s 就"成功"，host 恒为同一个，但 AVPlayer 加载失败、歌曲被跳过；测试却显示全档 ✓。

**根因**：音源脚本返回无效地址（反爬页/错误页/网页），而测试只判断 URL 是不是 http 开头 → 假阳性。第一个假阳性音源会一直占位，挡住后面真正能用的音源。

**修复**：`LXSourceManager.verifyAudioURL(_:)` 发 `Range: bytes=0-2047` 请求，检查：
- HTTP 状态码 200~206；
- Content-Type 非 `text/html` / `json` / `text/plain`；
- 返回实体非空。

`resolve()`（播放）与 `testSource()`（测试）都先验证再采用，假 URL 自动淘汰换下一个音源。

**音质映射**（与官方五档对齐）：标准→128k、较高/极高→320k、无损→flac、Hi-Res→flac24bit。

## 5. 官方风控（-460 检测到您的网络环境存在风险）

`MusicClient.eapi()` 的 header 曾自相矛盾：

- `User-Agent` 写 `iPhone; iOS 16.2`
- `osver` 写 `Microsoft-Windows-10-Professional...`、`os: pc`

这种伪造客户端指纹易被风控判定。修复为统一 iOS 头：`os=ios`、`osver=16.6.1`、`appver=9.1.90`、`mobilename=iPhone`、`resolution=1179x2556`，并提供 pc/ios 切换开关对照测试。修复后日志中官方接口从全量 -460 恢复为 `code=200`。

若两种头都风控，则是账号/IP 级问题，需依赖 LX 自定义音源。

## 6. 诊断日志

`PlaybackDiagnostics.swift`：

- 追加式文本日志：每条用 `FileHandle` append 到 `Documents/playback-diagnostics.txt`，避免整文件重写时的并发覆盖丢失。
- 全播放入口埋点：`play(tracks:)` / `playTrack` / `startPlaying` / `togglePlayPause` / `advanceToNext` / `playLocalFile` / `resolveAndLoad` / `handleUnplayable`，以及音源测试的每一档。
- 启动时写"就绪"记录；上限 2000 条；设置 → 诊断可导出 txt。
- `load()` 解析历史行时需注意行首空格（曾因 `drop(while:)` 缺失导致重启后历史不回显）。

排查方法论：**先看日志确定到底走到哪一步**，不要猜。上次"播放没日志"的真正原因是埋点全在 macOS 文件；"播放跳过"的真正原因是假 URL。日志是定位这类问题的唯一可靠手段。

## 7. 每日推荐归档

- 网易云每日推荐 6:00 更新。归档 key 按 6 点分界：6 点前算前一天。
- 同一归档日首次写入后不覆盖；但若旧存档 `savedAt` 在 6 点前、当前在 6 点后，视为凌晨旧数据，允许新数据覆盖。
- `DailySnapshot` 自定义 `init(from:)` 兼容旧版精简 `ArchivedTrack` 格式，用 JSON 重建为可播放 `Track`。

## 8. 设置页结构

`SettingsView` 用分段控件分「播放 / 界面 / 系统」三类：
- 播放：音质、音效、灰色歌曲解锁、内置音源、LX 自定义音源、诊断
- 界面：隐藏底部 tab、主题、播放页模式、歌词等
- 系统：存储、接口（eapi pc/ios 切换）、账号、更新

隐藏 tab：`hiddenTabs: [String]` 存 `IOSTab.stableKey`；同时过滤 iOS 26 原生 `TabView` 与自定义 `GlassTabBar`；当前 tab 被隐藏时自动切回推荐。

## 9. 构建与 CI

- `.github/workflows/trollstore.yml`：`push` 到 main 且仅代码路径（`Sources/**`、`ios/**`、`Package.swift*`）触发；文档改动不构建；`concurrency.cancel-in-progress` 取消排队旧构建。
- `xcodebuild CODE_SIGNING_ALLOWED=NO` → unsigned IPA → Artifact；打 `v*` tag 发 Release。
- 版本号在 `ios/Config/Shared.xcconfig` 的 `MARKETING_VERSION`，应用内检查更新依赖它递增。

## 10. 经验清单

1. 改 iOS 播放逻辑 → 只认 `PlayerServiceIOS.swift`。
2. 遇到"改了没用" → 先确认改的文件是否真的参与 iOS 编译。
3. 音源"可用"必须验证真实 URL，不能只看 scheme。
4. 排查播放问题先看诊断日志，定位到具体步骤再动手。
5. 日志落盘用追加式，别用整文件覆盖。
6. 条件编译隔离的 macOS 代码保留即可，不要删。
