import Foundation

// MARK: - 代理请求错误（全部简体中文描述）
enum APIError: LocalizedError {
    case notConfigured   // 代理地址未配置
    case badURL          // 代理地址格式错误
    case server(String)  // 后端返回错误信息
    case decoding        // 返回数据无法解析

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "代理服务未配置：请先在设置里填写代理地址（Proxy Base URL）。"
        case .badURL:
            return "代理地址格式不正确，请检查设置里的 Proxy Base URL（需以 http:// 或 https:// 开头）。"
        case .server(let message):
            return "服务器返回错误：\(message)"
        case .decoding:
            return "服务器返回的数据格式无法解析，请稍后重试。"
        }
    }
}

// MARK: - 代理 API 客户端
/// POST {proxyBaseURL}/cantonese/chat，header 带 x-app-secret；
/// 后端返回 {ok, lesson, error}（LessonResponse），解码用 convertFromSnakeCase
final class APIClient {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func sendChat(_ request: ChatRequest) async throws -> Lesson {
        // 1. 拼 URL：去掉 base 尾部多余的 /，再接路径
        let base = settings.proxyBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !base.isEmpty else { throw APIError.notConfigured }
        guard let url = URL(string: base + "/cantonese/chat"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw APIError.badURL
        }

        // 2. 组装请求
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 60
        if !settings.appSecret.isEmpty {
            urlRequest.setValue(settings.appSecret, forHTTPHeaderField: "x-app-secret")
        }
        urlRequest.httpBody = try JSONEncoder().encode(request)

        // 3. 发请求
        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        // 4. 非 2xx：尽量带上后端给的错误信息
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let backendMessage = (try? decoder.decode(LessonResponse.self, from: data))?.error
            if let backendMessage, !backendMessage.isEmpty {
                throw APIError.server(backendMessage)
            }
            throw APIError.server("HTTP 状态码 \(http.statusCode)")
        }

        // 5. 解析返回体
        guard let lessonResponse = try? decoder.decode(LessonResponse.self, from: data) else {
            throw APIError.decoding
        }
        if lessonResponse.ok, let lesson = lessonResponse.lesson {
            return lesson
        }
        if let error = lessonResponse.error, !error.isEmpty {
            throw APIError.server(error)
        }
        throw APIError.decoding
    }

    // MARK: - 流式请求（SSE）
    /// POST {proxyBaseURL}/cantonese/chat（body 带 stream:true），后端以
    /// text/event-stream 透传模型输出；每收到一个 content chunk 就拼 buffer，
    /// 用 LessonStreamParser 做渐进渲染回调；流结束做完整解码。
    /// 中途断流：已有内容则按原文兜底，无内容则按 decoding 错处理。
    func sendChatStream(_ request: ChatRequest, onPartial: @escaping @MainActor (Lesson) -> Void) async throws -> Lesson {
        // 1. 拼 URL（与 sendChat 同逻辑）
        let base = settings.proxyBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard !base.isEmpty else { throw APIError.notConfigured }
        guard let url = URL(string: base + "/cantonese/chat"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw APIError.badURL
        }

        // 2. 组装请求（stream:true）
        var streamRequest = request
        streamRequest.stream = true
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 60
        if !settings.appSecret.isEmpty {
            urlRequest.setValue(settings.appSecret, forHTTPHeaderField: "x-app-secret")
        }
        urlRequest.httpBody = try JSONEncoder().encode(streamRequest)

        // 3. 读 SSE 流
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw APIError.decoding }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if !(200..<300).contains(http.statusCode) {
            // 错误也是 JSON 体（{ok:false,error}），尽量读出来
            var errData = Data()
            for try await b in bytes { errData.append(b) }
            let decoder = JSONDecoder()
            if let msg = (try? decoder.decode(LessonResponse.self, from: errData))?.error, !msg.isEmpty {
                throw APIError.server(msg)
            }
            throw APIError.server("HTTP 状态码 \(http.statusCode)")
        }
        if !contentType.contains("text/event-stream") {
            // 老版本 Worker（不支持流式）：按普通 JSON 体解析
            var data = Data()
            for try await b in bytes { data.append(b) }
            return try Self.decodeLessonResponse(data)
        }

        var buffer = ""
        buffer.reserveCapacity(4096)
        var gotAnyContent = false
        for try await line in bytes.lines {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix("data:") else { continue }
            let payload = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                  let delta = chunk.choices?.first?.delta?.content,
                  !delta.isEmpty else { continue }
            buffer += delta
            gotAnyContent = true
            if let partial = LessonStreamParser.partialLesson(from: buffer) {
                await onPartial(partial)
            }
        }

        // 4. 流结束：完整解码
        if let lesson = LessonStreamParser.finalLesson(from: buffer) {
            return lesson
        }
        // 有内容但 JSON 解坏了：把原文当粤语回复兜底（与 Worker 端 fallbackLesson 同口径）
        if gotAnyContent {
            return Lesson(
                replyCantonese: String(buffer.prefix(2000)),
                replyJyutping: "",
                replyEnglish: "（模型返回格式异常，以下为原文）"
            )
        }
        throw APIError.decoding
    }

    /// 老协议 JSON 体解码（{ok, lesson, error}），供流式降级路径复用
    private static func decodeLessonResponse(_ data: Data) throws -> Lesson {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let lessonResponse = try? decoder.decode(LessonResponse.self, from: data) else {
            throw APIError.decoding
        }
        if lessonResponse.ok, let lesson = lessonResponse.lesson {
            return lesson
        }
        if let error = lessonResponse.error, !error.isEmpty {
            throw APIError.server(error)
        }
        throw APIError.decoding
    }
}
