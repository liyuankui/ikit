# Task Plan: iKit Meet Daemon 可靠性改进

## Goal
实现 iKit Meet Daemon 的可靠后台录音功能，解决进程意外中断、参数歧义和状态管理问题。

## Current Phase
Phase 5 - Testing

## Phases

### Phase 1: P0 - 信号处理与 Interval 单位 (Critical)
- [x] 实现 SIGTERM/SIGINT/SIGHUP 信号处理
- [x] 实现优雅退出（保存录音、合并片段）
- [x] 明确 interval 参数单位（支持 60s/5m/1h 格式）
- [x] 保持向后兼容（旧格式仍可用，显示警告）
- **Status:** complete

### Phase 2: P1 - 真正的 Background 模式与状态管理
- [x] 实现后台 daemon 启动（使用 nohup/PID 文件）
- [x] 创建 PID 文件管理（~/.config/ikit/meet.pid）
- [x] 实现 `ikit meet status` 命令
- [x] 实现 `ikit meet stop` 命令
- [x] 添加 daemon 日志文件
- **Status:** complete

### Phase 3: P2 - 日志持久化与预检查
- [x] 实现日志文件持久化（daemon.log）
- [x] 添加心跳文件（.heartbeat）
- [x] 实现启动前预检查（权限、磁盘空间、FunASR）
- [x] 改进错误提示信息
- **Status:** complete

### Phase 4: P3 - 配置文件支持
- [x] 设计 meet 配置结构
- [x] 实现 ~/.config/ikit/config.json 的 meet 部分
- [x] 支持默认配置
- **Status:** complete

### Phase 5: 测试与验证
- [x] 编写 E2E 测试用例
- [x] 测试后台运行稳定性
- [x] 测试信号处理（优雅退出）
- [x] 测试状态命令
- [x] 更新文档
- **Status:** complete

## Overall Status: ✅ COMPLETE

All 5 phases completed successfully:
- Phase 1: Signal handling & interval units ✅
- Phase 2: Background mode & status management ✅
- Phase 3: Log persistence & pre-flight checks ✅
- Phase 4: Config file support ✅
- Phase 5: Testing & verification ✅

## Key Questions

1. **Interval 参数兼容性**: 如何保持旧 API 兼容？
   - 方案: 旧格式 `--interval=60` 继续工作，显示警告提示使用新格式

2. **后台运行方式**: 使用 launchd 还是 nohup？
   - 方案: 先用 nohup + PID 文件（简单），后续可升级 launchd

3. **日志文件位置**: daemon.log 放在哪里？
   - 方案: 放在录音目录下，与录音文件一起

4. **状态检查频率**: status 命令如何获取实时状态？
   - 方案: 读取 PID 文件 + 检查进程存在 + 读取心跳文件

## Decisions Made

| Decision | Rationale |
|----------|-----------|
| Interval 单位后缀 (60s/5m/1h) | 明确无歧义，用户友好 |
| nohup + PID 文件实现后台 | 简单可靠，无需额外依赖 |
| 日志文件放在录音目录 | 便于问题排查，与录音一起归档 |
| 心跳文件每 10 秒更新 | 快速检测崩溃，低开销 |
| 保持旧 API 兼容 | 向后兼容，平滑迁移 |

## Errors Encountered

| Error | Attempt | Resolution |
|-------|---------|------------|
| | 1 | |

## Notes

- 优先实现 P0 功能（信号处理 + interval 单位）
- Phase 1 完成后再处理 Phase 2
- 每个阶段完成后更新 findings.md
- 所有代码改动记录在 progress.md
- 保持单文件架构（main.swift）
