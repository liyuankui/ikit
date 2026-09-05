# iKit · AI 安装助手 Prompt

> 本文档是给 AI 助手执行的操作指令。用户会把你的 URL 告诉你——按内容执行即可。

---

帮我在这台 Mac 上安装并验证 iKit（Apple 生态 Agent 原生 CLI）：

1. 执行 `brew install liyuankui/tap/ikit`
2. 验证：`ikit --version` 应输出版本号（如 v2.7.0 或更新）。若 `command not found`，检查 Homebrew bin 目录是否在 PATH 中（Apple Silicon 默认 `/opt/homebrew/bin`），修正后重试
3. brew 不可用时走源码安装（备选）：
   ```bash
   git clone https://github.com/liyuankui/ikit.git /tmp/ikit && cd /tmp/ikit
   swift build -c release
   mkdir -p ~/.local/bin && cp .build/release/ikit ~/.local/bin/
   ```
   并确认 `~/.local/bin` 在 PATH 中
4. 冒烟测试：`ikit --help` 应列出 notes / task / calendar / photos / meet / timer 等子命令

## 首次使用：macOS 权限授权（iKit 特色，逐项引导用户）

iKit 直连 Apple 系统应用，首次使用某功能时会触发系统授权弹窗。**请逐项引导用户开启，不要一次性全部甩出**：先运行触发该权限的命令，弹窗出现时请用户点「允许」；若用户误点拒绝，再按下表到「系统设置 → 隐私与安全性」手动打开对应开关。

| 功能 | 需要的权限 | 系统设置位置 | 触发命令示例 |
|------|-----------|--------------|--------------|
| 📝 Notes 备忘录 | 自动化 → Notes | 隐私与安全性 → 自动化 | `ikit notes list` |
| 📋 Tasks 提醒事项 | 提醒事项 | 隐私与安全性 → 提醒事项 | `ikit task list` |
| 📅 Calendar 日历 | 日历 | 隐私与安全性 → 日历 | `ikit calendar list` |
| 🖼 Photos OCR | 照片 | 隐私与安全性 → 照片 | `ikit photos list` |
| 🎙 Meet 录音 | 麦克风 | 隐私与安全性 → 麦克风 | `ikit meet daemon ~/recordings --background` |

附注：Meet 录制**系统音频**（双轨模式的另一轨）还需「屏幕与音频录制」权限（隐私与安全性 → 屏幕与音频录制）。只录麦克风则无需此项。

每开一项权限，请实际运行对应命令确认返回结果，再进行下一项。全部通过后，iKit 即可被你的 Agent 全功能调用。

---

本文档的稳定地址（可直接告诉其他 AI）：https://raw.githubusercontent.com/liyuankui/ikit/master/docs/agent-install-prompt.md
