# ASR 方案对比：Qwen3-ASR vs FunASR

> **创建时间**: 2026-02-18
> **目的**: 评估是否需要在 iKit 中引入 Qwen3-ASR 作为 FunASR 的替代/补充

---

## 快速结论

| 场景 | 推荐 | 原因 |
|------|------|------|
| **多人会议** | **FunASR** | 说话人分离必需 |
| **单人录音/播客** | **Qwen3-ASR** | 更高准确率 |
| **方言场景** | **Qwen3-ASR** | 22种方言支持 |
| **高并发服务** | **Qwen3-ASR-0.6B** | 2000x吞吐 |

**核心差异**: FunASR 支持说话人分离，Qwen3-ASR 不支持。两者互补而非替代。

---

## 基本信息

| 维度 | **Qwen3-ASR** | **FunASR** |
|------|---------------|------------|
| **开发者** | 阿里 Qwen 团队 | 阿里达摩院 |
| **GitHub** | [QwenLM/Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) | [modelscope/FunASR](https://github.com/modelscope/FunASR) |
| **许可证** | Apache-2.0 | MIT |
| **基础架构** | LLM-based (Qwen3-Omni) | 传统 E2E ASR |
| **Python 包** | `pip install qwen-asr` | `pip install funasr` |

### 模型规格

| 维度 | **Qwen3-ASR-1.7B** | **Qwen3-ASR-0.6B** | **FunASR-paraformer** |
|------|-------------------|-------------------|----------------------|
| 参数量 | 1.7B | 0.6B | ~220M |
| 内存需求 | ~4GB | ~1.5GB | ~1GB |
| RTF | ~0.1 | ~0.05 | ~0.1-0.2 |
| 高并发吞吐 | 中等 | **2000x** (128并发) | 高 |

---

## 语言支持

| 维度 | **Qwen3-ASR** | **FunASR** |
|------|---------------|------------|
| 语言数量 | **30种语言** | 主要中英文 |
| 中国方言 | **22种** | 部分支持 |
| 口音适应 | 多国英语口音 | 有限 |
| 自动语言识别 | ✅ | ✅ |

**Qwen3-ASR 支持的方言**:
> 东北、粤语、闽南、吴语、四川、安徽、福建、甘肃、贵州、河北、河南、湖北、湖南、江西、宁夏、山东、陕西、山西、天津、云南、浙江

---

## 功能对比

| 功能 | **Qwen3-ASR** | **FunASR** |
|------|---------------|------------|
| **说话人分离** | ❌ **不支持** | ✅ **支持** |
| **时间戳** | ✅ (需 ForcedAligner) | ✅ 内置 |
| **流式推理** | ✅ | ✅ |
| **VAD** | ❓ 需外部 | ✅ 内置 |
| **ITN (数字转换)** | ❓ | ✅ |
| **标点恢复** | ✅ | ✅ |
| **情感识别** | ❌ | ✅ |
| **唱歌/歌曲识别** | ✅ **独有** | ❌ |
| **vLLM 支持** | ✅ **day-0** | ❌ |

---

## 性能基准 (WER ↓)

### 中文

| 测试集 | **Qwen3-ASR-1.7B** | **FunASR** | **Whisper-large-v3** |
|--------|-------------------|------------|---------------------|
| WenetSpeech | **4.97%** | 6.35% | 13.47% |
| AISHELL-2 | **2.71%** | 2.85% | 5.06% |
| SpeechIO | **2.88%** | 2.93% | 7.56% |
| 极端噪音 | **16.17%** | 36.55% | 63.17% |

### 英文

| 测试集 | **Qwen3-ASR-1.7B** | **FunASR** | **Whisper-large-v3** |
|--------|-------------------|------------|---------------------|
| Librispeech | **1.63%** | 2.78% | 3.56% |
| GigaSpeech | **8.45%** | - | 9.76% |

### 唱歌/歌曲 (Qwen3-ASR 独有)

| 测试集 | **Qwen3-ASR-1.7B** | **GPT-4o** |
|--------|-------------------|------------|
| M4Singer | **5.98%** | 16.77% |
| 完整歌曲(中) | **13.91%** | 34.86% |

---

## 代码示例

### Qwen3-ASR

```python
from qwen_asr import Qwen3ASRModel
import torch

# vLLM 后端 (推荐)
model = Qwen3ASRModel.LLM(
    model="Qwen/Qwen3-ASR-1.7B",
    gpu_memory_utilization=0.7,
    max_inference_batch_size=128,
    forced_aligner="Qwen/Qwen3-ForcedAligner-0.6B"  # 启用时间戳
)

results = model.transcribe(
    audio="audio.wav",
    language="Chinese",  # 或 None 自动检测
    return_time_stamps=True
)

for r in results:
    print(r['language'], r['text'], r['time_stamps'])
```

### FunASR

```python
from funasr import AutoModel

# 说话人分离模型
model = AutoModel(
    model="iic/speech_paraformer-large-vad-punc_asr_nat-zh-cn-16k-common-vocab8404-pytorch",
    # 说话人分离需要额外模型
    punc_model="iic/punc_ct-transformer_cn-en-common-vocab471067-large",
    spk_model="iic/speech_campplus_sv_zh-cn_16k-common"
)

result = model.generate(input="audio.wav")
```

---

## 部署方式

| 方式 | **Qwen3-ASR** | **FunASR** |
|------|---------------|------------|
| Python 包 | ✅ `qwen-asr` | ✅ `funasr` |
| vLLM | ✅ day-0 支持 | ❌ |
| Docker | ✅ `qwenllm/qwen3-asr` | ✅ |
| API 服务 | ✅ DashScope | ✅ ModelScope |
| OpenAI 兼容 API | ✅ | ❌ |

### Qwen3-ASR vLLM 服务

```bash
# 启动服务
qwen-asr-serve Qwen/Qwen3-ASR-1.7B --port 8000

# 或直接用 vllm
vllm serve Qwen/Qwen3-ASR-1.7B
```

---

## 对 iKit 的建议

### 当前状态

iKit `meet` 命令使用 FunASR 进行转写，支持：
- ✅ 说话人分离
- ✅ 时间戳
- ✅ VAD

### 升级建议

| 场景 | 建议 | 优先级 |
|------|------|--------|
| 保持多人会议支持 | 继续使用 FunASR | P0 |
| 单人录音场景 | 可选切换 Qwen3-ASR | P2 |
| 方言支持 | 添加 Qwen3-ASR 作为备选 | P2 |
| 流式对比测试 | 两者都测试，选择更优 | P1 |

### 实验计划

1. **A/B 测试**: 用同一段会议录音分别跑 FunASR 和 Qwen3-ASR
2. **对比指标**:
   - 中英混合准确率
   - 专有名词识别
   - 噪音环境表现
   - 处理速度 (RTF)
3. **结论**: 决定是否需要双引擎支持

---

## 参考资源

- [Qwen3-ASR GitHub](https://github.com/QwenLM/Qwen3-ASR)
- [Qwen3-ASR HuggingFace](https://huggingface.co/collections/Qwen/qwen3-asr)
- [Qwen3-ASR Blog](https://qwen.ai/blog?id=qwen3asr)
- [Qwen3-ASR Paper](https://arxiv.org/abs/2601.21337)
- [FunASR GitHub](https://github.com/modelscope/FunASR)

---

**Last Updated**: 2026-02-18
