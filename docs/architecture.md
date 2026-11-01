# LanShare 架构设计

## 模块图

```
┌─────────────────────────────────────────────────────┐
│ pages/Index.ets          UI（附近/发送/接收/设置）      │
│    ▲ AppStorage 快照（devices / receiveState）        │
├─────────────────────────────────────────────────────┤
│ app/LanShareApp          组合根                        │
│   ├─ MulticastProvider   UDP 多播发现 ──┐             │
│   ├─ FallbackProber      HTTP 扫描发现 ─┤→ DeviceStore│
│   ├─ HttpServer          TCP 80/53317   │             │
│   │    └─ LanShareServer 路由            │             │
│   │         └─ ReceiveController 接收状态机│             │
│   └─ LocalSendClient     发送侧 rcp       │             │
│        └─ SendController                │             │
├─────────────────────────────────────────────────────┤
│ common: Settings(persist) / AppContext / Dto / Mime  │
└─────────────────────────────────────────────────────┘
```

## 关键设计决策

### 1. 纯 ArkTS，无原生依赖

鸿蒙 `@ohos.net.socket` 提供 `TCPSocketServer`（HTTP，M1）与
`TLSSocketServer`（HTTPS，M2，支持传入 PEM 自签证书），配合
`MulticastSocket`（API 11+）即可完整实现协议，无需 NAPI/Rust。

### 2. 手写 HTTP/1.1 服务端

系统没有 ArkTS HTTP 服务端 API，`HttpServer` 基于 `TCPSocketServer`
自实现：逐连接累积字节流 → 解析请求头（支持 Content-Length 与
chunked）→ 完整请求交给路由 → 响应后关闭连接（`Connection: close`，
简化解析；官方客户端与浏览器均兼容）。

**性能取舍**：请求头解析阶段增量扫描，请求体只在收齐后拼接一次，
避免大文件上传时的 O(n²) 拷贝。

M2 切换 TLS 时只需把 `TCPSocketServer` 换成 `TLSSocketServer`
（`secureOptions` 传入运行时生成的自签证书 PEM），上层路由不动。

### 3. 双通道发现

- 主：`MulticastProvider` —— 绑定 UDP 53317、加入多播组、三连发 announce
- 兜底：`FallbackProber` —— 读取 `connection.getConnectionProperties`
  获取本机 IPv4，对 /24 全网段并发 POST /register

两路独立失败（端口被占 / 多播被路由器拦截），任一可用即可发现设备。

### 4. 单线程事件驱动的 UI ↔ 服务端协同

ArkTS 应用逻辑跑在同一事件循环上，服务端回调可直接触发 UI 状态。
`ReceiveController` 把会话状态做成不可变快照（`ReceiveSnapshot`）
发布到 AppStorage，UI 通过 `@StorageLink` 重渲染；用户的接收/拒绝
通过 Promise resolver 回传给阻塞中的 HTTP 路由处理函数
（60 秒超时自动拒绝）。

### 5. 接收文件落盘

权限模型下应用不能随意写公共目录，因此接收先写入应用沙箱
`cacheDir`，全部收齐后由系统 `DocumentViewPicker.save()` 让用户
选择目标位置，以写模式打开返回的文档 URI 后 `fs.copyFileSync` 到其 fd。保存对话框要求应用前台，
后台收完时 UI 保留「保存到本机」按钮供用户手动触发。

### 6. 发送客户端与内存约束（M1 限制）

`LocalSendClient` 基于 RemoteCommunicationKit（rcp），单个长生命周期
Session，`remoteValidation: 'skip'` + `proxy: 'no-proxy'`：同一代码路径
连接 HTTP 对端，且局域网流量不经系统代理/VPN。HTTPS 对端（官方客户端默认）
实测要求客户端证书（mTLS），M1 未实现，需在 M2 给 rcp Session 配置客户端证书。
HTTP 兜底扫描对每个地址同时尝试 https 与 http（https 探测在 M2 前会被拒）。

请求体与接收缓冲均为整块 ArrayBuffer，因此 M1 限制单文件 64 MB
（`ProtocolConstants.MAX_FILE_SIZE_BYTES`）：发送侧在选择阶段标记，
接收侧不为超限文件分配 token，HttpServer 对超限请求体直接回 413。
M3 计划改为流式落盘/分块上传解除限制。

## 线程与生命周期

- 所有网络回调运行于主线程事件循环，无需锁
- 长任务（HTTP 请求、picker）均为 Promise 异步
- `EntryAbility.onCreate` 触发 `LanShareApp.bootstrap`（异步）：
  载入设置 → 初始化 AppContext → 起 HTTP 服务 → 起多播 → 三连发 →
  后台兜底扫描。各步骤独立捕获失败，不阻塞 UI
- M3 将引入 `DATA_TRANSFER` 长时任务（已在 module.json5 声明）保持
  后台接收能力
