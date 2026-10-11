import Foundation

// MARK: - 代理请求体
struct ChatRequest: Codable {
    let profile: ProfilePayload
    let history: [ChatTurn]
    let userText: String
    let useWebSearch: Bool
    /// 为 true 时后端以 SSE 流式返回（新版 App 用；老版本不传，默认非流式）
    var stream: Bool = false
}

// MARK: - 档案载荷
struct ProfilePayload: Codable {
    let name: String
    let level: String
    let interests: [String]
    let tutorName: String
    let focus: String?
}

// MARK: - 代理家教服务（v1 暂不启用，保留给以后用）
/// 走后端 AI 陪练：proxy 未配置时抛 APIError.notConfigured
final class ProxyTutorService: TutorService {
    private let settings: AppSettings
    private let client: APIClient

    init(settings: AppSettings) {
        self.settings = settings
        self.client = APIClient(settings: settings)
    }

    func sendChat(profile: TutorProfile, history: [ChatTurn], userText: String, useWebSearch: Bool) async throws -> Lesson {
        guard settings.proxyConfigured else {
            throw APIError.notConfigured
        }
        let payload = ProfilePayload(
            name: profile.name,
            level: profile.level.rawValue,
            interests: profile.interests,
            tutorName: profile.tutorName,
            focus: profile.focus
        )
        let request = ChatRequest(profile: payload, history: history, userText: userText, useWebSearch: useWebSearch)
        return try await client.sendChat(request)
    }

    /// 代理模式不维护本地主题状态，返回 nil（话题 chip 不高亮）
    var currentTopicId: String? { nil }

    /// 流式：SSE 逐 chunk 回调（ViewModel 用来渐进刷新 pending 气泡）
    func sendChatStream(
        profile: TutorProfile,
        history: [ChatTurn],
        userText: String,
        useWebSearch: Bool,
        onPartial: @escaping @MainActor (Lesson) -> Void
    ) async throws -> Lesson {
        guard settings.proxyConfigured else {
            throw APIError.notConfigured
        }
        let payload = ProfilePayload(
            name: profile.name,
            level: profile.level.rawValue,
            interests: profile.interests,
            tutorName: profile.tutorName,
            focus: profile.focus
        )
        let request = ChatRequest(profile: payload, history: history, userText: userText, useWebSearch: useWebSearch)
        return try await client.sendChatStream(request, onPartial: onPartial)
    }
}
