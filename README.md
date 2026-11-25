# Kumone-LX

基于 [missuo/kumone](https://github.com/missuo/kumone) 深度定制的 iOS 音乐播放器，面向 **TrollStore（巨魔）免签名安装**。在原版基础上新增了每日推荐历史存档、LX 自定义音源、播放诊断日志、官方风控修复等大量改动。

> 本项目与网易云音乐无关联，不包含任何官方域名或 API 地址。技术细节见 [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md)。

## 核心功能（本定制版新增）

### 1. 每日推荐历史存档
- 每次成功拉取「每日推荐」自动按日期保存快照到 `Documents/DailyRecommendArchive/yyyy-MM-dd.json`。
- 按网易云 6:00 更新时间归档：6 点前拉到的算昨天；6 点后新数据覆盖凌晨旧存档。
- 「每日推荐」页可进入历史，按日期回看、点击播放、播放全部、滑动删除，自动清理 90 天前存档。
- 兼容旧版精简存档格式，解码失败显示错误+重试，不再无限转圈。

### 2. LX 自定义音源
- 在 JavaScriptCore 中复刻 LX Music 的 user-api 宿主协议，直接运行 `pdone/lx-music-source` 的 `latest.js` 脚本。
- 播放解析链：**网易云官方 → 缓存 → LX 自定义音源 → 内置解锁源（pyncmd/酷狗/酷我）→ 失败跳过**。
- 一键从 GitHub 批量导入全部音源，也可粘贴脚本原文/URL 单个导入。
- 音源按测试结果排序（快的在前），不通的自动停用；导入 key 唯一，不会互相覆盖。
- **URL 真实验证**：音源返回的地址先发 Range 请求验证（状态码、Content-Type、实体内容），过滤假 URL/反爬网页，避免"测试显示可用却播放跳过"。
- 音质档位与官方对齐：标准 / 较高 / 极高 / 无损 / Hi-Res。

### 3. 官方接口风控修复
- 原版 eapi 设备头自相矛盾（UA=iPhone，但 `osver=Windows`、`os=pc`），易被判定伪造客户端触发 -460「检测到您的网络环境存在风险」。
- 统一为 iOS 客户端头（`os=ios`、`osver=16.6.1`、`appver=9.1.90`）；设置 → 系统 → 接口 可切换 pc/ios 对照测试。

### 4. 播放诊断日志
- 全链路记录每首歌：官方接口结果、每个音源的解析结果与耗时、URL 验证结果、最终选中的来源、跳过原因。
- 追加式文本落盘，App 重启不丢；设置 → 诊断 → 导出为 txt 分享。
- mini player 与播放页实时显示当前歌曲的**实际来源（官方 / LX 音源 / 内置源）与音质**。

### 5. 界面与其它
- 设置页分「播放 / 界面 / 系统」三类，不再一长条滚动。
- 可隐藏底部 tab（精选 / 漫游 / 搜索 / 我的，推荐不可隐藏）。
- 移除 iCloud 同步（TrollStore 无 iCloud 权限）。
- 应用内检查更新指向本仓库 Release，支持 TrollStore 一键安装。

沿用原版：官方 App 扫码登录（weapi/eapi）、歌词、音效、下载、CarPlay 等。

## 构建与安装

GitHub Actions（`.github/workflows/trollstore.yml`）：代码改动 push 到 main 或手动触发，macOS runner 上 `xcodebuild`（`CODE_SIGNING_ALLOWED=NO`）产出 unsigned IPA；文档改动不触发构建。打 `v*` tag 时发布 Release。

安装：用 TrollStore 打开 `Kumone-LX.ipa`（Settings → Install IPA）。TrollStore 用 CoreTrust 在设备上完成签名，无需开发者证书。iOS 16.0+，ARM64。

## 音源脚本来源

`https://github.com/pdone/lx-music-source` —— 设置 → LX 自定义音源 → 一键导入，或填 `https://raw.githubusercontent.com/pdone/lx-music-source/main/<source>/latest.js` 单个导入。脚本在本机 JS 沙箱运行，仅导入可信来源。

## 已知限制

- VIP / 版权歌曲能否播放取决于官方接口与所导入音源的实际可用性；官方 -460 风控可能与账号/IP 相关。
- JavaScriptCore 不支持 Node 的 `require`/`fs`，依赖 Node 原生模块的音源不可用（绝大多数 lx 音源只依赖 `request`，可正常运行）。
- macOS 代码以 `#if os(macOS)` 条件编译隔离，对 iOS 构建无影响，保留不动；面向 iOS 的改动必须落在 `PlayerServiceIOS.swift` 等非 macOS 文件。
