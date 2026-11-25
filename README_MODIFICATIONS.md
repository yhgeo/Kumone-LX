# Kumone-LX 定制改动总览

基于 [missuo/kumone](https://github.com/missuo/kumone)，面向 iOS 16.6 TrollStore 免签名安装。本文按主题汇总最终交付的改动；架构与排查细节见 [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md)，用户说明见 [README.md](README.md)。

## 一、核心新增功能

### 每日推荐历史存档
- 每次拉取每日推荐按日期存快照到 `Documents/DailyRecommendArchive/yyyy-MM-dd.json`。
- 按 6:00 更新时间归档（6 点前算昨天）；同一天不覆盖，但凌晨旧数据允许被 6 点后新数据覆盖。
- 历史页按日期回看、整行点击播放、播放全部、滑动删除，自动清理 90 天前。
- 兼容旧精简存档格式，解码失败显示错误+重试。

### LX 自定义音源
- JavaScriptCore 复刻 LX user-api 宿主协议（request/on/send/EVENT_NAMES/env/version/currentScriptInfo/utils），可跑 `pdone/lx-music-source` 的 latest.js。
- 一键批量导入 GitHub 全部音源；按音源名生成唯一 key，重名加序号，不互相覆盖。
- 音源测试：官方五档音质（标准/较高/极高/无损/Hi-Res）、可调超时 1~15 秒、音质多选；结果列表显示 ✓/✗、耗时、命中平台，成功快排在前面，失败不自动停用。
- 实测可用音源受网络环境影响；音源返回 API 端点（JSON/302）时验证会解析出真实直链再播放。

### 播放诊断日志
- 追加式文本落盘（`Documents/playback-diagnostics.txt`），App 重启不丢，上限 600 条。
- 分类：系统/播放/解析/官方/兜底/音源/测试/下载；导出 sheet 可按分类筛选、预览最近 200 条，导出文件含全部。
- 全链路记录：官方结果、每个 LX 音源结果与耗时、URL 验证、最终来源、跳过/下载失败原因。

### 界面与交互
- 设置分「播放/界面/系统」三类；可隐藏所有底部 tab（推荐/我的也可隐藏，至少留一个）。
- 记住上次选中的 tab，重启恢复；被隐藏则回退到第一个可见项。
- mini player 与沉浸播放页显示当前实际来源（官方/LX·音源名/内置源）与音质档位。
- 播放列表面板：已播放与待播放合并为同一列表（已播放灰化、点击可回跳）。
- 新图标：品牌红渐变 + 白色 K + 音波装饰，源文件 `docs/icon.svg`。

## 二、播放与下载链路

### 播放解析顺序
`官方接口 → 缓存 → LX 自定义音源 → 内置解锁源（pyncmd/酷狗/酷我）→ 失败跳过`

- **官方风控修复**：eapi 设备头统一 iOS（os=ios、osver=16.6.1、appver=9.1.90），此前 UA=iPhone 但 osver=Windows 自相矛盾易被判伪造。设置→系统→接口可切换 pc/ios 对照。
- **平台隔离**：iOS 播放走 `PlayerServiceIOS.swift`，macOS 走 `PlayerService.swift`；`#if os(macOS)` / `#if os(iOS)` 条件编译互斥。所有 iOS 播放改动必须落在 iOS 文件。
- **第三方源 header**：AVURLAsset 与缓存加载器对 LX/内置源注入浏览器 UA + Referer，解决 CDN 拒绝导致的"LX 成功却跳过"。
- **失败冷却**：解析失败/假 URL 的音源 5 分钟内跳过，避免每首都重试已知坏源（曾因此卡 141 秒）。

### 下载
- 官方下载失败（VIP/风控/无版权）自动回退 LX 音源。
- `lxDownloadResource` 用 HEAD 拿 size、URL SHA256 作稳定标识；`OfflineAudioValidator` 对 lx· 来源跳过 MD5 比对，靠完整解码+时长验证。
- 下载请求对 lx· 来源注入浏览器 UA（不带 Referer，避免 CDN 防盗链）；资源超时 240s、请求超时 60s，卡死会失败并释放队列位，不堵住后续任务。
- 下载全链路日志已接入诊断系统。

## 三、构建与安装

- GitHub Actions（`.github/workflows/trollstore.yml`）：代码改动 push 到 main 触发，`xcodebuild CODE_SIGNING_ALLOWED=NO` 产出 unsigned IPA；文档改动不构建；打 `v*` tag 发 Release。
- 安装：TrollStore 打开 IPA（Settings → Install IPA），CoreTrust 完成安装，无需开发者证书。
- 版本号：`ios/Config/Shared.xcconfig` 的 `MARKETING_VERSION`，检查更新依赖其递增。

## 四、已知限制

- VIP/版权歌能否播放取决于官方接口与所导入音源的实际可用性；官方 -460 风控可能与账号/IP 相关。
- JavaScriptCore 不支持 Node 的 `require`/`fs`，依赖原生模块的音源不可用（绝大多数 lx 音源只依赖 `request`）。
- 音源可用数量受本机网络环境影响：部分音源 CDN 在特定网络下 DNS 不通或超时，属网络侧问题，不是代码缺陷。
