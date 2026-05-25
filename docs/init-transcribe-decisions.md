# Init 和 Transcribe 模型处理决策

## 决策

### 1. init 命令
- **只创建目录结构**
- **不下载模型**
- 添加提示：首次使用 transcribe 时会自动下载模型

```bash
$ ikit init
✅ iKit 目录已创建: ~/.ikit/
  ├─ timer/
  ├─ meet/
  ├─ note/
  ├─ claude/
  ├─ logs/
  ├─ config/
  └─ run/

💡 提示: 首次运行 ikit meet transcribe 时会自动下载 ASR 模型 (~12GB)
```

### 2. transcribe 首次运行
- 检测模型缓存
- 显示模型状态
- 如果缺失，让 Python 库自动下载

```bash
$ ikit meet transcribe sys.m4a mic.m4a
⚡️ 检测 ASR 模型缓存...
   ✅ ModelScope: 4.9GB (FunASR - 中文)
   ✅ HuggingFace: 7.4GB (Whisper, MLX, pyannote - 英文)
📝 开始转录...
```

### 3. 可选：ikit doctor 命令
```bash
$ ikit doctor
🔍 系统检查
✅ Python: 3.13.1
✅ FunASR: 已安装
✅ MLX-Whisper: 已安装
✅ WhisperX: 已安装
✅ pyannote: 已安装

💾 模型缓存:
  ✅ ModelScope: 4.9GB
  ✅ HuggingFace: 7.4GB
  📊 总计: ~12GB
```

## 模型缓存位置（保持不变）

| 引擎 | 位置 | 大小 |
|------|------|------|
| FunASR | `~/.cache/modelscope/` | 4.9GB |
| MLX/WhisperX/pyannote | `~/.cache/huggingface/hub/` | 7.4GB |

## 不做的事

- ❌ init 时后台下载模型
- ❌ 迁移模型到 `~/.ikit/`
- ❌ 符号链接模型目录
