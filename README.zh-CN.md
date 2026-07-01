<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-dark.svg">
  <img src="assets/logo-light.svg" width="300" alt="Termo">
</picture>

**一体化的原生 macOS 远程工作台**

SSH · SFTP · 终端 · Windows 远程桌面 · 端口转发 · 主机监控

[![官网](https://img.shields.io/badge/%E5%AE%98%E7%BD%91-termoi.app-409EFF?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2NCA2NCI%2BCiAgPHJlY3Qgd2lkdGg9IjY0IiBoZWlnaHQ9IjY0IiByeD0iMTUiIGZpbGw9IiMxNDFFMzkiLz4KICA8cGF0aCBkPSJNMTYgMjEgTDI2IDMwIEwxNiAzOSIgZmlsbD0ibm9uZSIgc3Ryb2tlPSIjZmZmZmZmIiBzdHJva2Utd2lkdGg9IjUuMiIgc3Ryb2tlLWxpbmVjYXA9InJvdW5kIiBzdHJva2UtbGluZWpvaW49InJvdW5kIi8%2BCiAgPGxpbmUgeDE9IjMyIiB5MT0iNDAiIHgyPSI0NyIgeTI9IjQwIiBzdHJva2U9IiM1NEE4RkMiIHN0cm9rZS13aWR0aD0iNS4yIiBzdHJva2UtbGluZWNhcD0icm91bmQiLz4KPC9zdmc%2BCg%3D%3D)](https://termoi.app)
[![最新版本](https://img.shields.io/github/v/release/icloudza/termo?style=flat-square&label=%E6%9C%80%E6%96%B0%E7%89%88&color=409EFF)](https://github.com/icloudza/termo/releases)
[![下载量](https://img.shields.io/github/downloads/icloudza/termo/total?style=flat-square&label=%E4%B8%8B%E8%BD%BD&color=33C759)](https://github.com/icloudza/termo/releases)
[![Stars](https://img.shields.io/github/stars/icloudza/termo?style=flat-square&color=f5a623)](https://github.com/icloudza/termo/stargazers)
![平台](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-000000?style=flat-square&logo=apple)
[![许可](https://img.shields.io/badge/license-PolyForm%20Noncommercial-8250df?style=flat-square)](LICENSE.md)

**简体中文** · [English](README.md)

<br>

<img src="assets/termo-overview.png" width="820" alt="Termo 概览">

</div>

---

## 简介

**Termo** 是一款用 SwiftUI + AppKit 原生打造的 macOS 远程运维客户端。它把日常需要在多个工具间来回切换的事——SSH 终端、文件传输、Windows 远程桌面、端口转发、主机监控、密钥管理——收进同一个高完成度的界面里。

引擎层面，Termo 把 SSH / SFTP / 终端 / 端口转发 / 密钥 全部做进**进程内**（libssh2 + OpenSSL），不依赖系统 `ssh`、无需 spawn 外部进程；Windows 远程桌面内嵌 **FreeRDP**。因此它是一个自包含、经 Apple 签名与公证的单一二进制，连接更稳、启动更快、开箱即用。

## 特性

| 能力 | 说明 |
|---|---|
| **SSH 终端** | 基于 SwiftTerm 的完整终端；进程内 libssh2 引擎，连接稳、启动快 |
| **SFTP 文件浏览** | 上传 / 下载 / 重命名 / 权限修改，断点续传、并发队列、远程代码在线编辑 |
| **Windows 远程桌面** | 内嵌 FreeRDP：全彩图形管线、键盘输入、剪贴板双向同步、分辨率随窗口自适应 |
| **端口转发** | 本地（-L）/ 远程（-R）/ 动态 SOCKS（-D），后台常驻，托盘看板实时掌控 |
| **主机监控** | CPU / 内存 / 磁盘 / 网络实时折线，异常持续占用可发系统通知 |
| **SSH 密钥管理** | 进程内生成 / 导入 ed25519 · RSA，不依赖 `ssh-keygen` |
| **代码片段** | 常用命令一键插入或直接运行 |
| **统一自绘界面** | 深 / 浅色主题、菜单栏呼吸灯，细节对齐 Ghostty / Xcode 的观感 |
| **应用内自动更新** | Sparkle + EdDSA 签名，国内经 Cloudflare R2 加速下载 |
| **中英双语** | 设置内一键切换界面语言 |

## 下载安装

> 系统要求：macOS 14 (Sonoma) 及以上 · Apple Silicon（M 系列）

[![下载最新版](https://img.shields.io/badge/%E4%B8%8B%E8%BD%BD%E6%9C%80%E6%96%B0%E7%89%88-Termo.dmg-409EFF?style=for-the-badge)](https://termoi.app)

- 推荐：点上方按钮前往[官网](https://termoi.app)下载
- 或前往 [GitHub Releases](https://github.com/icloudza/termo/releases) 获取历史版本与校验信息

安装后首次打开若被 Gatekeeper 提示，请确认应用来自「已验证的开发者」——Termo 已用 **Developer ID 签名并经 Apple 公证**。装好后新版本会自动提醒，无需手动重复下载。

## 快速上手

1. 左侧活动栏选择 主机，点右上角 `+` 新增 SSH 主机（地址、账号、密码或密钥）
2. 点击主机进入概览，选 终端 即开始会话；选 文件 浏览远端目录
3. Windows 主机切到 RDP 面板新增，点 远程桌面 直接连入
4. 需要内网穿透时，进 端口转发 配置 -L / -R / -D 规则，后台常驻

密码与私钥口令保存在系统钥匙串，不落明文磁盘。

## 从源码构建

项目用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 声明式管理工程，第三方原生依赖（FreeRDP / libssh2 / Sparkle）以 xcframework 形式随仓库提供。

```bash
brew install xcodegen
git clone https://github.com/icloudza/termo.git && cd termo
xcodegen generate            # 由 project.yml 生成 Termo.xcodeproj
open Termo.xcodeproj         # Xcode 打开，或命令行构建：
xcodebuild -scheme Termo -configuration Release build
```

> 需要 Xcode 16+ 与 Apple Silicon 机器。增删源文件后重跑 `xcodegen generate`。

## 技术架构

- 界面：SwiftUI + AppKit，全自绘统一组件；单窗口 + 菜单栏常驻
- SSH 栈：进程内 libssh2（静态）+ 共享 OpenSSL，覆盖终端 PTY / SFTP 子系统 / 直连转发 / 已知主机校验 / 密钥生成
- RDP 栈：内嵌 FreeRDP 静态库 + ObjC 桥，BGRA 帧回主线程转 CGImage 渲染
- 持久化：主机 / 会话 JSON + 密码合并写入钥匙串（乐观锁防多端竞争）
- 分发：Developer ID 签名 + 公证；GitHub Actions 打 tag 自动发版 → Sparkle appcast → R2/CDN

## 许可

Termo 采用 [PolyForm Noncommercial License 1.0.0](LICENSE.md) 授权。

- 允许：个人使用、学习研究、爱好项目、非营利组织使用，可查阅、修改、分发源码
- 禁止：任何商业用途

© 2026 cloudza

---

<div align="center">
<sub>用 Swift 打造 · <a href="https://github.com/icloudza/termo/issues">反馈问题</a></sub>
</div>
