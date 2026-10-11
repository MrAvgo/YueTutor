import SwiftUI

/// 设置页：家教模式 / AI 陪练 / 语速 / 自动朗读 / 版本号。
/// AI 陪练：在下方填入云端陪练地址和密钥后，打开"AI 陪练"开关即启用；
/// 无网络或服务不可用时聊天自动回退本地模式，不会出现空白或报错。
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var profileStore: ProfileStore
    /// 课程重载后 +1，触发本页刷新（状态文案从 LocalTutorService.curriculumSource 实时读取）
    @State private var curriculumTick = 0
    /// 导出模板后的提示文案
    @State private var curriculumMessage: String?

    /// 当前课程状态文案
    private var curriculumStatusText: String {
        switch LocalTutorService.curriculumSource {
        case .builtIn:
            return String(format: L10n.t("settings.curriculum_status_builtin"), LocalTutorService.curriculum.count)
        case .customFile:
            return String(format: L10n.t("settings.curriculum_status_custom"), LocalTutorService.curriculum.count)
        case .invalidFile(_, let reason):
            return L10n.t("settings.curriculum_status_invalid") + "：" + reason
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                // 兴趣（多选）：16 个课程主题，不支持自定义输入
                Section(header: Text(L10n.t("settings.interests_section"))) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 8)], spacing: 8) {
                        ForEach(LocalTutorService.curriculum, id: \.id) { theme in
                            // 没勾选=全选：此时全部（含今日打卡特别主题）都显示为选中态
                            let selected = profileStore.profile.interests.isEmpty
                                || profileStore.profile.interests.contains(theme.titleZh)
                            Button {
                                toggleInterest(theme.titleZh)
                            } label: {
                                Text(theme.titleZh)
                                    .font(.subheadline)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .frame(maxWidth: .infinity)
                                    .background(selected ? Theme.accent : Theme.accent.opacity(0.12))
                                    .foregroundColor(selected ? .white : Theme.accent)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // 课程文件：外部 curriculum.json（"文件"App 的粤语陪练文件夹）
                Section(header: Text(L10n.t("settings.curriculum_section"))) {
                    Text(curriculumStatusText)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(L10n.t("settings.curriculum_hint"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button(L10n.t("settings.export_template")) {
                        do {
                            try CurriculumLoader.exportTemplate(LocalTutorService.builtInCurriculum)
                            curriculumMessage = String(
                                format: L10n.t("settings.export_done"),
                                CurriculumLoader.templateFileName
                            )
                        } catch {
                            curriculumMessage = L10n.t("settings.export_failed")
                        }
                    }
                    Button(L10n.t("settings.reload_curriculum")) {
                        LocalTutorService.reloadCurriculum()
                        curriculumMessage = nil
                        curriculumTick += 1
                    }
                    if let msg = curriculumMessage {
                        Text(msg)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                // 语音：语速 + 自动朗读
                Section(header: Text(L10n.t("settings.voice_section"))) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L10n.t("settings.speech_rate"))
                            Spacer()
                            Text(String(format: "%.2f", settings.speechRate))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $settings.speechRate, in: 0.3...0.7, step: 0.05)
                            .tint(Theme.accent)
                    }
                    Toggle(L10n.t("settings.auto_speak"), isOn: $settings.autoSpeak)
                        .tint(Theme.accent)
                }

                // AI 陪练：模式开关 + 云端代理地址 + 密钥
                Section(header: Text(L10n.t("settings.proxy_section"))) {
                    Toggle(L10n.t("settings.mode_proxy"), isOn: Binding(
                        get: { settings.tutorMode == .proxy },
                        set: { settings.tutorMode = $0 ? .proxy : .local }
                    ))
                    .tint(Theme.accent)
                    TextField(L10n.t("settings.proxy_url"), text: $settings.proxyBaseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField(L10n.t("settings.proxy_secret"), text: $settings.appSecret)
                    Text(L10n.t("settings.proxy_note"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // 按钮震动反馈：开关（打开时震一下确认）
                Section {
                    Toggle(L10n.t("settings.haptics"), isOn: Binding(
                        get: { settings.hapticsEnabled },
                        set: {
                            settings.hapticsEnabled = $0
                            playHaptic(settings)
                        }
                    ))
                    .tint(Theme.accent)
                }

                // 版本号
                Section {
                    Text(L10n.t("settings.version"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(L10n.t("settings.attribution"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle(L10n.t("settings.title"))
        }
    }

    // MARK: - 兴趣多选

    private func toggleInterest(_ title: String) {
        var current = profileStore.profile.interests
        if let index = current.firstIndex(of: title) {
            current.remove(at: index)
        } else {
            current.append(title)
        }
        profileStore.setInterests(current)
    }
}
