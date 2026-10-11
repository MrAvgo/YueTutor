# 粤语陪练 YueTutor

「粤语陪练」是一款 iOS App，帮你开口说粤语、跟家教练口语。

- **Bundle ID**：`one.lxc.yuetutor`，显示名「粤语陪练」
- **v1 是纯离线版**：不依赖任何网络服务，打开就能练；AI 陪练功能以后再加
- **最低系统**：iOS 17.0，支持 iPhone 与 iPad

## 目录结构

```
ios-yuetutor/
├── ios/
│   ├── project.yml          # XcodeGen 工程配置（生成 YueTutor.xcodeproj）
│   └── YueTutor/            # App 源码
│       ├── Models/          # 数据模型
│       ├── Services/        # 语音识别、音频等服务
│       ├── Views/           # 界面
│       ├── ViewModels/      # 视图模型
│       ├── Resources/       # 资源，含 zh-Hans.lproj / en.lproj 双语本地化
│       └── Assets.xcassets/ # App 图标与主题色（工程配置自带）
├── server/                  # Node 代理后端（可选，v1 不用）
│   └── index.js
└── .github/workflows/ipa.yml  # CI：打 unsigned IPA
```

## v1 功能清单（纯离线）

- 麦克风录音 + 系统语音识别：开口说粤语，App 能听懂你说什么
- 本地口语练习流程：跟练、纠正、过关式练习（全部离线完成）
- 中英双语界面（简体中文 / English）
- 设置页预留「AI 陪练」入口：v1 该入口置灰不可用，留给以后启用 AI 功能

v1 不联网、不上传录音，所有处理都在本机完成。

## 本地后端 server/（可选）

`server/` 是一个 Node 代理服务，**v1 用不到**，是为以后启用 AI 陪练准备的：

- 把 Anthropic API key 藏在服务端，不直接出现在 App 客户端里
- 用 `APP_SECRET` 鉴权（App 通过 `x-app-secret` 请求头携带）
- 对外提供粤语家教对话接口（讲解、翻译、纠正一律简体中文；粤语用香港口语繁体字 + 数字调粤拼）
- 环境变量：`ANTHROPIC_API_KEY`、`APP_SECRET`（必填）、`TUTOR_MODEL`（默认 claude-sonnet-4-6）、`PORT`（默认 3000）

想提前了解后端用法，看 `server/index.js` 开头注释即可。

## 构建说明

**注意：iOS App 只能在 macOS 上编译，Linux 编不了。**

### 本地构建（需 macOS + Xcode）

```bash
brew install xcodegen
cd ios
xcodegen generate     # 生成 YueTutor.xcodeproj
open YueTutor.xcodeproj   # 用 Xcode 打开，真机调试
```

用 `xcodegen generate` 重新生成工程即可应用 `project.yml` 的修改。

### CI 打包（推荐）

推送到 GitHub 后，GitHub Actions（`.github/workflows/ipa.yml`）会在 macOS runner 上自动：

1. `xcodegen generate` 生成工程
2. `xcodebuild archive`（Release，unsigned）
3. 组装 `YueTutor-unsigned.ipa` 并上传为 artifact

unsigned 包没有签名，需要自签名或用侧载工具（如 AltStore / Sideloadly）安装到真机。

## 后续步骤

1. **自建 GitHub 仓库并推送**：用户在 GitHub 上新建仓库（是否公开待定），把本目录内容推送到 `main` 分支。
2. **跑 CI 验证编译**：push 后看 Actions 的 `Build YueTutor unsigned IPA` 是否成功——Linux 本机编不了 iOS，以 CI 结果为准。成功后在 artifact 里下载 `YueTutor-unsigned.ipa` 真机试装。
3. **以后想启用 AI 陪练**：
   1. 申请 Anthropic API key；
   2. 把 `server/` 部署到 Railway 等平台（配置 `ANTHROPIC_API_KEY` 和 `APP_SECRET` 环境变量）；
   3. 在 App 设置页填入代理 URL 和密钥，解开「AI 陪练」入口（v1 该入口置灰）。
