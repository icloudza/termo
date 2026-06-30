# 发布与自动更新（Sparkle + GitHub Actions）

Termo 双渠道发布，**同源码、同版本号、两条独立更新通道**：

| 渠道 | 分发 | 更新机制 | 沙盒 |
|------|------|----------|------|
| **Developer ID**（GitHub） | DMG / zip | **Sparkle** 读 `appcast.xml` | 否 |
| **Mac App Store** | `.pkg` | App Store 自动更新 | 是（剥离 Sparkle） |

> Sparkle 只链接进 Dev ID 构建：MAS 配置在构建末尾的 `Strip Sparkle (MAS only)` 脚本里删除
> `Sparkle.framework`，且代码全部 `#if !TERMO_MAS` 隔离 + 弱链接，MAS 包零 Sparkle，符合审核要求。

---

## 一次性设置（首发前做一次）

### 1. 生成 Sparkle EdDSA 签名密钥

```bash
./scripts/sparkle-tools/generate_keys          # 在钥匙串创建私钥，打印公钥
```

- 把打印出的 **公钥**（`SUPublicEDKey` 的 base64 串）填进 `Termo/Info.plist`，
  替换占位符 `__SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER__`。公钥不是机密，随源码提交。
- 导出 **私钥** 供 CI 使用（私钥是机密，绝不入库）：
  ```bash
  ./scripts/sparkle-tools/generate_keys -x sparkle_private_key.pem
  ```
  把 `sparkle_private_key.pem` 的内容存为 GitHub Secret `SPARKLE_ED_PRIVATE_KEY`，然后删除本地文件。

### 2. 导出 Developer ID Application 证书

钥匙串访问 ▸ 找到 `Developer ID Application: …(KTP97H9YFF)` ▸ 右键导出为 `.p12`（设一个密码）：

```bash
base64 -i cert.p12 | pbcopy        # 存为 Secret MACOS_CERT_P12_BASE64
```

### 3. 配置 GitHub Secrets（仓库 ▸ Settings ▸ Secrets ▸ Actions）

| Secret | 内容 |
|--------|------|
| `SPARKLE_ED_PRIVATE_KEY` | 上一步导出的 EdDSA 私钥（PEM 内容） |
| `MACOS_CERT_P12_BASE64` | Developer ID 证书 `.p12` 的 base64 |
| `MACOS_CERT_PASSWORD` | 导出 `.p12` 时设的密码 |
| `KEYCHAIN_PASSWORD` | 任意强随机串（CI 临时钥匙串口令） |
| `APPLE_ID` | 公证用 Apple ID 邮箱 |
| `APPLE_APP_PASSWORD` | App 专用密码（appleid.apple.com 生成；本机现用 `sltf-…`） |

> Team ID `KTP97H9YFF` 已硬编码在 workflow 与 `package-app.sh` 中。

### 4. 开启 GitHub Pages

仓库 ▸ Settings ▸ Pages ▸ Source 选 **Deploy from a branch** ▸ 分支 `gh-pages` / `(root)`。
首次发版后 `appcast.xml` 会出现在 `https://icloudza.github.io/termo/appcast.xml`
（即 `Info.plist` 的 `SUFeedURL`）。`gh-pages` 分支由 CI 自动创建/更新。

---

## 发一个新版本（Dev ID 渠道，全自动）

1. 改 `Termo/Info.plist`：递增 `CFBundleShortVersionString`（如 `0.9.2`）**和** `CFBundleVersion`（如 `28`）。
   > `CFBundleVersion` 必须单调递增——Sparkle 与 App Store 都按它判定新旧。
2. 提交，并打 **与版本号一致** 的 tag（注释信息会成为发行说明）：
   ```bash
   git tag -a v0.9.2 -m "修复 xxx；新增 yyy"
   git push origin main --tags
   ```
3. `Release` workflow 自动：构建 → 签名 → 公证装订 → 打 zip/dmg →
   EdDSA 签名 + 更新 `appcast.xml` → 创建 GitHub Release（上传 zip+dmg）→ 部署 appcast 到 Pages。
4. 已安装的旧版 App 会在下次定时检查（或用户手动「检查更新」）时发现新版并自更新。

---

## Mac App Store 渠道（手动）

App Store 不能由 CI 自动「发布」（需人工提交 + 苹果审核）。流程：

```bash
xcodebuild -scheme Termo -configuration ReleaseMAS archive \
  -archivePath build/Termo-MAS.xcarchive
# 用 Apple Distribution / Mac App Distribution 证书 + App Store 描述文件签名导出 .pkg，
# 再用 Transporter 或 `xcrun altool` 上传到 App Store Connect，提交审核。
```

详见 [[mas-feasibility]] / [[ssh-libssh2-migration]] 记忆中的上架蓝图。版本号与 Dev ID 渠道保持一致即可。
