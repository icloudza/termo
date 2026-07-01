# 贡献指南 / Contributing

感谢你对 Termo 的兴趣！Issue 与 PR 均欢迎，可用中文或英文。
Thanks for your interest in Termo! Issues and PRs are welcome, in Chinese or English.

> **许可提示 / License note**：Termo 采用 [PolyForm Noncommercial License 1.0.0](LICENSE.md)。提交贡献即表示你同意你的贡献在同一许可下发布。Termo is licensed under PolyForm Noncommercial 1.0.0; by contributing you agree your contribution is released under the same terms.

## 报告问题 / Reporting issues

- 先搜索 [已有 Issue](https://github.com/icloudza/termo/issues)，避免重复
- 用对应模板提交，附上 **macOS 版本、Termo 版本、复现步骤**
- 安全漏洞请勿公开，见 [SECURITY.md](SECURITY.md)

- Search [existing issues](https://github.com/icloudza/termo/issues) first
- File with the matching template; include **macOS version, Termo version, steps to reproduce**
- Do not report security vulnerabilities publicly — see [SECURITY.md](SECURITY.md)

## 开发环境 / Development setup

需要 Xcode 16+ 与 Apple Silicon。/ Requires Xcode 16+ on Apple Silicon.

```bash
brew install xcodegen
git clone https://github.com/icloudza/termo.git && cd termo
xcodegen generate            # 由 project.yml 生成工程 / generate the project
xcodebuild -scheme Termo -configuration Debug build   # 验证可编译 / verify it builds
```

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 管理：**改动源文件的增删后重跑 `xcodegen generate`**，不要手改 `.xcodeproj`。
The project is managed by XcodeGen: **re-run `xcodegen generate` after adding/removing files**; never hand-edit `.xcodeproj`.

## 代码约定 / Conventions

- Swift 5.9，遵循现有代码风格；UI 统一使用自绘组件（`ThemedTextField` / `PrimaryButton` 等），不用原生模态
- 用户可见文案用 `String(localized:)` / `Text` 字面量，便于本地化
- 提交信息用 Conventional Commits（`feat:` / `fix:` / `build:` …）

- Swift 5.9, match the surrounding style; UI uses the custom themed components, never native modals
- Wrap user-facing strings for localization (`String(localized:)` / `Text` literals)
- Use Conventional Commits (`feat:` / `fix:` / `build:` …)

## 提交 PR / Pull requests

1. 从 `main` 拉分支，保持改动聚焦、单一主题
2. 确保 `xcodebuild -scheme Termo -configuration Debug build` 通过
3. 描述清楚动机与做法，关联相关 Issue
4. UI 改动请附前后截图

1. Branch off `main`, keep the change focused
2. Make sure `xcodebuild -scheme Termo -configuration Debug build` passes
3. Explain the motivation and approach; link related issues
4. Attach before/after screenshots for UI changes
