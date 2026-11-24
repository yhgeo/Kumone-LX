import Foundation
import JavaScriptCore
import os.log

// MARK: - LX 自定义音源引擎
//
// 在 JavaScriptCore 里复刻 LX Music 的 user-api 宿主协议，让 pdone/lx-music-source
// 这类音源脚本（依赖全局 request / on / send / EVENT_NAMES / setTimeout）直接运行。
//
// 宿主向脚本注入：
//   - request(url, options, callback)  -> Swift URLSession 发起 HTTP，回调 (err, resp)
//   - on('request', handler)           -> 保存 handler，Swift 侧解析歌曲时调用
//   - send('inited', info)             -> 脚本初始化完成，记录支持的能力
//   - EVENT_NAMES / setTimeout / clearTimeout / console / atob / btoa
//
// 所有 JS 执行与状态读写都在同一串行队列上，保证线程安全。

/// 一个已导入的音源脚本的元信息（来自文件头注释 @name/@version 等）。
struct LXSourceMeta: Codable, Hashable, Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let author: String
    let version: String
    let description: String
    let rawScript: String
}

/// 音源解析结果。
struct LXResolvedURL {
    let url: URL
    let sourceName: String
}

enum LXSourceError: LocalizedError {
    case notInitialized
    case sourceNotFound(String)
    case scriptFailed(String)
    case invalidURL(String)
    case noURL

    var errorDescription: String? {
        switch self {
        case .notInitialized: return "LX 音源引擎未初始化"
        case .sourceNotFound(let s): return "未找到音源：\(s)"
        case .scriptFailed(let m): return "音源脚本错误：\(m)"
        case .invalidURL(let u): return "无效播放地址：\(u)"
        case .noURL: return "音源未返回播放地址"
        }
    }
}

final class LXSourceEngine {

    static let shared = LXSourceEngine()

    private let log = Logger(subsystem: "sb.moe.kumone", category: "lx-source")
    private let queue = DispatchQueue(label: "sb.moe.kumone.lxsource", qos: .userInitiated)
    private var context: JSContext?
    private let session: URLSession

    /// 当前脚本注册的唯一 request handler；key = 平台代号（kw/kg/tx/wy/mg），
    /// ".__pending__" 是脚本未上报平台时的兜底。
    private var requestHandlers: [String: JSValue] = [:]
    /// 当前脚本上报的平台 -> actions。
    private var capabilities: [String: [String]] = [:]
    /// native setTimeout 计时器，防止被 GC。
    private var timers: [Int32: DispatchWorkItem] = [:]
    private var timerCounter: Int32 = 0
    /// 最近一次脚本执行/解析的详细错误，供可用性测试与诊断展示。
    private(set) var lastDiagnostic: String = ""
    /// 最近一次脚本 evaluate 是否抛异常。
    private(set) var lastScriptError: String?

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15"
        ]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 宿主 shim

    /// 每次加载脚本都重建 JSContext：脚本顶层有 `const`，重复 evaluateScript
    /// 会因为标识符重复声明而 SyntaxError。
    private func installShim() {
        let ctx = JSContext()!
        self.context = ctx
        ctx.exceptionHandler = { [weak self] _, value in
            let msg = value?.toString() ?? "unknown JS exception"
            self?.log.error("JS exception: \(msg, privacy: .public)")
            self?.lastScriptError = msg
        }

        // console：只取第一个参数转字符串，足够脚本调试用
        let logFn: @convention(block) (String) -> Void = { msg in
            NSLog("[LX] %@", msg)
        }
        let console = JSValue(newObjectIn: ctx)!
        for level in ["log", "warn", "error", "info"] {
            console.setObject(JSValue(object: logFn, in: ctx), forKeyedSubscript: level as NSString)
        }
        ctx.setObject(console, forKeyedSubscript: "console" as NSString)

        // EVENT_NAMES
        let events = JSValue(newObjectIn: ctx)!
        events.setObject("request", forKeyedSubscript: "request" as NSString)
        events.setObject("inited", forKeyedSubscript: "inited" as NSString)
        events.setObject("updateAlert", forKeyedSubscript: "updateAlert" as NSString)
        ctx.setObject(events, forKeyedSubscript: "EVENT_NAMES" as NSString)

        // request(url, options, callback) -> URLSession
        let requestFn: @convention(block) (String, JSValue?, JSValue?) -> JSValue = { [weak self] urlString, optionsValue, callback in
            guard let self, let ctx = self.context else { return JSValue(undefinedIn: nil) }
            let abort = JSValue(newObjectIn: ctx)!
            var aborted = false
            abort.setObject(JSValue(object: { () in aborted = true }, in: ctx), forKeyedSubscript: "abort" as NSString)

            guard let url = URL(string: urlString) else {
                self.safeCall(callback, ["网络地址错误", NSNull()])
                return abort
            }
            let opts = optionsValue?.toDictionary() ?? [:]
            let method = (opts["method"] as? String)?.uppercased() ?? "GET"
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = (opts["timeout"] as? NSNumber).map { min(Double(truncating: $0), 60) } ?? 15
            if let headers = opts["headers"] as? [String: Any] {
                for (k, v) in headers { req.setValue("\(v)", forHTTPHeaderField: k) }
            }
            if let body = opts["body"] {
                if let str = body as? String {
                    req.httpBody = str.data(using: .utf8)
                } else if let data = body as? Data {
                    req.httpBody = data
                } else if JSONSerialization.isValidJSONObject(body),
                          let data = try? JSONSerialization.data(withJSONObject: body) {
                    req.httpBody = data
                    if req.value(forHTTPHeaderField: "Content-Type") == nil {
                        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    }
                }
            }
            let task = self.session.dataTask(with: req) { data, response, error in
                self.queue.async {
                    guard !aborted else { return }
                    if let error {
                        self.safeCall(callback, [error.localizedDescription, NSNull()])
                        return
                    }
                    let http = response as? HTTPURLResponse
                    let bodyString: String
                    if let data {
                        bodyString = String(data: data, encoding: .utf8)
                            ?? String(data: data, encoding: .isoLatin1) ?? ""
                    } else { bodyString = "" }
                    let resp: [String: Any] = [
                        "statusCode": http?.statusCode ?? 200,
                        "statusMessage": HTTPURLResponse.localizedString(forStatusCode: http?.statusCode ?? 200),
                        "headers": http?.allHeaderFields ?? [:],
                        "body": bodyString,
                        "url": response?.url?.absoluteString ?? urlString,
                    ]
                    self.safeCall(callback, [NSNull(), resp])
                }
            }
            task.resume()
            abort.setObject(JSValue(object: { () in aborted = true; task.cancel() }, in: ctx), forKeyedSubscript: "abort" as NSString)
            return abort
        }
        ctx.setObject(JSValue(object: requestFn, in: ctx), forKeyedSubscript: "request" as NSString)

        // on(event, handler)
        let onFn: @convention(block) (String, JSValue?) -> JSValue = { [weak self] event, handler in
            guard let self, let ctx = self.context else { return JSValue(undefinedIn: nil) }
            if event == "request", let handler {
                self.requestHandlers[".__pending__"] = handler
            }
            return JSValue(object: true, in: ctx)!
        }
        ctx.setObject(JSValue(object: onFn, in: ctx), forKeyedSubscript: "on" as NSString)

        // send(event, data)
        let sendFn: @convention(block) (String, JSValue?) -> JSValue = { [weak self] event, data in
            guard let self, let ctx = self.context else { return JSValue(undefinedIn: nil) }
            if event == "inited" {
                let info = data?.toDictionary() ?? [:]
                if let sources = info["sources"] as? [String: Any] {
                    for (key, value) in sources {
                        guard let s = value as? [String: Any] else { continue }
                        let actions = (s["actions"] as? [String]) ?? []
                        self.capabilities[key] = actions
                        if let handler = self.requestHandlers[".__pending__"] {
                            self.requestHandlers[key] = handler
                        }
                    }
                }
            }
            return JSValue(object: true, in: ctx)!
        }
        ctx.setObject(JSValue(object: sendFn, in: ctx), forKeyedSubscript: "send" as NSString)

        // setTimeout / clearTimeout
        let setTimerFn: @convention(block) (JSValue?, NSNumber?) -> NSNumber = { [weak self] fn, delay in
            guard let self else { return 0 }
            self.timerCounter += 1
            let id = self.timerCounter
            let work = DispatchWorkItem {
                self.queue.async {
                    fn?.call(withArguments: nil)
                    self.timers.removeValue(forKey: id)
                }
            }
            self.timers[id] = work
            let ms = delay.map { Double(truncating: $0) / 1000.0 } ?? 0
            self.queue.asyncAfter(deadline: .now() + ms, execute: work)
            return NSNumber(value: id)
        }
        ctx.setObject(JSValue(object: setTimerFn, in: ctx), forKeyedSubscript: "setTimeout" as NSString)

        let clearTimerFn: @convention(block) (NSNumber?) -> Void = { [weak self] num in
            guard let self, let num else { return }
            self.timers.removeValue(forKey: num.int32Value)?.cancel()
        }
        ctx.setObject(JSValue(object: clearTimerFn, in: ctx), forKeyedSubscript: "clearTimeout" as NSString)

        // atob / btoa
        let btoaFn: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        let atobFn: @convention(block) (String) -> String = {
            guard let d = Data(base64Encoded: $0) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        ctx.setObject(JSValue(object: btoaFn, in: ctx), forKeyedSubscript: "btoa" as NSString)
        ctx.setObject(JSValue(object: atobFn, in: ctx), forKeyedSubscript: "atob" as NSString)
    }

    /// 回调安全调用：统一切到 JS 队列执行。
    private func safeCall(_ callback: JSValue?, _ args: [Any]) {
        guard let callback else { return }
        queue.async { callback.call(withArguments: args) }
    }

    // MARK: - 脚本管理

    /// 加载单个音源脚本。重建 JSContext 后同步执行脚本；脚本里的 on/send
    /// 会在同一 queue 上排队执行，resolve 时也走 queue.sync，时序天然正确。
    func loadScript(_ raw: String, key: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.requestHandlers.removeAll()
                self.capabilities.removeAll()
                self.lastScriptError = nil
                self.installShim()
                self.context?.evaluateScript(raw)
                let plats = Array(self.capabilities.keys).sorted()
                self.lastDiagnostic = self.lastScriptError.map { "脚本异常: \($0)" }
                    ?? (plats.isEmpty ? "脚本未上报任何可用平台（缺少 send(inited)）"
                                      : "已加载，平台: \(plats.joined(separator: ","))")
                cont.resume()
            }
        }
    }

    static func parseMeta(_ raw: String, key: String) -> LXSourceMeta {
        func field(_ name: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: "@\(name)\\s+(.+)", options: []),
                  let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let r = Range(m.range(at: 1), in: raw) else { return "" }
            return String(raw[r]).trimmingCharacters(in: .whitespaces)
        }
        return LXSourceMeta(
            key: key,
            name: field("name"),
            author: field("author"),
            version: field("version"),
            description: field("description"),
            rawScript: raw
        )
    }

    /// 解析播放地址：遍历当前脚本上报的全部平台（kw/kg/tx/wy/mg...）逐一尝试，
    /// 返回第一个可用的 https 地址。
    func resolve(musicInfo: [String: Any], quality: String = "128k") async throws -> LXResolvedURL {
        let platforms = queue.sync { Array(capabilities.keys).sorted() }
        let hasFallback = queue.sync { requestHandlers[".__pending__"] != nil }
        guard !platforms.isEmpty || hasFallback else { throw LXSourceError.notInitialized }

        let candidates = platforms.isEmpty ? ["kw"] : platforms
        for platform in candidates {
            if let result = await resolveOne(platform: platform, musicInfo: musicInfo, quality: quality) {
                return result
            }
        }
        throw LXSourceError.noURL
    }

    /// 单平台解析。失败返回 nil，由调用方决定继续尝试下一个平台。
    private func resolveOne(platform: String, musicInfo: [String: Any], quality: String) async -> LXResolvedURL? {
        await withCheckedContinuation { (cont: CheckedContinuation<LXResolvedURL?, Never>) in
            queue.async {
                guard let ctx = self.context,
                      let handler = self.requestHandlers[platform] ?? self.requestHandlers[".__pending__"] else {
                    cont.resume(returning: nil)
                    return
                }
                let payload: [String: Any] = [
                    "source": platform,
                    "action": "musicUrl",
                    "info": ["type": quality, "musicInfo": musicInfo],
                ]
                guard let promise = handler.call(withArguments: [JSValue(object: payload, in: ctx)!]) else {
                    cont.resume(returning: nil)
                    return
                }
                var finished = false
                let finish: (LXResolvedURL?) -> Void = { result in
                    guard !finished else { return }
                    finished = true
                    cont.resume(returning: result)
                }

                let then = promise.objectForKeyedSubscript("then" as NSString)
                // Promise 的 then 是 JS 函数，作为 JSValue 时 isObject 为 true。
                if then != nil, then?.isNull != true, then?.isUndefined != true {
                    let onFulfilled: @convention(block) (JSValue?) -> Void = { [weak self] value in
                        guard let self else { return }
                        let text = value?.toString() ?? ""
                        self.queue.async {
                            guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
                                finish(nil)
                                return
                            }
                            finish(LXResolvedURL(url: url, sourceName: platform))
                        }
                    }
                    let onRejected: @convention(block) (JSValue?) -> Void = { [weak self] value in
                        let msg = value?.toString() ?? "未知错误"
                        self?.queue.async { self?.lastDiagnostic = "[\(platform)] \(msg)" }
                        finish(nil)
                    }
                    promise.invokeMethod("then", withArguments: [
                        JSValue(object: onFulfilled, in: ctx)!,
                        JSValue(object: onRejected, in: ctx)!,
                    ])
                    self.queue.asyncAfter(deadline: .now() + 20) { finish(nil) }
                } else {
                    let text = promise.toString() ?? ""
                    if let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
                        finish(LXResolvedURL(url: url, sourceName: platform))
                    } else {
                        finish(nil)
                    }
                }
            }
        }
    }

    func availableSources() -> [String] {
        queue.sync { Array(capabilities.keys).sorted() }
    }

    func diagnostic() -> String {
        queue.sync { lastDiagnostic }
    }
}

// MARK: - 便捷：Track -> 音源脚本 musicInfo

extension Track {
    /// 把 kumone 的统一 Track 转音源脚本期望的 musicInfo 字典。
    /// 各音源 idField 不同（id/hash/songmid/rid/mid），尽量都给上。
    var lxMusicInfo: [String: Any] {
        var info: [String: Any] = [
            "id": String(id),
            "songId": String(id),
            "songid": String(id),
            "name": name,
            "songname": name,
            "singer": artists.first?.name ?? "",
            "artist": artists.first?.name ?? "",
            "duration": durationMS,
        ]
        if let pic = album.picUrl { info["picUrl"] = pic }
        return info
    }
}
