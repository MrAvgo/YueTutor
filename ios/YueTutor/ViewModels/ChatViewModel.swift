import SwiftUI

/// 聊天状态管理：消息流 / 发送 / 朗读 / service 选择。
///
/// service 选择：`settings.tutorMode == .local` 用 `LocalTutorService()`，
/// 否则用 `ProxyTutorService(settings:)`；代理失败时静默回退本地，保证不断聊。
@MainActor
final class ChatViewModel: ObservableObject {
    /// 全部聊天消息（含思考中的 pending）。
    @Published var messages: [ChatMessage] = []
    /// 是否正在等待家教回复。
    @Published var isSending = false
    /// 当前主题 id（用于高亮顶部话题 chip），每次收到家教回复后更新。
    @Published var currentTopicId: String?
    /// 家教回复送达计数：pending 气泡是原地替换成正式内容的，`messages.count`
    /// 不变，只靠 count 观察不到送达；ChatView 观察它做滚动定位。
    @Published var tutorDeliveryNonce: Int = 0
    /// 最近一次送达的家教消息 id（滚动目标：滚到这条消息的顶部开始看）。
    private(set) var lastTutorMessageID: UUID?

    private var settings: AppSettings?
    private var profileStore: ProfileStore?
    private var synthesizer: SpeechSynthesizer?
    private var didStart = false
    /// 缓存的 service 实例：LocalTutorService 在内部维护跟读计数、待跟读句、
    /// 失败跳过等会话状态，必须复用同一实例；每次新建会导致状态丢失（永远"第 1 遍"）。
    private var cachedService: (any TutorService)?
    private var cachedServiceMode: TutorMode?
    /// 代理失败时的回退实例：单独长驻复用，保证 LocalTutorService 的会话状态连续。
    private let fallbackLocalService = LocalTutorService()

    // MARK: - 配置

    /// 由 `ChatView.onAppear` 调用，注入依赖。
    func configure(settings: AppSettings, profileStore: ProfileStore, synthesizer: SpeechSynthesizer) {
        self.settings = settings
        self.profileStore = profileStore
        self.synthesizer = synthesizer
    }

    /// 是否已经开场（发过首条请求）。
    var hasStarted: Bool { didStart }

    // MARK: - 开场

    /// 首次进入时调一次：用空消息向 service 要开场白（不显示用户气泡）。
    func startIfNeeded() {
        guard !didStart else { return }
        guard settings != nil, profileStore != nil else { return }
        didStart = true
        Task { await requestReply(userText: "", history: []) }
    }

    // MARK: - 发送

    /// 发送学习者消息。
    func sendLearner(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        guard settings != nil, profileStore != nil else { return }
        let history = recentHistory()
        messages.append(.learner(trimmed))
        Task { await requestReply(userText: trimmed, history: history) }
    }

    /// 切换话题：把主题名作为用户消息发送。
    func switchTopic(_ topic: String) {
        sendLearner(topic)
    }

    /// 发送"考考我"，让家教出题考学习者。
    func askForQuiz() {
        // 发给 service 的是固定中文指令；按钮上的显示文字走 L10n 本地化。
        sendLearner("考考我")
    }

    /// 重试上一次失败的发送：清掉失败的 pending，重发最后一条学习者消息。
    func retryFailed() {
        guard !isSending else { return }
        guard let lastText = messages.last(where: { $0.role == .learner && !$0.isPending })?.text,
              !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.removeAll(where: { $0.isPending })
        sendLearner(lastText)
    }

    // MARK: - 朗读

    /// 按设置语速朗读指定文本。
    func speak(_ text: String) {
        synthesizer?.speak(text, rate: settings?.speechRate ?? 0.5)
    }

    /// 停止朗读。
    func stopSpeaking() {
        synthesizer?.stop()
    }

    // MARK: - 内部

    /// 按设置选择 service。实例按 tutorMode 缓存复用（切换模式时重建），
    /// 保证 LocalTutorService 的会话状态（跟读计数等）在多轮对话间连续。
    private func makeService() -> (any TutorService)? {
        guard let settings else { return nil }
        if let cached = cachedService, cachedServiceMode == settings.tutorMode {
            return cached
        }
        let service: any TutorService
        if settings.tutorMode == .local {
            service = LocalTutorService()
        } else {
            service = ProxyTutorService(settings: settings)
        }
        cachedService = service
        cachedServiceMode = settings.tutorMode
        return service
    }

    /// 最近 20 条有效消息转 `[ChatTurn]`（去掉思考中的 pending；role 用
    /// LLM 通用的 "user" / "assistant"，与服务端 buildMessages 的归一化保持一致）。
    private func recentHistory() -> [ChatTurn] {
        messages.suffix(20).compactMap { message in
            guard !message.isPending else { return nil }
            switch message.role {
            case .learner:
                guard let text = message.text, !text.isEmpty else { return nil }
                return ChatTurn(role: "user", text: text)
            case .tutor:
                let text = message.lesson?.replyCantonese ?? message.text ?? ""
                guard !text.isEmpty else { return nil }
                return ChatTurn(role: "assistant", text: text)
            }
        }
    }

    /// 向 service 请求回复：先挂 pending 气泡，成功替换为家教卡片，失败标 errorText。
    private func requestReply(userText: String, history: [ChatTurn]) async {
        guard let settings, let profileStore, let service = makeService() else { return }
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }

        let pending = ChatMessage.pendingTutor()
        messages.append(pending)
        let pendingID = pending.id

        do {
            // 流式：先出首字（2-3 秒），边收边刷新 pending 气泡
            let lesson = try await service.sendChatStream(
                profile: profileStore.profile,
                history: history,
                userText: userText,
                useWebSearch: false
            ) { [weak self] partial in
                self?.refreshPending(pendingID: pendingID, lesson: partial)
            }
            deliver(lesson, pendingID: pendingID, topicId: service.currentTopicId, settings: settings)
        } catch {
            // 代理后端不可用（断网/未配置/密钥缺失/模型报错）时静默回退本地，
            // 保证不出现空白或报错界面；本地也失败才显示错误。
            if service is ProxyTutorService {
                do {
                    let lesson = try await fallbackLocalService.sendChat(
                        profile: profileStore.profile,
                        history: history,
                        userText: userText,
                        useWebSearch: false
                    )
                    deliver(lesson, pendingID: pendingID, topicId: fallbackLocalService.currentTopicId, settings: settings)
                } catch {
                    showError(pendingID: pendingID)
                }
            } else {
                showError(pendingID: pendingID)
            }
        }
    }

    /// 流式刷新 pending 气泡：只换内容，不触发滚动锚点（避免流式中途乱跳）
    /// 同时 bump streamFollowNonce，让 View 把气泡底部跟入视野（新字始终可见）
    /// 关键：必须保留原 pendingID！ChatMessage.tutor() 会生成新 UUID，
    /// 若换了 id，后续 deliver 按 pendingID 就找不到了（2026-10-11 实锤教训）。
    private func refreshPending(pendingID: UUID, lesson: Lesson) {
        if let index = messages.firstIndex(where: { $0.id == pendingID }) {
            messages[index] = ChatMessage(
                id: pendingID, role: .tutor, text: nil,
                lesson: lesson, isPending: false, errorText: nil
            )
            streamFollowID = pendingID
            streamFollowNonce += 1
        }
    }

    /// 流式跟随滚动状态：View 据此决定是否把生长中的气泡底部滚入视野
    /// 注意必须 @Published，否则 View 的 onChange 收不到（2026-10-11 实锤教训）
    @Published var streamFollowNonce = 0
    @Published var streamFollowID: UUID?

    /// 把家教回复送达：替换 pending 气泡、更新滚动锚点、按设置朗读。
    private func deliver(_ lesson: Lesson, pendingID: UUID, topicId: String?, settings: AppSettings) {
        // 流式跟随到此结束，后续由"送达到位"滚动（消息顶部定位）接管
        streamFollowID = nil
        if let index = messages.firstIndex(where: { $0.id == pendingID }) {
            // 保留 pendingID（同 refreshPending 的教训），避免行身份抖动
            let delivered = ChatMessage(
                id: pendingID, role: .tutor, text: nil,
                lesson: lesson, isPending: false, errorText: nil
            )
            messages[index] = delivered
            // 触发"送达到位"滚动：定位到这条新消息的顶部
            lastTutorMessageID = delivered.id
            tutorDeliveryNonce += 1
        }
        currentTopicId = topicId
        if settings.autoSpeak {
            synthesizer?.speak(lesson.replyCantonese, rate: settings.speechRate)
        }
    }

    /// 发送失败时在 pending 气泡上标错误（可点重试）。
    private func showError(pendingID: UUID) {
        if let index = messages.firstIndex(where: { $0.id == pendingID }) {
            messages[index].errorText = L10n.t("error.chat_failed")
            lastTutorMessageID = messages[index].id
            tutorDeliveryNonce += 1
        }
    }
}
