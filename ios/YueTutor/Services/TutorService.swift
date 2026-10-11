import Foundation

// MARK: - 聊天轮次
/// 发给家教服务的历史上下文：role 取 "user" / "assistant"
struct ChatTurn: Codable {
    let role: String
    let text: String
}

// MARK: - 家教服务协议
/// 本地离线家教与代理后端家教都实现这个协议，ViewModel 只依赖协议
protocol TutorService {
    func sendChat(profile: TutorProfile, history: [ChatTurn], userText: String, useWebSearch: Bool) async throws -> Lesson
    /// 流式版本（协议方法，保证动态分发到 ProxyTutorService 的真流式实现；
    /// extension 只提供默认实现给本地服务）
    func sendChatStream(
        profile: TutorProfile,
        history: [ChatTurn],
        userText: String,
        useWebSearch: Bool,
        onPartial: @escaping @MainActor (Lesson) -> Void
    ) async throws -> Lesson
    /// 当前主题 id（本地服务维护，用于 UI 高亮当前话题；代理服务返回 nil）
    var currentTopicId: String? { get }
}

extension TutorService {
    /// 流式版本：默认实现 = 非流式跑完再回调一次（本地服务走这个，不用改）
    func sendChatStream(
        profile: TutorProfile,
        history: [ChatTurn],
        userText: String,
        useWebSearch: Bool,
        onPartial: @escaping @MainActor (Lesson) -> Void
    ) async throws -> Lesson {
        let lesson = try await sendChat(profile: profile, history: history, userText: userText, useWebSearch: useWebSearch)
        await onPartial(lesson)
        return lesson
    }
}
