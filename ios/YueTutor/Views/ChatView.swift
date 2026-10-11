import SwiftUI

/// 聊天页：顶栏（家教名）+ 话题 chips + 消息流 + 底部输入条。
struct ChatView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var synthesizer: SpeechSynthesizer

    @StateObject private var viewModel = ChatViewModel()
    @StateObject private var recognizer = SpeechRecognizer()
    @State private var inputText = ""
    /// 是否显示"跳到底部"悬浮按钮：底部锚点滚出可视区时显示
    @State private var showJumpToBottom = false
    /// 点悬浮按钮时 +1，消息列表内响应并瞬间滚到底部
    @State private var jumpToBottomNonce = 0
    /// 流式跟随：家教回复生长中是否自动把气泡底部滚入视野。
    /// 新一轮对话开始时为 true；用户手动拖动后为 false（不再打扰看历史）；
    /// 点"跳到底部"后恢复 true；送达后由"顶部定位"接管，置 false。
    @State private var followStream = true
    /// 外部课程重载后 +1，触发 topics 重算（实际从 LocalTutorService.curriculum 实时读取）
    @State private var curriculumReloadTick = 0

    /// 顶部话题 chips：设置页勾了兴趣主题就只显示勾选的；没勾则显示全部。
    /// 当前主题始终显示（即使不在勾选的兴趣里），插到最前面。
    /// profileStore.profile.interests / viewModel.currentTopicId 变化时自动刷新。
    private var topics: [CourseTheme] {
        let interests = profileStore.profile.interests
        guard !interests.isEmpty else { return LocalTutorService.curriculum }
        var filtered = LocalTutorService.curriculum.filter { interests.contains($0.titleZh) }
        if let currentId = viewModel.currentTopicId,
           !filtered.contains(where: { $0.id == currentId }),
           let current = LocalTutorService.curriculum.first(where: { $0.id == currentId }) {
            filtered.insert(current, at: 0)
        }
        return filtered.isEmpty ? LocalTutorService.curriculum : filtered
    }

    var body: some View {
        VStack(spacing: 0) {
            topicChips
            Divider()
            messageList
            if let recognitionError = recognizer.errorMessage, !recognizer.isRecording {
                Text(recognitionError)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
            InputBar(
                text: $inputText,
                isRecording: recognizer.isRecording,
                isSending: viewModel.isSending,
                onMic: { recognizer.toggle() },
                onSend: sendInput
            )
        }
        .onAppear {
            viewModel.configure(settings: settings, profileStore: profileStore, synthesizer: synthesizer)
            viewModel.startIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .curriculumDidReload)) { _ in
            // 外部课程重载后刷新顶部主题 chips（topics 从 LocalTutorService.curriculum 实时读取）
            curriculumReloadTick += 1
        }
        .onChange(of: recognizer.transcript) { _, transcript in
            // 录音过程中把识别结果实时填入输入框
            if recognizer.isRecording {
                inputText = transcript
            }
        }
    }

    // MARK: - 话题 chips

    private var topicChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollViewReader { chipProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(topics, id: \.id) { theme in
                            let isCurrent = theme.id == viewModel.currentTopicId
                            Button {
                                playHaptic(settings)
                                viewModel.switchTopic(theme.titleZh)
                            } label: {
                                Text(theme.titleZh)
                                    .font(.system(size: 17))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(isCurrent ? Theme.accent : Theme.accent.opacity(0.10))
                                    .foregroundColor(isCurrent ? .white : Theme.accent)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isSending)
                            .id(theme.id)
                        }
                    Button {
                        playHaptic(settings)
                        viewModel.askForQuiz()
                    } label: {
                        Text(L10n.t("chat.quiz"))
                            .font(.system(size: 17))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.accent.opacity(0.10))
                            .foregroundColor(Theme.accent)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule()
                                    .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isSending)
                }
                .padding(.horizontal)
            }
            // 当前主题变化时，把对应的 chip 滚到可视区（16 个主题横向排布，
            // 打字/"换个主题"切换后高亮的 chip 可能在屏幕外）
            .onChange(of: viewModel.currentTopicId) { _, newId in
                guard let newId else { return }
                withAnimation {
                    chipProxy.scrollTo(newId, anchor: .center)
                }
            }
        }
        .padding(.vertical, 8)
    }
    }

    // MARK: - 消息列表

    /// 键盘收起灵敏度：手指在消息列表上拖动超过该距离（pt）即收键盘。
    /// 0 ≈ .immediately（一碰就收）；越大越不灵敏。20 是中间值。
    private let keyboardDismissDragThreshold: CGFloat = 20

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        messageRow(message)
                            .id(message.id)
                    }
                    // 底部锚点：学习者发消息时滚到底部；
                    // 用它的 appear/disappear 判断用户是否偏离底部，控制悬浮按钮显隐
                    Color.clear
                        .frame(height: 1)
                        .id("bottomAnchor")
                        .onAppear { showJumpToBottom = false }
                        .onDisappear { showJumpToBottom = true }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.never)
            .overlay(alignment: .bottom) {
                if showJumpToBottom {
                    Button {
                        playHaptic(settings)
                        jumpToBottomNonce += 1
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Theme.accent)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .padding(.bottom, 16)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("跳到底部")
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showJumpToBottom)
            .simultaneousGesture(
                DragGesture(minimumDistance: keyboardDismissDragThreshold)
                    .onChanged { _ in
                        dismissKeyboard()
                        // 用户手动拖动：接管滚动，流式不再自动跟随
                        followStream = false
                    }
            )
            // 学习者发消息（count 增加）：瞬间滚到底部，即时反馈。
            // 注意不用 withAnimation：动画没跑完时若家教回复送达，
            // 两处滚动会打架把视图停在半中间；全用瞬间定位，位置是确定的。
            .onChange(of: viewModel.messages.count) { _, _ in
                followStream = true
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
            // 悬浮按钮点按：瞬间跳到底部（无动画，与消息定位逻辑一致，避免打架）
            .onChange(of: jumpToBottomNonce) { _, _ in
                followStream = true
                proxy.scrollTo("bottomAnchor", anchor: .bottom)
            }
            // 流式生长：气泡变高时把底部滚入视野，新字始终可见。
            // 用户手动拖动后 followStream=false，不打扰看历史；瞬间定位，与现有逻辑一致。
            .onChange(of: viewModel.streamFollowNonce) { _, _ in
                guard followStream, let id = viewModel.streamFollowID else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            // 家教回复送达（pending 原地替换为正式内容）：新消息从顶部开始显示。
            // 两点教训：① 必须等 LazyVStack 量好新内容高度后再定位，否则停半中间——
            // async 一轮不够（16 张主题卡片量高度需要时间），等 0.25s；
            // ② 定位不要做动画：内容高度变化时动画滚动会插值漂移，直接瞬间定位最准。
            .onChange(of: viewModel.tutorDeliveryNonce) { _, _ in
                // 送达后由"顶部定位"接管，流式跟随到此结束
                followStream = false
                guard let id = viewModel.lastTutorMessageID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
    }

    /// 单条消息行：学习者右气泡，家教用卡片 / 思考中 / 失败提示。
    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.role {
        case .learner:
            HStack {
                Spacer(minLength: 48)
                Text(message.text ?? "")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Theme.accent)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            }
        case .tutor:
            // 家教卡片：左侧顶格、右侧留 24pt——对话框的样子，不顶满全宽；
            // 学习者气泡仍保持右侧 48pt 收敛。
            HStack {
                if message.isPending {
                    pendingBubble(message)
                } else if let lesson = message.lesson {
                    MessageBubbleView(
                        lesson: lesson,
                        onSpeak: { viewModel.speak($0) },
                        onSuggestedReply: { viewModel.sendLearner($0) }
                    )
                }
                Spacer(minLength: 24)
            }
        }
    }

    /// 思考中气泡：转圈；失败时显示错误文案，点击重试。
    @ViewBuilder
    private func pendingBubble(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorText = message.errorText {
                Button {
                    viewModel.retryFailed()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundColor(.red)
                        Text(L10n.t("chat.error_retry"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
                    .tint(Theme.accent)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    // MARK: - 发送

    private func sendInput() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if recognizer.isRecording {
            recognizer.stop()
        }
        viewModel.sendLearner(text)
        inputText = ""
    }
}
