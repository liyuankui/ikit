# Task Plan: iKit 目录结构重构 v3

## Goal
实现简洁的 `~/.ikit/` 目录结构，与子命令保持一致，由 iKit 自管理。

## Current Phase
Phase 2: 完善 init 命令

## Phases

### Phase 1: IKitDir 类和 init 命令 ✅
- [x] 创建 `IKitDir` 类
- [x] 实现 `ikit init` 命令
- [x] 更新 session-resume.txt 路径
- [x] **Status:** complete

### Phase 2: 完善 init 和 transcribe 提示
- [ ] init 添加模型下载提示
- [ ] transcribe 检测并显示模型缓存
- [ ] **Status:** in_progress

### Phase 3: Timer 完整迁移
- [ ] 更新所有 timer 相关路径
- [ ] 实现 history.json
- [ ] **Status:** pending

### Phase 4: Meet 迁移
- [ ] 更新录音路径到 `~/.ikit/meet/sessions/`
- [ ] 实现会话状态管理
- [ ] **Status:** pending

### Phase 5: 其他功能
- [ ] Note 缓存
- [ ] Claude sessions
- [ ] 主日志路径
- [ ] **Status:** pending

### Phase 6: 测试
- [ ] 测试 init 命令
- [ ] 测试各功能路径
- [ ] **Status:** pending

## 目录结构

```
~/.ikit/
├── timer/     ← ikit timer
├── meet/      ← ikit meet
├── note/      ← ikit note
├── claude/    ← ikit claude (新)
├── logs/      ← 通用
├── config/    ← ikit config
└── run/       ← 运行时状态
```

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| 不考虑兼容性 | 直接使用新路径，服务未上线 |
| 子目录对应子命令 | 保持一致性 |
| IKitDir 统一管理 | 目录操作收口 |
| `ikit init` 创建目录 | 不下载模型，只提示 |
| 模型保持 `~/.cache/` | Python 标准做法，不迁移 |
| transcribe 提示模型 | 检测并显示缓存状态 |

## 模型处理

| 操作 | 位置 | 说明 |
|------|------|------|
| 下载 | 自动 | 首次 transcribe 时 Python 库自动下载 |
| 缓存 | `~/.cache/modelscope/` + `~/.cache/huggingface/` | 保持不变 |
| 检测 | transcribe 启动时 | 显示模型缓存大小和状态 |
| 管理 | 不管理 | 用 huggingface-cli 手动管理（可选） |
