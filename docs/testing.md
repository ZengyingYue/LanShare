# M1 构建与真机测试指南

## 1. 构建

### 方式 A：DevEco Studio（Windows / macOS）

`File → Open` 打开 `app/ohos`，`Project Structure → Signing Configs` 勾选自动签名，连接真机后 Run。

### 方式 B：Linux 命令行（Command Line Tools）

1. 登录华为开发者联盟，下载 **Command Line Tools for HarmonyOS（Linux x64）**，解压到如 `~/opt/command-line-tools`
   （包内含 node、ohpm、hvigor、HarmonyOS SDK、hdc）。
2. 环境变量：

   ```bash
   export CLT=~/opt/command-line-tools
   export PATH=$CLT/bin:$CLT/sdk/default/openharmony/toolchains:$PATH
   export NODE_HOME=$CLT/tool/node   # 以实际解压目录为准
   export DEVECO_SDK_HOME=$CLT/sdk
   ```

3. 构建未签名 HAP：

   ```bash
   cd app/ohos
   ohpm install
   hvigorw assembleHap --mode module -p product=default -p buildMode=debug --no-daemon
   # 产物：entry/build/default/outputs/default/entry-default-unsigned.hap
   ```

4. 签名（真机安装必需，材料放在仓库外或 `signing/`，已被 .gitignore 忽略）：
   - 用 SDK 自带的 `hap-sign-tool.jar`（`toolchains/lib/`）`generate-keypair` + `generate-csr` 生成 `.p12` 与 CSR；
   - AppGallery Connect →「证书、APP ID 和 Profile」：上传 CSR 得调试证书 `.cer`；
     登记设备 UDID（`hdc shell bm get --udid`）；创建 APP ID `com.lanshare.app`；生成调试 Profile `.p7b`；
   - 签名：

     ```bash
     java -jar $CLT/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar sign-app \
       -mode localSign -signAlg SHA256withECDSA -keyAlias lanshare \
       -keystoreFile signing/lanshare.p12 -keystorePwd *** -keyPwd *** \
       -appCertFile signing/lanshare.cer -profileFile signing/lanshare.p7b \
       -inFile entry/build/default/outputs/default/entry-default-unsigned.hap \
       -outFile lanshare-debug.hap
     ```

5. 安装与日志：

   ```bash
   hdc install -r lanshare-debug.hap
   hdc shell aa start -a EntryAbility -b com.lanshare.app
   hdc hilog | grep LanShare
   ```

### 首次编译重点确认

以下 API 是在无 SDK 环境下按文档/经验写的，编译报错优先看这里：

| 位置 | 用法 |
|------|------|
| `client/LocalSendClient.ets` | `rcp.createSession({ requestConfiguration: { security: { remoteValidation: 'skip' }, proxy: 'no-proxy' } })`、`new rcp.Request(url, 'POST', headers, content)`、`request.configuration.transfer.timeout.{connectMs,transferMs}`、`response.toString()` |
| `protocol/MulticastProvider.ets` | `socket.constructMulticastSocketInstance()`、`setLoopbackMode`、`addMembership` |
| `receive/ReceiveController.ets` | `new picker.DocumentViewPicker(context)`、`fs.copyFileSync(path, fd)`、`pasteboard.createData(MIMETYPE_TEXT_PLAIN, text)` + `getSystemPasteboard().setData()` |
| `server/HttpServer.ets` | `socket.constructTCPSocketServerInstance()` 的 `connect`/`message` 事件 |

## 2. 测试对端：`tools/lspeer.py`

PC 上的最小 LocalSend v2 实现（仅 Python 标准库，HTTP），用于在没有官方客户端或需要脚本化时测试：

```bash
python3 tools/lspeer.py discover                     # 多播宣告，列出应答的设备（含手机）
python3 tools/lspeer.py serve --out ~/inbox          # 当接收端；可加 --pin 1234 / --mode decline|busy
python3 tools/lspeer.py send <手机IP> a.jpg b.pdf     # 当发送端
python3 tools/lspeer.py send <手机IP> --text "你好"   # 发文本消息（同官方“粘贴”），应回 204
python3 tools/lspeer.py scenarios <手机IP> [--pin 1234]   # 按提示在手机上点接受/拒绝，自动判定结果

# 发给开启加密的官方客户端：需要客户端证书（send 默认先试 https，失败再退回 http）
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -subj "/CN=LocalSend User"
python3 tools/lspeer.py --cert cert.pem --key key.pem send <电脑IP> a.jpg
```

## 3. M1 测试清单

前置：手机与电脑在同一 Wi-Fi（关闭 AP 隔离），电脑防火墙放行 TCP/UDP 53317。

| # | 场景 | 方法 | 期望 |
|---|------|------|------|
| 1 | 多播发现：手机 → 电脑 | 官方 LocalSend / `lspeer serve` 运行中，打开 LanShare | 「附近」出现电脑 |
| 2 | 多播发现：电脑 → 手机 | `lspeer discover` / 官方客户端刷新 | 列出 LanShare 手机 |
| 3 | HTTP 兜底 | 关闭电脑端多播（或换 AP 隔离多播的网络），点「刷新」 | 仍能发现（https 与 http 均扫描） |
| 4 | 电脑 → 手机 | 官方客户端发送 2 个文件 | 手机弹确认，接受后保存成功，内容一致 |
| 5 | 手机 → 电脑（官方默认加密开） | LanShare 发送到官方客户端 | **M1 预期失败**：官方要求客户端证书（mTLS），M2 后应成功 |
| 6 | 手机 → 电脑（官方关闭加密） | 同上 | 成功（HTTP） |
| 7 | 拒绝 | 手机点拒绝 | 发送方提示被拒（403） |
| 8 | PIN | 手机设 PIN，`scenarios --pin` | 401、401、429；正确 PIN 后可传 |
| 9 | 并发 | 弹窗期间再发一个请求 | 第二个 409 |
| 10 | 取消 | `scenarios` 取消段 / 官方客户端中途取消 | 手机显示失败并清理，后续上传 409 |
| 11 | 超限 | 发送 > 64 MB 文件 | 发送侧标记「64MB+」；接收侧显示「已跳过」，仅超限时 403 |
| 12 | 设置 | 改设备名保存 | 立即生效，PIN 不被清空；改端口提示重启 |

结果记录到 issue 或本文件末尾，修复后发布 0.1.x。

## 4. 实测记录

### 2026-11-01 — PC ↔ PC（Linux `lspeer` ↔ Windows 官方 LocalSend 2.2，同一 Wi-Fi）

| 方向 | 结果 | 备注 |
|------|------|------|
| 多播发现（双向） | ✅ | Windows 收到宣告后通过 HTTP `/register` 回连 |
| Windows → Linux | ✅ 内容一致 | 官方客户端用 **chunked** 传输上传（无 Content-Length）；lspeer 原先只认 Content-Length，收到 0 字节，已修复 |
| Linux → Windows（20 MB + 中文文件名） | ✅ SHA-256 一致 | 走 HTTPS，**必须出示客户端证书**；~4 MB/s |

发现：

1. **官方 HTTPS 服务要求客户端证书（mTLS）**。不带证书 → `certificate required`；新证书首次连接会
   `access denied`，片刻后同一证书被接受（原因未明，待查）。直接影响 LanShare：M1 发送端发不了默认配置的官方客户端（清单 #5）。
2. **官方上传使用 chunked 编码**。LanShare `HttpServer` 已实现 chunked 解析，真机测试 #4 时重点确认。
3. Windows 上关闭「加密」后，服务未立即切回 HTTP（仍是 TLS），可能需要重启 LocalSend。

