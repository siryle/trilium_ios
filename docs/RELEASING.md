# TriliumPocket 构建与发布

TriliumPocket 是面向 iPhone 的原生 SwiftUI 应用，最低支持 iOS 17。所有编译、XCTest、归档和 IPA 打包都在 GitHub Actions 完成。无需在本地构建，无需安装任何依赖；工作流使用 GitHub 托管 runner 已安装的 Xcode、Python、GitHub CLI 和系统工具。

## 首次接入 GitHub

当前工作目录来自 Gitea，目前未配置 GitHub remote。Gitea 不会执行 GitHub Actions；必须先将仓库内容同步到 GitHub 才能使用 `.github/workflows/ios-release.yml`。本地代码提交不会自动添加 GitHub remote 或推送；推送需要按照 AGENTS.md 获得用户确认。

1. 在 GitHub 创建一个仓库，并将当前代码（包含 `.github/workflows/ios-release.yml`）同步到它。可以保留 Gitea 作为 `origin`，另加名为 `github` 的 remote：`git remote add github https://github.com/<owner>/<repo>.git`。地址需要替换为实际仓库。
2. 将代码推送至 GitHub 的 `main` 分支：`git push github main`。之后每次从 Gitea 更新代码，也需要同步到 GitHub。
3. 在 GitHub 仓库 Settings → Actions → General 中启用 Actions，确保策略允许本工作流固定 SHA 的官方 `actions/checkout`、`actions/upload-artifact` 和 `actions/download-artifact`。若组织策略禁止写入 Releases，需要由仓库/组织管理员允许发布任务使用 `contents: write`。
4. 不需要 Apple Developer 证书、描述文件、签名 secrets 或额外第三方访问令牌。工作流默认仅授予 `contents: read`；发布 job 获得 `contents: write`，清理 job 获得 `actions: write` 和 `contents: write`，均使用各自 job 的 `GITHUB_TOKEN`。

## CI 与发布入口

- 向 `main` 推送：生成工程、执行 XCTest、归档，成功后自动打包未签名 IPA 并上传到 `build-<运行编号>-<12 位提交 SHA>` 预发布 Release。无需先创建版本标签，不会替换正式版本的 Latest 标记。
- 创建以 `main` 为目标的 Pull Request：只验证测试及归档，不发布 Release。
- 推送 `v*` 标签：验证标签后，对标签对应提交测试、归档并上传未签名 IPA 到同名正式 GitHub Release。
- 手动运行 Actions → iOS CI and unsigned release → Run workflow：选择含此工作流的可信分支，`tag` **留空**即可发布所选提交的预发布版本。若填写已经存在于 GitHub 的版本标签，例如 `v1.0.0`，则发布该标签指向的提交。目标代码也必须包含生成器和源文件。

标签只允许 `v` 开头、紧接数字、其余为 ASCII 字母、数字、点、下划线或连字符，并且必须满足 Git 的合法标签规则。例如 `v1.0.0`、`v1.1.0-beta.1`；不接受斜杠、空格、shell 字符或换行。发布已有代码的操作示例：

```sh
git tag v1.0.0 <intended-commit-sha>
git push github v1.0.0
```

同名版本标签的手动运行和标签推送共用队列，发布 job 也按标签串行执行。工作流先固定提交 SHA，测试和归档使用同一工作树；上传附件前读取远端标签（支持 annotated tag），如果标签指向其他提交，则失败并停止上传。自动预发布在测试成功后创建唯一 build 标签，明确指向测试提交，不会随 main 后续变动。重新运行同一次工作流会复用该预发布标签并替换同名附件。发布后不要移动版本标签。

## 工程与构建行为

`scripts/generate_project.py` 仅使用 Python 标准库。Actions 每次 checkout 后运行它，动态发现 `TriliumPocket/` 下的 Swift 源文件和 `tests/TriliumPocketTests/` 下的 XCTest 文件；新增 `App`、`Core`、`Features`、`Resources` 文件无需手工修改源文件列表。生成的 `TriliumPocket.xcodeproj` 使用显式 `PBXGroup` 和 source/resource build phases，包含应用 target、托管 XCTest target 及共享 `TriliumPocket` scheme。

工程最低部署版本为 iOS 17，设备族为 iPhone，使用 `TriliumPocket/Resources/Info.plist` 和 `Assets.xcassets`。为支持用户显式选择的自托管 HTTP/IP 服务器，plist 启用 `NSAllowsArbitraryLoads`；应用 URL 校验默认要求 HTTPS，只有开启 HTTP 选项才允许明文连接。不要同时加入 `NSAllowsLocalNetworking` 或 `NSAllowsArbitraryLoadsInWebContent` 等细分 ATS 键，因为 iOS 10+ 会忽略主 `NSAllowsArbitraryLoads` 键。笔记 WebView 的远程加载限制由自定义资源 scheme 与 CSP 控制。App Icon 是不透明的 1024×1024 PNG；首次生成时由标准库绘制，无外部图像依赖。生成器不会覆盖已存在的 plist 或图标。资源文件和工程均可审阅；无需在本地执行 Xcode。

构建 job 使用 `macos-15` 自带的默认 Xcode，并在日志记录版本和 SDK。它从 `simctl` JSON 中选择最高可用 iOS 版本的 iPhone simulator（要求 iOS ≥ 17），通过 UDID 执行 `xcodebuild test`，不固定容易过期的设备名称。随后使用 `generic/platform=iOS` 和 `CODE_SIGNING_ALLOWED=NO` 执行 Release archive，不调用需要签名的 `-exportArchive`。

官方 Actions 固定到已核对的稳定版本提交：checkout v7.0.1、upload-artifact v7.0.2、download-artifact v8.0.2。升级时应核对官方仓库 release/tag 与 SHA，再更新工作流；不用未验证的浮动分支。

## 下载、校验与安装限制

成功发布后，GitHub Release 包含：

- `TriliumPocket-<tag>-unsigned.ipa`：ZIP 内为 `Payload/TriliumPocket.app`。
- `COMMIT_SHA.txt`：实际经过测试并归档的源代码提交。
- `SHA256SUMS.txt`：IPA 和提交记录文件的 SHA-256。

下载所有附件到同一目录后可运行 `shasum -a 256 -c SHA256SUMS.txt`（macOS）或 `sha256sum -c SHA256SUMS.txt`（Linux）校验。

每次非 Pull Request 工作流结束后，清理任务按创建时间保留最近三次本工作流运行，删除更早的已完成运行及其产物、日志；正在运行或重新运行的任务会跳过。保留运行的 artifacts 仍受 7 天有效期限制。发布成功后，按发布时间保留最近三个包含本项目未签名 IPA 的 Release（包含预发布和已有 IPA 附件的草稿），删除更早的 Release 及全部附件，保留对应 Git 标签。发布失败时仅清理 Actions 历史，保留现有 IPA Release。清理任务在仓库内串行执行，Pull Request 不获得删除权限。

已有历史记录也可通过本地已安装的 Ruby 和已登录的 GitHub CLI 清理，无需安装依赖。先预览，确认列表后使用 `--apply` 执行：

```sh
GH_REPO='owner/repo' ruby scripts/prune_releases.rb
GH_REPO='owner/repo' ruby scripts/prune_releases.rb --apply
```

**这是未签名 IPA，不能直接在普通 iPhone 上安装或运行，也不属于 App Store/TestFlight 分发包。** 真实设备安装必须另行使用有效 Apple 身份和相应 provisioning profile 进行签名，并满足安装方式的授权条件。该仓库的工作流不配置 Apple 签名；不要将“下载成功”误认为“可以直接安装”。

## 验证边界与排错

本地只运行工程生成器及静态结构检查，不执行 Xcode 构建、依赖安装或浏览器测试。用户提供的 Actions 截图已确认测试和未签名 archive 成功；修改后的发布分支仍需在 GitHub Actions 验证打包及附件上传。GitHub 托管镜像会更新；如果镜像不再提供可用 iPhone simulator 或匹配 SDK，工作流会给出明确错误，需根据 runner 日志调整其镜像。

测试失败时查看 `ios-test-results-<sha>` artifact 中的 `test.log`/`.xcresult`；归档失败时查看 `archive.log`。找不到标签时，先确保标签已经推送到 **GitHub**，只在 Gitea 创建标签不会触发这个流程。Release 写权限被拒绝时检查组织/仓库 Actions 策略。当前实现没有触发远端工作流；实际运行结果应以 GitHub Actions 日志为准。
