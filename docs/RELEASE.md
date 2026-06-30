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

下面 1–3 必须在**首次发版前**完成；4（GitHub Pages）放到第一次发版**之后**做。

### 1. Sparkle EdDSA 签名密钥

```bash
./scripts/sparkle-tools/generate_keys
```

- 首次运行会在登录钥匙串创建私钥并打印公钥；若已存在密钥，会直接打印既有公钥（幂等）。
- 把打印出的 **公钥**（`SUPublicEDKey` 的 base64 串）填进 `Termo/Info.plist`，替换占位符
  `__SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER__`。公钥不是机密，随源码提交。
  > 占位符不替换的话，CI 的防呆检查（release.yml）会 `grep` 到它并直接 `exit 1`，发不出版。
- 导出 **私钥** 供 CI 使用（私钥是机密，绝不入库）：
  ```bash
  ./scripts/sparkle-tools/generate_keys -x "$HOME/sparkle_private_key.pem"
  ```
  把该文件**整段内容**存为 GitHub Secret `SPARKLE_ED_PRIVATE_KEY`（约 60 字符、单行），存好后删除本地文件。

### 2. Developer ID Application 证书 → `.p12`

钥匙串访问里**必须连私钥一起导出**，否则签不了名：

1. 找到 `Developer ID Application: …(KTP97H9YFF)`，点它左侧**展开三角 ▸**，露出下面的**私钥**。
2. **同时选中「证书 + 它的私钥」两项**（或直接右键那把私钥）→「导出 2 项…」。
3. 格式选 **个人信息交换 (.p12)**，设一个**纯字母数字的简单密码**（带特殊符号后续易踩引号坑）。
   这个密码就是 Secret `MACOS_CERT_PASSWORD`。

> 只选中证书本身（不展开选私钥）时，导出格式只有 `.cer`/`.pem`，那是公开证书、**不含私钥**，不能用于签名。

**验证 .p12 是否正确**（含私钥、Team 对）。注意 macOS 自带 `openssl` 是老 LibreSSL，**解不开钥匙串导出的新版 p12**，会假性报 `no start line` / `0 keys`；用系统原生 `security` 验证（同 CI 做法）：

```bash
read -s -r "P?导出密码: "; echo
KC="$HOME/_verify.keychain-db"
security delete-keychain "$KC" 2>/dev/null
security create-keychain -p test "$KC"
security unlock-keychain -p test "$KC"
security import "$HOME/证书.p12" -k "$KC" -P "$P" -T /usr/bin/codesign \
  && security find-identity -v -p codesigning "$KC"
security delete-keychain "$KC"
```

期望输出 `… "Developer ID Application: <你的名字> (KTP97H9YFF)"` + `1 valid identities found`。
若报 `MAC verification failed during PKCS12 import` → 密码不对；若 `0 valid identities found` → 没把私钥一起导出，回上面重导。

验证通过后转 base64 存 Secret：

```bash
base64 -i "$HOME/证书.p12" | pbcopy
pbpaste | wc -c        # 几千字符（如 ~4353）才对；若只有几十字符是剪贴板没覆盖，重来
```

→ 粘进 Secret `MACOS_CERT_P12_BASE64`。

### 3. 配齐 6 个 GitHub Secrets

仓库 ▸ Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret：

| Secret | 内容 | 来源 |
|--------|------|------|
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle EdDSA 私钥（PEM 整段，约 60 字符） | 步骤 1 |
| `MACOS_CERT_P12_BASE64` | Dev ID 证书 `.p12` 的 base64（几千字符） | 步骤 2 |
| `MACOS_CERT_PASSWORD` | **导出 .p12 时设的密码**（必须与 p12 一字不差） | 步骤 2 |
| `KEYCHAIN_PASSWORD` | **任意强随机串**（CI 临时钥匙串口令，与证书无关）：`openssl rand -base64 24` | 自定义 |
| `APPLE_ID` | 公证用 Apple ID 邮箱（KTP97H9YFF 账号的登录邮箱） | Apple 账号 |
| `APPLE_APP_PASSWORD` | App 专用密码 `xxxx-xxxx-xxxx-xxxx` | appleid.apple.com ▸ 登录与安全 ▸ App 专用密码 |

> 两个带 password 的别混：`MACOS_CERT_PASSWORD` 是真实的 p12 导出密码（必须匹配）；
> `KEYCHAIN_PASSWORD` 只是随机串。`GITHUB_TOKEN` 由 Actions 自带，不用配。
> Team ID `KTP97H9YFF` 已硬编码在 workflow 与 `package-app.sh` 中。

### 清理本地敏感文件

Secret 存好后，删掉本地的私钥与证书：

```bash
rm -f "$HOME/sparkle_private_key.pem" "$HOME/证书.p12"
```

### 4. GitHub Pages（第一次发版之后）

`gh-pages` 分支由 CI 在首次发版时自动创建；分支存在后再去
仓库 ▸ Settings ▸ Pages ▸ Source 选 **Deploy from a branch** ▸ 分支 `gh-pages` / `(root)`。
开启后 `appcast.xml` 即在 `https://icloudza.github.io/termo/appcast.xml`（即 `Info.plist` 的 `SUFeedURL`）。
首个版本没有「更新」可找，故 Pages 晚一步开不影响首发，但第二次发版前必须开好。

---

## 发一个新版本（Dev ID 渠道，全自动）

1. 改 `Termo/Info.plist`：递增 `CFBundleShortVersionString`（如 `0.9.2`）**和** `CFBundleVersion`（如 `28`）。
   > `CFBundleVersion` 必须单调递增——Sparkle 与 App Store 都按它判定新旧。
2. 提交，并打 **与版本号一致** 的 tag（tag 注释会成为发行说明）：
   ```bash
   git tag -a v0.9.2 -m "修复 xxx；新增 yyy"
   git push origin main --tags
   ```
3. `Release` workflow 自动：构建 → 签名 → 公证装订 → 打 zip/dmg →
   EdDSA 签名 + 更新 `appcast.xml` → 创建 GitHub Release（上传 zip+dmg）→ 部署 appcast 到 Pages。
4. 已安装的旧版 App 会在下次定时检查（24h）或用户手动「检查更新」时发现新版并自更新。

> 首次跑流水线也是对整套 CI（签名/公证/appcast）的实测，首跑常在公证等步骤失败，看 Actions 日志按下方排查表修。

---

## Mac App Store 渠道（手动）

App Store 不能由 CI 自动「发布」（需人工提交 + 苹果审核）。流程：

```bash
xcodebuild -scheme Termo-MAS -configuration ReleaseMAS archive \
  -archivePath build/Termo-MAS.xcarchive
```

用 Apple Distribution / Mac App Distribution 证书 + App Store 描述文件签名导出 `.pkg`，
再用 Transporter 或 `xcrun altool` 上传到 App Store Connect，提交审核。版本号与 Dev ID 渠道保持一致。

---

## 排查表

| 现象 | 原因 | 处理 |
|------|------|------|
| CI 一开始就 `exit 1`（防呆） | `Info.plist` 的 `SUPublicEDKey` 还是占位符 | 填入步骤 1 的公钥 |
| 验证 p12 报 `no start line` / `0 keys` | 系统 LibreSSL 解不开新版 p12 | 用步骤 2 的 `security import` 验证，别用 `openssl pkcs12` |
| `MAC verification failed during PKCS12 import` | 密码与 p12 不符 | 核对 `MACOS_CERT_PASSWORD`；不确定就回钥匙串重导（设简单密码） |
| 两个 Secret 值看着一样 | 粘贴时剪贴板是上一次内容 | 重跑对应 `pbcopy`，用 `pbpaste \| wc -c` 核对长度再粘 |
| 公证失败 | `APPLE_ID` / `APPLE_APP_PASSWORD` 错，或 App 专用密码失效 | 重新生成 App 专用密码，更新 Secret |
| 更新下载失败 | `appcast.xml` 的 enclosure URL 失效 | 检查 GitHub Release 资产是否存在 |
| 签名校验失败 | appcast 的 `edSignature` 与本地 `SUPublicEDKey` 不匹配 | 确认公钥/私钥是同一对 |
| MAS 包误含 Sparkle | `Strip Sparkle` 脚本未执行 | 检查是否用 `ReleaseMAS`/`DebugMAS` 配置构建 |
