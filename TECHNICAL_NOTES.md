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

**调用约定已对照 LX 官方源码验证**（`lyswhut/lx-music-desktop` 的 `src/main/modules/userApi/renderer/preload.js`）：

- 官方 `events.request.call(context, { source, action, info })`，其中 `info = { type, musicInfo }`——与本引擎 `resolveOne` 一致。
- `send('inited', { sources: { kw: {type:'music',actions, qualitys}, ... } })` 上报平台能力——与 `capabilities` 记录一致。
- `musicUrl` 返回必须是字符串 URL（长度 <2048、以 http 开头）——与引擎 `onFulfilled` 校验一致。

**本地音源测试方法**（`../lx-source-test/faithful.js`）：在 node 里忠实复刻上述宿主，`musicInfo` 用纯数字 id（`1295216600`），遍历 `inited` 上报的所有平台逐个跑。结论：调用约定正确；部分音源 CDN（sayqz.com/haitangw.net 等）在测试机网络下 DNS 不通，属网络环境问题，不是代码缺陷。

导入 key：按音源 `@name` 生成唯一键，重名加 `-2/-3`；早期用 URL 末段 `latest.js` 导致全部音源互相覆盖。

## 4. 假 URL 问题与验证

**现象**：日志显示某音源 0.2s 就"成功"，host 恒为同一个，但 AVPlayer 加载失败、歌曲被跳过；测试却显示全档 ✓。

**根因**：音源脚本返回无效地址（反爬页/错误页/网页），而测试只判断 URL 是不是 http 开头 → 假阳性。第一个假阳性音源会一直占位，挡住后面真正能用的音源。

**修复**：`LXSourceManager.verifyAudioURL(_:)` 发 `Range: bytes=0-2047` 请求，检查 HTTP 状态码 200~206、Content-Type 非网页、实体非空。

**二次修正（重要）**：初版验证见 JSON 就判失败，误杀了一大批**正规 API 端点型音源**——例如幻音返回 `music-dl.sayqz.com/api/?...&type=url`，请求它得到 JSON，需解析出真实音频 URL。现验证逻辑：

- 跟随 302 重定向（`response.url` 即最终地址）；
- Content-Type 为 json/javascript 时，从 `url/data/musicUrl/link/playUrl` 字段（含嵌套 `data.url`）提取真实地址，递归验证（最多 2 层）；
- 返回「最终可播 URL」而非 Bool，播放时用它替换音源原始返回值（`LXResolvedURL(url: finalURL, ...)`）；
- 只有 text/html、text/plain、无实体才判失败。

这是"可用音源变少"的主因修正。经 node 本地测试（faithful.js）验证：溯音音源返回真实 `kw-lv.kuwo.cn` 直链、验证通过；幻音等 CDN 在测试机 DNS 不通，属网络侧限制。

`resolve()`（播放）与 `testSource()`（测试）共用此验证，假 URL 淘汰换下一个音源，并配合失败冷却黑名单（5 分钟）避免重复试错。

**音质映射**（与官方五档对齐）：标准→128k、较高/极高→320k、无损→flac、Hi-Res→flac24bit。

## 5. 官方风控（-460 检测到您的网络环境存在风险）

`MusicClient.eapi()` 的 header 曾自相矛盾：

- `User-Agent` 写 `iPhone; iOS 16.2`
- `osver` 写 `Microsoft-Windows-10-Professional...`、`os: pc`

这种伪造客户端指纹易被风控判定。修复为统一 iOS 头：`os=ios`、`osver=16.6.1`、`appver=9.1.90`、`mobilename=iPhone`、`resolution=1179x2556`，并提供 pc/ios 切换开关对照测试。修复后日志中官方接口从全量 -460 恢复为 `code=200`。

若两种头都风控，则是账号/IP 级问题，需依赖 LX 自定义音源。

## 5b. 下载链路与 CDN header

官方下载失败（VIP/风控/无版权）时 `DownloadManager` 的 resolver 回退 `MusicAPI.lxDownloadResource`：从 LX 音源解析 URL → HEAD 拿 Content-Length → URL 去 query 后 SHA256 前 32 位作 contentMD5 标识 → 构造 descriptor。`OfflineAudioValidator` 对 `lx·` 来源跳过 MD5 比对（音源无官方 MD5），靠文件大小 + 完整解码 + 时长验证。

**下载 0KB 卡住的排查**（诊断日志分类=下载）：日志显示 `NSURLErrorDomain -1001`（超时）。根因是后台下载请求不带 header、且请求超时只有 30s：

- 对 `lx·` 来源的下载请求注入浏览器 UA，但**不带 Referer**——实测 `music.163.com` Referer 会让酷我/网易 CDN 触发防盗链（表现为超时）。注意这与播放路径不同：播放带 UA+Referer 是有效的，下载则不行。
- `timeoutIntervalForRequest` 30→60s，`timeoutIntervalForResource` 120→240s；卡死下载超时失败并释放队列位，避免后续 20 个任务全堵在排队中（并发上限 2）。
- `lxDownloadResource` 的 HEAD 请求也带浏览器 UA。

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
3. 音源"可用"必须验证真实 URL，且要处理 JSON API 端点/302 重定向，不能见 JSON 就判失败。
4. 排查播放/下载问题先看诊断日志（下载也有分类），定位到具体步骤再动手。
5. 日志落盘用追加式，别用整文件覆盖；上限与预览都要限制，避免导出卡顿。
6. 条件编译隔离的 macOS 代码保留即可，不要删。
7. 播放与下载的 CDN header 策略不同：播放带 UA+Referer 有效，下载只需 UA（Referer 反触发防盗链）。
8. 怀疑音源/引擎不兼容时，对照 LX 官方 preload 源码 + 用 node 忠实模拟宿主跑脚本，区分"代码问题"与"网络环境限制"。
