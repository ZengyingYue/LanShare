# LanShare

**原生鸿蒙（HarmonyOS NEXT）局域网文件共享** — 兼容 [LocalSend](https://github.com/localsend/localsend) v2 协议，可与官方 Windows / macOS / Linux / Android / iOS 客户端直接互传。

> Native HarmonyOS (NEXT) LAN file sharing, wire-compatible with the LocalSend v2 protocol — interoperates out of the box with the official LocalSend apps on Windows / macOS / Linux / Android / iOS.

[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

## ✨ 特性 / Features

- 📱 **纯原生 ArkTS**：不依赖 Flutter/Android 兼容层，直接运行于 HarmonyOS NEXT（API 12+）
- 🔄 **与 LocalSend 生态互通**：实现 LocalSend v2 协议（UDP 多播发现 + REST over HTTP），同一局域网内与官方全平台客户端互发文件
- 🔍 **双通道设备发现**：UDP 多播（224.0.0.167:53317）+ HTTP 子网扫描兜底（应对多播受限网络）
- 🔐 **PIN 码保护**：接收侧可设 PIN，错误 3 次按协议返回 429 限流
- 🌐 **中英双语 UI**

## 📦 当前状态 / Status

**M0 — 代码骨架完成，尚未在真机验证。**

- [x] 协议层：发现（多播 + HTTP 兜底）、/register、/prepare-upload、/upload、/cancel、/info
- [x] 接收流程：请求确认 → 落盘 → 系统选择器保存
- [x] 发送流程：文件/照片选择 → 协商 → 并行上传（3 并发）
- [x] 四页 UI（附近 / 发送 / 接收 / 设置）
- [ ] DevEco Studio 构建验证（需 Windows/macOS）
- [ ] 真机 ↔ 桌面版 LocalSend 互传测试
- [x] M1 代码修正：补齐 oh-package、GET_NETWORK_INFO 权限、ArkTS 严格模式问题；
      发送侧改用 rcp，可直连开启加密（HTTPS）的官方客户端
- [ ] M1 限制：接收侧明文 HTTP；发送 HTTPS 暂不校验证书；单文件 ≤ 64 MB

见 [docs/roadmap.md](docs/roadmap.md) 了解完整里程碑（M2 将加入 TLS 加密与证书指纹）。

## 🏗️ 架构 / Architecture

```
app/ohos/entry/src/main/ets/
├── app/            LanShareApp        组合根：装配各模块
├── protocol/       MulticastProvider  UDP 多播发现（LocalSend 协议主通道）
│                   FallbackProber     HTTP 子网扫描兜底
│                   Dto                协议数据模型 + 兼容性处理
├── server/         HttpServer         基于 TCPSocketServer 的手写 HTTP/1.1
│                   LanShareServer     LocalSend v2 REST 路由
├── client/         LocalSendClient    发送侧 rcp 客户端（HTTP/HTTPS，M2 加指纹校验）
├── receive/        ReceiveController  接收会话状态机 + 保存
├── send/           SendController     发送流程
├── common/         Settings/DeviceStore/Logger/...
└── pages/          Index              主页面（4 Tab）
```

详见 [docs/architecture.md](docs/architecture.md) 与 [docs/protocol.md](docs/protocol.md)。

## 🔨 构建 / Build

DevEco Studio 仅提供 Windows / macOS 版本：

1. 安装 [DevEco Studio 5.0+](https://developer.huawei.com/consumer/cn/deveco-studio/)
2. `File → Open` 打开 `app/ohos`（首次打开会提示同步 hvigor 版本，确认即可）
3. `File → Project Structure → Signing Configs` 配置自动签名
4. 连接 HarmonyOS NEXT 真机（或模拟器），点击 Run

> 本仓库在 Linux 上开发。除 DevEco Studio 外，也可用华为
> [Command Line Tools](https://developer.huawei.com/consumer/cn/download/)（含 Linux 版）
> 在命令行构建，步骤见 [docs/testing.md](docs/testing.md)。

## 🧪 互传测试 / Interop Testing

> 完整的 M1 测试清单与脚本化测试工具 `tools/lspeer.py` 见 [docs/testing.md](docs/testing.md)。

1. 电脑安装 [LocalSend 桌面版](https://localsend.org)，与手机连入**同一 Wi-Fi**（关闭 AP 隔离）
2. **手机 → 电脑**：LanShare「发送」页选文件 → 「附近」页点击电脑设备
3. **电脑 → 手机**：LocalSend 选中文件发送到 LanShare → 「接收」页点「接收」→ 选择保存位置
4. 排查：路由器 AP 隔离、防火墙放行 TCP/UDP 53317、多播失败时点「刷新」走 HTTP 扫描

## 🗺️ Roadmap

| 里程碑 | 内容 |
|--------|------|
| M1 | DevEco 构建通过 + 真机互传验证（HTTP） |
| M2 | TLS：运行时 RSA 自签证书 + TLSSocketServer + 指纹校验（TOFU/固定） |
| M3 | PIN 增强、快速保存（SaveButton + 媒体库）、后台保活、Web 下载模式 |
| M4+ | 其他平台原生客户端（可选） |

## 📄 License

[Apache-2.0](LICENSE)

## 🙏 Acknowledgments

- [LocalSend](https://github.com/localsend/localsend)（Apache-2.0）— LanShare 实现其 v2 协议以实现跨生态互传，感谢该项目定义了简洁实用的局域网传输协议
- 协议实现的兼容性细节参考了 LocalSend 客户端的公开行为；[协议仓库](https://github.com/localsend/protocol)本身未附许可证，本文档均为独立撰写
