# Roadmap

## M0 — 代码骨架（已完成 / this repo）

- [x] 工程结构（DevEco Studio 可打开的 HarmonyOS NEXT 工程，API 12）
- [x] 协议层：多播发现 + HTTP 兜底 + Dto 兼容处理
- [x] HTTP/1.1 服务端（TCP + 路由 + chunked 支持）
- [x] 接收/发送完整流程 + 四页 UI（中英双语）
- [x] 文档：协议实现说明 / 架构 / 本路线图

## M1 — 真机可用（当前阶段）

- [x] 静态审查修正（未编译）：补 `oh-package.json5`、`GET_NETWORK_INFO` 权限、
      ArkTS 严格模式写法、保存到文档 URI、设置页 PIN 被清空、超大请求体 OOM 等
- [x] 发送侧改用 rcp：可直连默认开启加密（HTTPS）的官方客户端
- [x] PC 端测试对端 `tools/lspeer.py`（发现/收/发/场景脚本）
- [ ] 构建通过（DevEco Studio 或 Linux Command Line Tools），修复编译问题
- [ ] 真机 ↔ 桌面版 LocalSend 双向互传验证
- [ ] 多播在真机上的行为验证（失败时确认 HTTP 兜底有效）
- [ ] 真实 Wi-Fi 环境下 PIN、拒绝、取消、并发场景测试
- [ ] 修复实测暴露的问题，发布 0.1.x

## M2 — 加密传输

- [ ] 运行时生成 RSA-2048 自签名证书（cryptoFramework 生成密钥 +
      手写 X.509 DER 编码，`CN=LocalSend User`，与官方一致）
- [ ] `TLSSocketServer` 替换 `TCPSocketServer`（PEM 注入）
- [ ] 发送侧切换 rcp（`remoteValidation` 自定义校验），
      实现指纹 TOFU + 已知指纹固定
- [ ] 指纹迁移：随机 UUID → 证书 SHA-256（大写 hex）
- [ ] 上传文件 sha256 校验（mismatch → 422）

## M3 — 体验完善

- [ ] 大文件流式/分块上传，解除 64 MB 限制
- [ ] 照片/视频快速保存到媒体库（SaveButton + MediaAssetChangeRequest）
- [ ] `DATA_TRANSFER` 长时任务 + 进度通知（后台接收）
- [ ] Web 下载模式（`download: true` + `/prepare-download` + `/download`）
- [ ] 部分接收（选文件子集）、接收历史

## M4+ — 生态扩展（可选）

- [ ] 其他平台原生客户端（或与官方 LocalSend 桌面端互补定位）
- [ ] 鸿蒙特性：系统分享接收（share sheet）、平板/折叠屏适配
- [ ] CI（需 Linux 版构建工具链验证）
