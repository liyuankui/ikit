# iKit Health：iPhone 快捷指令导出方案

> issue #24 · 2026-11-13 · Mac 端 HealthKit 需付费开发者账号（免费 Personal Team 的 profile 不含 `com.apple.developer.healthkit`，launchd 在启动层拒绝，实测 error 163 / SIGKILL），故健康数据经 iPhone 侧导出，Mac 只读文件。

## 依赖（讲清楚）

| 层 | 依赖 | 必须？ | 说明 |
|----|------|--------|------|
| CLI 读取端 `ikit health` | 无第三方依赖 | — | 纯 Foundation 解析 JSON 落盘，`swift build` 即得；删掉全部数据文件也不影响其他模块 |
| 数据生产端（三选一） | Health Exporter & Shortcuts App（¥22 买断，**当前采用**） | ✅ 至少一种 | 备选：原生快捷指令（免费，路径 A）；heartbridge 不推荐（无睡眠、需 Mac 服务器常驻） |
| 传输 | iCloud Drive | ✅ | iPhone 与 Mac 同一 Apple ID + iCloud Drive 开启；目录契约 `iCloud Drive/iKit/health/` |
| iPhone 侧触发 | 快捷指令自动化 | ✅ | 定档：每天 **08:08**（Kyle 作息 7:30 起），Export Health Data 范围「**最近 30 天**」——快照自带滚动全史，prune 随时可清 |
| 下游 xianchong 恢复雷达 | `~/.local/bin/ikit`（`IKIT_BIN` 环境变量可覆盖） | 可选 | patch 已移交丰容管理员，apply 后晨报出现 `❤️ 恢复雷达` 行；无数据时静默降级 |

**数据形状（CLI 两种都收，同日多文件时后者覆盖前者）**：
1. Exporter 快照 `*_export_*.json`：多日多指标（`sleepTime[].stages` / `heartRateVariability[]` / `restingHeartRate[]` / `exerciseMinutes[]` 等 22 指标）——**当前生产格式**
2. 原生快捷指令单日 `health-YYYY-MM-DD.json`：schema 见下文

## 数据流

```text
Apple Watch → iPhone 健康 → 快捷指令「iKit Health Export」（每日 08:08 自动化）
  → iCloud Drive/iKit/health/health_export_*.json（30 天滚动快照）
  → Mac 同步（iCloud Drive）
  → ikit health today | trend | prune（xianchong 晨报经 scripts/lib/health.ts 调用）
```

> ⏰ **时序（2026-11-13 定档）**：导出 08:08（Kyle 7:30 起床，醒后缓冲保证睡眠会话完整 + Watch→iPhone 同步）；晨报 Kyle 自调至 8:18，中间 10 分钟为 iCloud 同步窗口。导出必须在起床后——人在睡时睡眠会话未结束，早于起床的档期拿到的是截断半宿数据。

## JSON Schema（除 `date` 外字段均可省略，CLI 渲染存在的部分）

```json
{
  "date": "2026-11-13",
  "generated_at": "2026-11-13T06:05:00+08:00",
  "sleep": {
    "asleep_minutes": 435,
    "deep_minutes": 95,
    "rem_minutes": 90,
    "bedtime": "2026-11-12 23:12",
    "wake": "2026-11-13 06:28"
  },
  "hrv": { "avg_ms": 48, "samples": 6 },
  "resting_hr": 53,
  "hr_zone": { "min": 45, "max": 165, "avg": 61 }
}
```

## iPhone 快捷指令搭建

> 两条路：**A. 手搓原生**（免费，隐私最优，起步版仅 8 个动作）；**B. [Health Exporter & Shortcuts](https://apps.apple.com/us/app/health-exporter-shortcuts/id6759006922) App**（$2.99≈¥22 买断、无内购；装好后快捷指令只要「它的 Export Health Data 动作 + 存储文件」两步；v1.7.0 起支持自动化无人值守，导出含 HRV/静息心率/睡眠）。第三方碰健康数据需自酌。

### 路径 A·起步版（先搭这个，约 5 分钟，8 个动作）

只做三件事：HRV 均值、静息心率、睡眠总分钟数。深睡/REM/心率区间以后再加。

1. 前提：iPhone 与本 Mac 使用**同一 Apple ID** 且 iCloud Drive 开启；Mac 端已建好 `iCloud Drive/iKit/health/` 目录。
2. 「快捷指令」App → 新建（＋）→ 命名 `iKit Health Export`。
3. 依次添加 8 个动作（英文 | 中文）：
   1. `Find Health Samples | 查找健康样本`：类型 `Heart Rate Variability`，周期 `过去 1 天`
   2. `Calculate Statistics | 计算统计`：`Average`，输入上一步结果（→ 变量「HRV均值」）
   3. `Find Health Samples`：类型 `Resting Heart Rate`，`过去 1 天`
   4. `Calculate Statistics`：`Average`（→ 变量「静息心率」）
   5. `Find Health Samples`：类型 `Sleep Analysis | 睡眠分析`，`过去 1 天`，`Filter | 筛选`：Value 包含 `Asleep`
   6. `Repeat with Each | 重复每个项目中`：内部放 `Get Time Between Dates | 获取两个日期间的时长`（Start Date → End Date，分钟），`Round | 四舍五入`，`Add to Variable | 添加到变量`（「睡眠分钟」，Repeat 前先 `Set Variable | 设置变量` 清零）
   7. `Text | 文本`：`{"date":"<Format Date yyyy-MM-dd>","hrv":{"avg_ms":<HRV均值>},"resting_hr":<静息心率>,"sleep":{"asleep_minutes":<睡眠分钟总和>}}`（尖括号处用魔法变量）
   8. `Save File | 存储文件`：文件名 `health-<日期>.json`，位置 `iCloud Drive → iKit → health`，关闭「存储前询问」
4. 首次运行弹「快捷指令」想读取健康数据 → **允许**。
5. 自动化：自动化 → 新建 → 特定时间 `07:45`、每天 → 运行 `iKit Health Export` → 「立即运行」（或用「起床时/睡眠专注结束」触发，贴合真实作息；日期范围动作里给固定值，锁屏也能跑完）。

### 路径 A·完整版（可选增强，在起步版基础上加）

- 深睡/REM 分钟：复制第 5-6 步，`Filter` 分别用 `Asleep (Deep)` / `Asleep (REM)` → 填入 `sleep.deep_minutes` / `sleep.rem_minutes`
- 就寝/起床时间、心率 24h 区间（min/max/avg 三个 Statistics）、`generated_at` 时间戳

### 路径 B·Exporter App（¥22 买断，**已选定并于 2026-11-13 验证跑通**）

1. App Store 装 [Health Exporter & Shortcuts](https://apps.apple.com/us/app/health-exporter-shortcuts/id6759006922)（$2.99/¥22 买断，无内购）
2. 打开 App 一次，授予健康数据读取权限
3. 「快捷指令」新建 `iKit Health Export`，两个动作：
   - 它提供的 `Export Health Data` 动作：数据类型全选或至少 HRV/静息心率/睡眠；日期范围**「最近 30 天」（固定值，切勿 Ask Each Time）**——快照自带全史，也解锁无脑 prune
   - `Save File | 存储文件`：接上一步输出的 JSON 文件，存 `iCloud Drive → iKit → health`，关闭「存储前询问」
4. 手动跑一次验证（首跑弹健康权限 → 允许），确认文件出现在 iCloud Drive/iKit/health/
5. 自动化：特定时间 `08:08` 每天 → 运行本快捷指令 → 「立即运行」
6. 日常维护：`ikit health prune --keep 7`（快照按类保留最新 N 个，其余进废纸篓；30 天窗口配置下随时可清）

> 定档 08:08 导出 / 8:18 晨报：10 分钟 iCloud 同步窗口通常足够（<2 分钟），但前两三天留意晨报 `❤️ 恢复雷达` 行是否出现——缺行即同步没跟上，可将晨报再延 10 分钟。某天缺数多为锁屏未触发或 iCloud 延迟，`ikit health` 会如实显示。

## 验证

```bash
ikit health            # 状态：目录、天数、最新日期
ikit health today      # 最新一天摘要
ikit health trend      # 7 日趋势表
```

xianchong 晨报头部将出现 `> ❤️ 恢复雷达：…`（数据 ≥4 天后给出 HRV 基线信号）。

## 故障排查

| 症状 | 原因 | 处理 |
|------|------|------|
| `no health drops found` | 快捷指令没跑过/没存对目录 | 手动跑一次；确认存到 `iKit/health/` |
| 目录在但文件迟迟不到 Mac | iCloud 同步延迟 | 等 1–2 分钟；Mac 端确认 iCloud Drive 正常 |
| 快捷指令取数全空 | 健康 App 无该类数据 / 权限被拒 | 设置→隐私与安全性→健康→快捷指令，开读取 |
| 一直为空且以上均正常 | iPhone 与 Mac 不同 Apple ID | 数据无法跨账号同步，需统一 |
