import Foundation

// MARK: - SSE 流式 lesson 解析
/// Worker 以 OpenAI 兼容的 SSE 格式透传 Gemini 输出（data: {...} / data: [DONE]），
/// 每 chunk 的 content 拼起来是一个 JSON lesson。App 逐 chunk 累积，
/// 用 partialLesson 做渐进渲染（先出 reply_cantonese），最后用 finalLesson 完整解码。

/// SSE 单 chunk（OpenAI chat.completions 流式格式）
struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }
        let delta: Delta?
    }
    let choices: [Choice]?
}

enum LessonStreamParser {
    /// 从尚不完整的 JSON 缓冲中提取已闭合的 string 字段值；
    /// 字段值还没收齐（引号未闭合）时返回 nil。
    static func partialString(_ json: String, key: String) -> String? {
        guard let keyRange = json.range(of: "\"\(key)\"") else { return nil }
        var i = keyRange.upperBound
        // 跳过空白与冒号
        while i < json.endIndex {
            let c = json[i]
            if c == " " || c == "\n" || c == "\r" || c == "\t" || c == ":" {
                i = json.index(after: i)
            } else {
                break
            }
        }
        guard i < json.endIndex, json[i] == "\"" else { return nil }
        i = json.index(after: i)
        var out = ""
        out.reserveCapacity(256)
        var escaped = false
        while i < json.endIndex {
            let c = json[i]
            if escaped {
                // 保留常见转义的实际字符
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                return out  // 引号闭合，字段完整
            } else {
                out.append(c)
            }
            i = json.index(after: i)
        }
        return nil  // 流还没给完
    }

    /// 渐进渲染用的部分 lesson：只填已收齐的展示字段；
    /// reply_cantonese 为空时返回 nil（还不值得刷新 UI）。
    static func partialLesson(from buffer: String) -> Lesson? {
        let cantonese = partialString(buffer, key: "reply_cantonese") ?? ""
        guard !cantonese.isEmpty else { return nil }
        return Lesson(
            replyCantonese: cantonese,
            replyJyutping: partialString(buffer, key: "reply_jyutping") ?? "",
            replyEnglish: partialString(buffer, key: "reply_english") ?? ""
        )
    }

    /// 流结束后的完整解码：取首个 { 到最后的 }（与 Worker 端 extractJsonObject 同逻辑），
    /// snake_case 转驼峰；失败返回 nil。
    static func finalLesson(from buffer: String) -> Lesson? {
        guard let s = buffer.firstIndex(of: "{"),
              let e = buffer.lastIndex(of: "}"), e > s else { return nil }
        let slice = String(buffer[s...e])
        guard let data = slice.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Lesson.self, from: data)
    }
}
