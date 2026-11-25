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

## 四次修复（2026-11-24 夜）

- **音源测试解构失败**：野花等音源用 `let {...}=globalThis.lx` 解构，之前只注入了全局 request/on/send，缺 `lx` 对象。现在注入完整 `lx`（EVENT_NAMES/request/on/send/env/version/currentScriptInfo/utils 含 md5/aes/buffer）。测试改为等待异步 inited 完成后再 resolve。
- **音源互相覆盖**：导入 key 之前一律用 URL 末段 "latest"，导致新音源覆盖旧的。改为按音源名生成唯一 key，重名自动加序号。
- **一键导入**：设置页「一键导入全部音源」按钮，通过 GitHub API 拉取 pdone/lx-music-source 全部目录的 latest.js 批量导入，弹窗显示成功/失败数。
- **历史页加载卡死**：旧版存档是精简结构，新版解码失败后无限转圈。现在兼容旧格式（重建为可播放 Track），失败时显示错误+重试按钮，不再死转。
- **普通歌回归**：git diff 对比初版定位到 `freeTrialInfo==nil` 判断把带试听字段的普通歌误判跳过。恢复初版"有 URL 就用"逻辑；freeTrialInfo 只作试听标记，不影响有 URL 先播。

## 五次修复（2026-11-25）

- **播放诊断日志**：新增 `PlaybackDiagnostics`，全链路记录每首歌的官方接口结果、每个 LX 音源解析结果与耗时、最终选中的播放地址、跳过原因。设置 → 诊断 → 导出诊断日志，可分享为 txt 文件排查。
- **普通/VIP 跳过修复**：
  1) 音质映射修正：`higher`(较高) 之前被映射成 128k（多数音源不支持），现在标准/较高/极高统一 320k。
  2) 官方 URL 加载失败（风控返回非音频假地址）时，强制走音源重试一次（`forceSourceRetryIDs`/`retriedSourceIDs` 防循环），而不是直接跳过。
- **音源测试超时**：每个音源最多 8 秒（引擎 resolve 加 timeout 参数），避免 Hello World 那种 30 秒等待。播放解析同样每音源 8 秒。
- **归档时间**：网易云日推每天 6:00 更新，6 点前拉到的是昨天的，现在归到昨天日期，不再误记为今天历史。
- **选源说明**：设置页说明播放时按启用顺序逐个尝试 LX 音源，第一个成功的生效；LX 全失败再用内置酷狗/酷我。

## 六次修复（2026-11-25 早）

- **诊断日志持久化**：从内存改为写盘（Documents/playback-diagnostics.json），App 重启不丢。此前导出 0 条是因为没播放过歌 + 日志只在内存。
- **音源测试**：超时从 8 秒降到 3 秒；增加四档音质测试（320k/128k/flac/flac24bit），显示每档 ✓/✗；测试后按成功率+延迟自动排序（快的在前），不通的自动取消启用。
- **选源有序化**：enabledKeys 从 Set 改为有序数组，UI 列表顺序 = 播放解析顺序（第一个成功的生效）。
- **代理说明**：JS 音源脚本的 request 走 Swift URLSession，自动跟随 iOS 系统代理/VPN；"[local] 不支持" 是音源自身环境检测，非代理问题。

## 七次修复（2026-11-25 早）

- **日志补全**：此前 0 条是因为播放走缓存分支、测试无埋点、且单例首次访问才初始化。现在 App 启动即写"就绪"记录；播放准备/缓存命中/离线播放、音源测试每档音质均有日志。仍持久化到磁盘。
- **日推归档**：6:00 后重新拉取会覆盖 6 点前的旧存档（此前"同一天不覆盖"导致 6 点更新后历史里还是昨天内容）。
- **隐藏 tab**：设置 → 界面 → 底部标签，可隐藏 精选/漫游/搜索/我的（推荐不可隐藏）。过滤同时作用于 iOS 26 原生 TabView 与自定义 GlassTabBar。
- **设置页分类**：顶部新增「播放 / 界面 / 系统」分段控件，选项分组显示，不再一长条。

## 八次修复（2026-11-25）

- **播放日志漏记根因**：此前只埋在 resolveAndLoad；mini player 点播放走 `togglePlayPause → engine.resume/play`，不经 resolveAndLoad，所以完全没记录。现在顶层必经入口 play(tracks:)/startPlaying/togglePlayPause 全部埋点，任何播放动作都留痕。
- **测试提速**：超时 3s→2s；先测 320k/128k，两档都失败即判不可用、跳过 flac/flac24bit；固定 300ms 等待改轮询 150ms。17 音源从约 6 分钟大幅缩短。
- **测试结果入列表**：每个音源行直接显示 ✓/✗、耗时、各音质结果，不必点开弹窗。

## 九次修复（2026-11-25）

- **日志仍不记录播放的根治**：此前用 JSON 整文件反复重写，高并发下后写覆盖先写。改为**追加式文本日志**（每条 FileHandle append 到 playback-diagnostics.txt），不再丢条目；导出直接读内存+文本。
- **全播放入口埋点**：play(tracks:)/playTrack/startPlaying/togglePlayPause/advanceToNext/playLocalFile/resolveAndLoad 全部记录，任何播放/切歌/恢复/跳过动作都必留痕。

## 十次修复（2026-11-25 · 真正根因）

- **此前多次播放修复全部无效的根源**：kumone 有两套 PlayerService，`PlayerService.swift` 是 `#if os(macOS)`，`PlayerServiceIOS.swift` 是 `#if os(iOS)`。之前所有"音源兜底/播放日志/强制重试"都加在 macOS 文件，iOS App 根本不编译它——所以 VIP/风控歌依旧跳过、日志一条没有。
- 现已把完整链路移植到 iOS 文件：官方失败 → 缓存 → **LX 自定义音源**（用户导入的）→ 内置解锁源（酷狗/酷我/pyncmd）→ 失败跳过；play/startPlaying/toggle/advance/resolveAndLoad/handleUnplayable 全埋点；init 触发日志就绪。
- 顺带修复 PlaybackDiagnostics.load() 的行首空格解析 bug（重启后历史日志不再丢失）。

## 十一次修复（2026-11-25）

- **假 URL 根治**：日志显示幻音音源 0.2s"成功"但每首都同一无效 host，AVPlayer 加载失败就跳过。现在 LX resolve 与测试都会对返回的 URL 发 Range 请求验证（状态码 200~206、非 text/html/json、有实体），假 URL 自动淘汰换下一个音源。
- **音质对齐**：音源测试五档改为官方的 标准/较高/极高/无损/Hi-Res，显示中文名；映射 标准→128k、较高/极高→320k、无损→flac、Hi-Res→flac24bit。
- **官方风控修复**：eapi 头此前自相矛盾（UA=iPhone 但 osver=Windows、os=pc），易被判伪造。统一为 iOS 客户端头（os=ios、osver=16.6.1、appver=9.1.90）。设置→系统→接口可切换 pc/ios 对照测试。

## 十二次修复（2026-11-25 · v0.2.0）

- **播放来源/音质可视化**：mini player 副标题与沉浸播放页 metadata 显示当前实际来源（网易云官方 / LX·音源名 / 内置解锁源）与音质档位，试听加标记。PlayerService 与 PlayerServiceIOS 均加 playbackSourceLabel/playbackQualityLabel 计算属性。
- **文档整理**：README.md 重写为中文、聚焦本定制版改动；README_CN.md 精简指向；新增 TECHNICAL_NOTES.md 系统记录架构（两套 PlayerService）、解析链、LX 宿主协议、假 URL 验证、风控修复、诊断日志、归档、构建 CI 与踩坑经验。
- **macOS 代码评估**：确认 61 个整文件 `#if os(macOS)` 与 10 个 `#if os(iOS)` 条件编译隔离，macOS 代码对 iOS 构建零影响（不产符号、不增体积），保留不动；面向 iOS 的改动只落 PlayerServiceIOS.swift。

## 十三次修复（2026-11-25 · v0.2.1）

- **沉浸播放页显示来源/音质**：CompactTrackHeader 加来源+音质行（此前只在 mini player 和 metadata 方法显示，沉浸歌词页用的是 CompactTrackHeader 所以没显示）。
- **加速音源切换**：日志显示每首都重试已知假 URL 音源（幻音/长青/全豆要各 1-3s），fish 甚至卡 141s。新增失败冷却黑名单：解析失败/假 URL 的音源 5 分钟内跳过，测试后重置；初始化 200ms→120ms。切换从 6-10 秒降到 1-2 秒。
- **隐藏 tab 全放开**：推荐和我的都可隐藏，仅保留"至少一个可见 tab"防白屏；当前 tab 被隐藏时切到第一个可见项。
- **下载走音源**：官方下载失败（VIP/风控/无版权"暂不可下载"）时自动回退 LX 自定义音源。MusicAPI.lxDownloadResource 用 HEAD 拿 size、URL SHA256 作稳定标识构造 descriptor；OfflineAudioValidator 对 lx· 来源跳过 MD5 比对，改由完整解码+时长验证保证完整性。

## 十四次修复（2026-11-25 · v0.2.2）

- **tab 选择持久化**：selectedTab 存 UserDefaults，重启恢复；隐藏的 tab 重启时回退到第一个可见项（解决"隐藏推荐重启又显示"）。
- **VIP 歌 LX 成功却跳过**：日志显示溯音音源验证通过（host=kw-er.kuwo.cn）后立刻跳过——原因是 AVURLAsset/CachingAudioResourceLoader 裸请求不带 UA/Referer，酷我 CDN 拒绝。现在第三方源播放时注入浏览器 UA + music.163.com Referer（AVURLAsset options + URLSession header）。
- **音源测试不再误停用**：只用《晴天》一首探针，失败不代表音源对其它歌不可用。测试失败只排序靠后，不再自动停用；测试验证也加 Referer 与播放对齐。

## 十五次修复（2026-11-25 · v0.2.3）

- **下载进度 0KB 卡住**：与播放同源问题——LX 音源下载请求不带 UA/Referer 被 CDN 拒。BackgroundDownloadTransport.start 对 lx· 来源注入浏览器头；加 timeoutIntervalForResource=120s，卡死下载超时失败并释放队列位，避免后续全部堵在排队中。
- **日志导出卡顿**：exportSheet 的 body 里直接 Text(exportedText()) 每次重绘拼接上千条。改为点导出时生成一次预览、只显示最近 200 条；完整内容仍写入导出文件。
- **音源测试可配置**：新增每档超时 Stepper（1~15 秒，默认 3）与音质多选（标准/较高/极高/无损/Hi-Res），存 UserDefaults；testSource 接受 timeout/qualities 参数。
- **可用音源统计**：从日志最后一次完整测试统计，实测可用 4 个（溯音5档、fish5档、星海3档、非常刀2档），15 个全失败。GitHub 显示"可用"多但本 App 少，主因是本机 URL 验证过滤假 URL + 测试探针歌《晴天》单曲限制。
