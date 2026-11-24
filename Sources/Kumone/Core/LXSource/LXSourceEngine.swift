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
//   - md5 / aes / rsa（脚本可选使用）
//
// 解析流程：Swift 调用 `resolve(sourceID:musicInfo:quality:)`，引擎构造
//   { source, action:'musicUrl', info:{ type, musicInfo } }
// 交给脚本的 request handler，Promise resolve 出 https 播放地址。

/// 一个已导入的音源脚本的元信息（来自文件头注释 @name/@version 等）。
struct LXSourceMeta: Codable, Hashable, Identifiable {
    var id: String { key }
    let key: String          // 文件名主干，如 "xinghai"
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

/// 线程约束：JSContext 不是线程安全的，所有脚本执行与 request handler 调用
/// 都串行跑到同一队列。解析接口用 async 桥接回调用方。
final class LXSourceEngine {

    static let shared = LXSourceEngine()

    private let log = Logger(subsystem: "sb.moe.kumone", category: "lx-source")
    private let queue = DispatchQueue(label: "sb.moe.kumone.lxsource", qos: .userInitiated)
    private let context = JSContext()
    private let session: URLSession

    /// 已注册脚本的 request handler（key = source id）。
    private var requestHandlers: [String: JSValue] = [:]
    /// 脚本上报的能力：source -> [actions]。
    private var capabilities: [String: [String]] = [:]
    /// native setTimeout 计时器，防止被 GC。
    private var timers: [Int32: DispatchWorkItem] = [:]
    private var timerCounter: Int32 = 0
    /// 等待 inited 的连续请求 id。
    private var initWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var initWaiterCounter = 0
    private var didInit = false

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15"
        ]
        self.session = URLSession(configuration: cfg)
        installShim()
    }

    // MARK: - 宿主 shim

    private func installShim() {
        context?.exceptionHandler = { [weak self] ctx, value in
            let msg = value?.toString() ?? "unknown JS exception"
            self?.log.error("JS exception: \(msg, privacy: .public)")
        }

        // console
        let console = JSValue(newObjectIn: context)!
        for level in ["log", "warn", "error", "info"] {
            console.setObject(JSValue(object: { (args: [Any]) in
                let text = args.map { "\($0)" }.joined(separator: " ")
                NSLog("[LX:\(level)] %@", text)
            }, in: context)!, forKey: level)
        }
        context?.setObject(console, forKeyedSubscript: "console" as NSCopying)

        // EVENT_NAMES
        let events = JSValue(newObjectIn: context)!
        events.setObject("request", forKeyedSubscript: "request" as NSCopying)
        events.setObject("inited", forKeyedSubscript: "inited" as NSCopying)
        events.setObject("updateAlert", forKeyedSubscript: "updateAlert" as NSCopying)
        context?.setObject(events, forKeyedSubscript: "EVENT_NAMES" as NSCopying)

        // request(url, options, callback) -> URLSession
        let requestFn: @convention(block) (String, JSValue?, JSValue?) -> JSValue = { [weak self] urlString, optionsValue, callback in
            guard let self else { return JSValue(undefinedIn: self.context) }
            let abort = JSValue(newObjectIn: self.context)!
            var aborted = false
            abort.setObject(JSValue(object: { () in aborted = true }, in: self.context)!,
                            forKeyedSubscript: "abort" as NSCopying)
            guard let url = URL(string: urlString) else {
                self.safeCall(callback, with: ["网络地址错误", NSNull()])
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
                        self.safeCall(callback, with: [error.localizedDescription, NSNull()])
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
                    self.safeCall(callback, with: [NSNull(), resp])
                }
            }
            task.resume()
            abort.setObject(JSValue(object: { () in aborted = true; task.cancel() }, in: self.context)!,
                            forKeyedSubscript: "abort" as NSCopying)
            return abort
        }
        context?.setObject(JSValue(object: requestFn, in: context)!,
                           forKeyedSubscript: "request" as NSCopying)

        // on(event, handler)
        let onFn: @convention(block) (String, JSValue?) -> JSValue = { [weak self] event, handler in
            guard let self, let ctx = self.context else { return JSValue(undefinedIn: self?.context) }
            if event == "request", let handler {
                self.queue.async { self.requestHandlers["__pending__"] = handler }
            }
            return JSValue(object: true, in: ctx)!
        }
        context?.setObject(JSValue(object: onFn, in: context)!,
                           forKeyedSubscript: "on" as NSCopying)

        // send(event, data)
        let sendFn: @convention(block) (String, JSValue?) -> JSValue = { [weak self] event, data in
            guard let self, let ctx = self.context else { return JSValue(undefinedIn: self?.context) }
            if event == "inited" {
                let info = data?.toDictionary() ?? [:]
                self.queue.async {
                    if let sources = info["sources"] as? [String: Any] {
                        for (key, value) in sources {
                            if let s = value as? [String: Any], let actions = s["actions"] as? [String] {
                                self.capabilities[key] = actions
                                if let handler = self.requestHandlers["__pending__"] {
                                    self.requestHandlers[key] = handler
                                }
                            }
                        }
                    }
                    self.didInit = true
                    for waiter in self.initWaiters.values { waiter.resume() }
                    self.initWaiters.removeAll()
                }
            }
            return JSValue(object: true, in: ctx)!
        }
        context?.setObject(JSValue(object: sendFn, in: context)!,
                           forKeyedSubscript: "send" as NSCopying)

        // setTimeout / clearTimeout
        let setTimerFn: @convention(block) (JSValue?, NSNumber?) -> NSNumber = { [weak self] fn, delay in
            guard let self else { return 0 }
            self.timerCounter += 1
            let id = self.timerCounter
            let work = DispatchWorkItem {
                self.queue.async {
                    if let fn, fn.isObject { fn.call(withArguments: nil) }
                    self.timers.removeValue(forKey: id)
                }
            }
            self.timers[id] = work
            let ms = delay.map { Double(truncating: $0) / 1000.0 } ?? 0
            self.queue.asyncAfter(deadline: .now() + ms, execute: work)
            return NSNumber(value: id)
        }
        context?.setObject(JSValue(object: setTimerFn, in: context)!,
                           forKeyedSubscript: "setTimeout" as NSCopying)
        let clearTimerFn: @convention(block) (NSNumber?) -> Void = { [weak self] num in
            guard let self, let num else { return }
            let id = num.int32Value
            self.queue.async { self.timers.removeValue(forKey: id)?.cancel() }
        }
        context?.setObject(JSValue(object: clearTimerFn, in: context)!,
                           forKeyedSubscript: "clearTimeout" as NSCopying)

        // atob / btoa
        let btoaFn: @convention(block) (String) -> String = { text in
            Data(text.utf8).base64EncodedString()
        }
        let atobFn: @convention(block) (String) -> String = { text in
            guard let data = Data(base64Encoded: text) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        context?.setObject(JSValue(object: btoaFn, in: context)!,
                           forKeyedSubscript: "btoa" as NSCopying)
        context?.setObject(JSValue(object: atobFn, in: context)!,
                           forKeyedSubscript: "atob" as NSCopying)

        // Math.random 已有；Date.now 由 JSCore 原生提供。
    }

    /// 回调安全调用：切回 JS 队列再把 [error, data] 作为参数调用。
    private func safeCall(_ callback: JSValue?, with args: [Any]) {
        guard let callback else { return }
        if DispatchQueue.currentLabel == self.queue.label {
            callback.call(withArguments: args)
        } else {
            self.queue.async { callback.call(withArguments: args) }
        }
    }

    // MARK: - 脚本管理

    /// 加载单个音源脚本。脚本头注释里的 @name/@version 等会被解析为元信息。
    func loadScript(_ raw: String, key: String) async throws -> LXSourceMeta {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.didInit = false
                self.requestHandlers.removeAll()
                self.capabilities.removeAll()
                self.context?.evaluateScript(raw)
                // 脚本同步执行后应调用 send('inited', ...) 或注册 on('request')。
                // 部分脚本 send 是异步 resolve，这里给一个短等待窗口。
                self.waitForInit { cont.resume() }
            }
        }
        return parseMeta(raw, key: key)
    }

    /// 等待最多 1.5 秒的 inited；超时也放行（老脚本可能不 send inited，只 on request）。
    private func waitForInit(completion: @escaping () -> Void) {
        if didInit || !requestHandlers.isEmpty { completion(); return }
        initWaiterCounter += 1
        let id = initWaiterCounter
        initWaiters[id] = CheckedContinuation<Void, Never> {
            completion()
        }()
        // 兜底超时
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let waiter = self.initWaiters.removeValue(forKey: id) else { return }
            waiter.resume()
        }
    }

    private func parseMeta(_ raw: String, key: String) -> LXSourceMeta {
        func field(_ name: String) -> String {
            let pattern = "@\(name)\\s+(.+)"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw) else { return "" }
            return String(raw[range]).trimmingCharacters(in: .whitespaces)
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

    /// 解析播放地址。musicInfo 至少包含 id / name；不同音源需要的字段不同，
    /// 调用方应尽量把 Track 的完整字段塞进去（参见 Track.lxMusicInfo）。
    func resolve(source: String, musicInfo: [String: Any], quality: String = "128k") async throws -> LXResolvedURL {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let handler = self.requestHandlers[source] ?? self.requestHandlers["__pending__"] else {
                    cont.resume(throwing: LXSourceError.notInitialized)
                    return
                }
                let payload: [String: Any] = [
                    "source": source,
                    "action": "musicUrl",
                    "info": [
                        "type": quality,
                        "musicInfo": musicInfo,
                    ],
                ]
                let arg = JSValue(object: payload, in: self.context)!
                guard let promise = handler.call(withArguments: [arg]) else {
                    cont.resume(throwing: LXSourceError.scriptFailed("handler 未返回 Promise"))
                    return
                }
                // 兼容两种返回：Promise 或直接的 thenable
                let then = promise.objectForKeyedSubscript("then")
                if then?.isObject == true || then?.isCallable == true {
                    let onFulfilled: @convention(block) (JSValue?) -> Void = { [weak self] value in
                        guard let self else { return }
                        let text = value?.toString() ?? ""
                        self.queue.async {
                            guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else {
                                cont.resume(throwing: LXSourceError.invalidURL(text))
                                return
                            }
                            cont.resume(returning: LXResolvedURL(url: url, sourceName: source))
                        }
                    }
                    let onRejected: @convention(block) (JSValue?) -> Void = { [weak self] value in
                        guard let self else { return }
                        let msg = value?.toString() ?? "unknown"
                        self.queue.async { cont.resume(throwing: LXSourceError.scriptFailed(msg)) }
                    }
                    promise.invokeMethod("then", withArguments: [
                        JSValue(object: onFulfilled, in: self.context)!,
                        JSValue(object: onRejected, in: self.context)!,
                    ])
                } else {
                    let text = promise.toString() ?? ""
                    if let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
                        cont.resume(returning: LXResolvedURL(url: url, sourceName: source))
                    } else {
                        cont.resume(throwing: LXSourceError.invalidURL(text))
                    }
                }
            }
        }
    }

    func availableSources() -> [String] {
        queue.sync { Array(capabilities.keys).sorted() }
    }
}

// MARK: - 便捷：Track -> 音源脚本 musicInfo

extension Track {
    /// 把 kumone 的统一 Track 转音源脚本期望的 musicInfo 字典。
    /// 各音源 idField 不同（id / hash / songmid / rid / mid），尽量都给上。
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
