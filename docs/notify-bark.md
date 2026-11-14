# iKit Notify：Mac → iPhone 推送（Bark 通道）

> 2026-11-14 · 背景：Mac 侧自动化/agent 任务完成后通知手机。选型 Bark（App Store 免费、APNs 秒推、无开发者账号要求、支持端到端加密与自托管）。

## 数据流

```text
ikit notify "标题" "内容" [--tpl 模板]
  → AES-128-CBC 加密（密钥只在 Mac 与 iPhone 两端，服务器只见密文）
  → POST ciphertext+iv → https://api.day.app/<device_key>
  → APNs 秒推 → Bark App 解密展示（按 group 分组 / level 定打扰级别）
```

## 一次性配置（已完成 2026-11-14）

1. iPhone 装 Bark（免费）→ App 首页复制 key
2. `ikit config set bark_key <key>`（22 位左右短串；**不是** 64 位十六进制——那类串不在服务器设备库里，推送会报 `failed to get device token`）
3. `ikit config set bark_crypt_key <16字符>`（加密开关；同一串需粘贴到 Bark App「我的 → 推送加密」，两边一致才能解密）
4. 测试：`ikit notify "测试" "hello"`——手机显示「解密失败」= 两端 key 不一致或 IV 格式错；正常显示 = 闭环

## 模板（--tpl，默认 done）

| 模板 | 场景 | level | 声音 | 分组 | 其他 |
|------|------|-------|------|------|------|
| `done` | 任务完成 | active | calm | iKit | 留档 |
| `fail` | 失败/需人工 | timeSensitive（专注模式也显示） | bell | iKit-fail | 副标题「需处理」，留档 |
| `digest` | 例行简报 | passive（不亮屏，进列表） | — | iKit-digest | 副标题「例行」，留档 |
| `urgent` | 紧急 | critical（穿透静音，需 App 内授权「重要警告」） | alert | iKit-urgent | 音量 5 |
| `action` | 需点击处理 | active | minuet | iKit | 配 `--url`/`--copy` |

覆盖参数：`--level/--sound/--group/--subtitle/--url/--copy/--icon/--volume/--markdown/--no-archive`（全参数见 [bark.day.app/#/params](https://bark.day.app/#/params)；全部兼容加密模式）。

```bash
ikit notify "转录完成" "meet-11-14.md 已落盘"
ikit notify --tpl digest "晨报已生成" "❤️ HRV 33ms"
ikit notify --tpl action "PR 等你 review" --url "https://github.com/…" --copy "gh pr checkout 42"
```

## 推荐接入点

- xianchong 晨报生成后：`ikit notify --tpl digest "晨间简报已生成" "<恢复雷达一行>"`（晨报自动化 prompt 加一步）
- 长任务（meet 转录/health 断流监控/批量 OCR）：完成 `done`、异常 `fail`
- 例行任务的失败重试链（如 Readwise 简报 no-op 之外的状态）：`fail`

## 加密实现要点（踩坑记录）

- 算法：AES-128-CBC + PKCS7；key = 配置字符串的 **ASCII 字节**（16 字节）
- **IV 协议格式是坑**：`iv` 参数必须是 **16 个 ASCII 字符的字符串**，App 直接取其字节当 IV——发 32 位 hex 字符串会被截成前 16 个 ASCII 字节 → 必然「解密失败」（2026-11-14 实测修复）
- 密文 base64 后需 form 编码（`+` `/` `=`）；`IKIT_BARK_KEY` 环境变量可临时覆盖 device key
- 隐私边界：默认服务器 api.day.app 只见密文；敏感场景可 `bark_server` 切自托管

## 故障排查

| 症状 | 原因 | 处理 |
|------|------|------|
| `failed to get device token` | device key 无效（如误用 64 位 hex） | App 首页重抄 key → `config set bark_key` |
| 手机收到但显示「解密失败」 | 两端 crypt key 不一致 / IV 格式错 | App「推送加密」重粘 key；或升级 iKit（旧版 IV bug） |
| 推送成功但没亮屏 | level=passive 或系统聚焦 | 预期行为（digest 模板）；urgent 需 App 授权「重要警告」 |
| urgent 不穿透静音 | App 未授权重要警告 | Bark App 设置 → 重要警告 → 允许 |
