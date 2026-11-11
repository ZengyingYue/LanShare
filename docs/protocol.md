# LanShare 协议实现说明

LanShare 实现 LocalSend v2（至 2.2）协议的一个子集，目标是与官方客户端互传。
本文档独立描述 LanShare 实现的线上行为，包含实现过程中的兼容性决策。

协议官方参考：<https://github.com/localsend/protocol>
（注意：该仓库未附带开源许可证，本文档为独立撰写，未复制其文本。）

## 总览

| 项目 | 值 |
|------|-----|
| 默认端口 | 53317（UDP 多播、HTTP 服务共用；可配置） |
| 多播组 | 224.0.0.167（限定 224.0.0.0/24，兼容部分 Android 设备） |
| 传输协议 | M1 为 HTTP；协议本身允许 HTTPS（M2 实现） |
| 内容编码 | JSON（camelCase）；文件内容为原始二进制 body |
| 身份标识 | 指纹：M1 为随机 UUID；M2 起为证书 DER 的 SHA-256（大写 hex） |

## 设备发现

### 主通道：UDP 多播

向 `224.0.0.167:53317` 发送 UTF-8 JSON 数据报：

```json
{
  "alias": "HUAWEI Mate-123",
  "version": "2.2",
  "deviceModel": "HUAWEI XXX",
  "deviceType": "mobile",
  "fingerprint": "<random-or-cert-sha256>",
  "port": 53317,
  "protocol": "http",
  "download": false,
  "announce": true,
  "announcement": true
}
```

- `announce`/`announcement` 同时携带（v1/v2 双兼容）
- 启动时按 **100ms / 500ms / 2000ms** 三连发（与官方客户端一致）
- 收到他方 announce 后：
  - 忽略指纹等于自己（自发现过滤）与指纹为空的报文
  - 将对方加入设备列表
  - 若对方 `announce=true`，回执：向对方 `ip:port` 发 `POST /register`（优先），
    TCP 失败时不做额外动作（HTTP 兜底扫描会再覆盖）
- 指纹比较大小写不敏感

### 兜底通道：HTTP 子网扫描

多播不可用（网络策略限制）时，对每个本机 IPv4 所在 /24 的全部地址
（排除自身，并发 50，超时 400ms）发送 `POST /register`。
200 响应即发现一台 LocalSend 设备；412 表示发现了自己。

## REST API

所有路由基于 `/api/localsend/v2`，同时提供 `/v1/info` 别名。
JSON 响应均为 camelCase。

### POST /api/localsend/v2/register

请求体为发送方身份（同 announce 报文去掉 announce 字段）。
响应 200：

```json
{
  "alias": "...", "version": "2.2", "deviceModel": "...",
  "deviceType": "mobile", "fingerprint": "...", "download": false
}
```

- 请求指纹等于自己 → `412`（自发现）
- 请求体非法 → `400`
- 副作用：登记对方设备

### GET /api/localsend/v2/info（含 /v1/info）

同 /register 的响应。`?fingerprint=` 等于自己时返回 `412`。

### POST /api/localsend/v2/prepare-upload[?pin=xxx]

请求体：

```json
{
  "info": { /* 发送方身份，同 /register 请求 */ },
  "files": {
    "<fileId>": {
      "id": "<fileId>",
      "fileName": "photo.jpg",
      "size": 12345,
      "fileType": "image/jpeg",
      "sha256": null
    }
  }
}
```

LanShare 接收侧行为（状态码与协议一致）：

| 状态 | 含义 |
|------|------|
| 200  | 接受，返回 `{sessionId, files: {fileId: token}}` |
| 204  | 无需传输：文本消息（见下） |
| 400  | 请求体非法 / files 为空 |
| 401  | 需要 PIN 或 PIN 错误 |
| 403  | 用户拒绝 |
| 409  | 已有进行中的会话（协议规定单会话） |
| 429  | 同一 IP 的 PIN 失败已达 3 次 |

**文本消息**：官方客户端的“粘贴/文本”发送不传文件，而是发一个
`fileType` 为 `text/plain`（v1 为 `text`）的单文件，全文放在 `preview` 里。
与官方接收端一致，LanShare 判定条件为“恰好一个文件 + text 类型 + preview 非空”，
命中时不弹确认、不建会话，直接在接收页显示文本并写入系统剪贴板，回 `204`；
发送方收到 204 即视为完成，不会再上传 .txt。PIN 校验仍在此之前进行。

兼容性处理：

- 校验和字段同时接受 `sha256` 与旧版 `hash`（官方 Dart 客户端 ≤1.15 使用后者），
  LanShare 发送时一律输出 `sha256`
- `files` 的 map key 与 `id` 不一致时以 `id` 为准（缺失时回退为 key）
- v1 对端缺省 `version`/`port`/`protocol` 时的默认：port=53317、protocol=http
- 未知 `deviceType` 一律按 `desktop` 展示

### POST /api/localsend/v2/upload?sessionId=..&fileId=..&token=..

- 请求体为**原始文件二进制**（非 multipart）
- 校验顺序：无会话→409；来源 IP 与 prepare-upload 不一致→403；
  参数缺失→400；sessionId 不符→403；fileId 未知或 token 不符→403；
  文件已完成→409；写盘失败→500
- 成功 → 200 空体
- M1 尚未校验 sha256（M2 补充，mismatch 时 422）

### POST /api/localsend/v2/cancel?sessionId=..

发送方中止会话；会话归属校验通过返回 200，否则 409。

## 传输流程

### 上传（LanShare 作为发送方）

1. 多播/扫描发现设备
2. `POST /prepare-upload`（若 401 则带 `?pin=` 重试）
3. 对每个被接受的文件 `POST /upload`（3 路并发，原始二进制 body）
4. 任一失败 → `POST /cancel`

### 接收（LanShare 作为接收方）

1. `prepare-upload` 到达 → UI 弹出确认（60 秒超时自动拒绝 → 403）
2. 接受后生成 sessionId + 每文件随机 UUID token
3. 收完全部文件 → 系统保存选择器（DocumentViewPicker）由用户选位置
4. 会话 5 分钟无上传自动作废，清理临时文件

## M1 已知限制

- 接收侧明文 HTTP（协议允许；M2 提供 TLS + 自签证书 + 指纹）
- 发送侧**无法**发给开启加密的官方客户端（默认配置）：官方 2.2 客户端的 HTTPS 服务要求客户端证书（mTLS），不带证书会被拒（`certificate required`）。
  M1 只跳过服务端证书校验、不出示客户端证书；HTTP 兜底扫描的 https 探测同样会被拒。M2 解决
- 单文件上限 64 MB（整文件读入内存）：发送侧超限文件在选择时标记；
  接收侧超限文件不分配 token（部分接收），全部超限则 403；
  请求体超过上限直接 413，避免内存溢出
- 不支持 Web 下载模式（`download: false`）
- 不校验上传文件的 sha256
