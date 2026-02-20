#!/usr/bin/env python3
"""
会议纪要生成器
- 说话人识别（spk0/spk1 分析）
- 增量识别（记住说话人映射）
- 生成符合模板的会议纪要
"""

import json
import re
import time
import requests
import sys
import os
from pathlib import Path
from datetime import datetime
from collections import defaultdict, Counter
from typing import Dict, List, Tuple

# Retry configuration
MAX_RETRIES = 3
RETRY_DELAYS = [2, 4, 8]  # Exponential backoff: 2s, 4s, 8s
RETRY_STATUS_CODES = {429, 500, 502, 503, 504}  # Status codes that trigger retry

# 添加 scripts 目录到路径
script_dir = Path(__file__).parent
sys.path.insert(0, str(script_dir))

try:
    from speaker_mapper import SpeakerMapper, interactive_mapping
    SPEAKER_MAPPER_AVAILABLE = True
except ImportError:
    SPEAKER_MAPPER_AVAILABLE = False
    print("⚠️  speaker_mapper 不可用，将使用基础模式")


class MeetingSummaryGenerator:
    def __init__(self, recording_dir: str, date: str, session: str = None):
        self.recording_dir = Path(recording_dir)
        self.date = date
        self.session = session  # 会议时段 (morning/afternoon/full)
        self.speaker_stats = defaultdict(lambda: {"count": 0, "words": 0, "first_mention": None})
        self.timeline = []
        self.all_sentences = []

        # 初始化说话人映射器
        self.speaker_mapper = SpeakerMapper() if SPEAKER_MAPPER_AVAILABLE else None
        self.speaker_mapping = {}  # spk_id -> 姓名（从映射器加载）

        # 加载已有映射
        self._load_existing_mappings()

    def _load_existing_mappings(self):
        """从映射器加载已有映射（按会议）"""
        if self.speaker_mapper:
            meeting_mappings = self.speaker_mapper.get_meeting_mappings(self.date, self.session or "")
            for spk_key, info in meeting_mappings.items():
                if "name" in info:
                    self.speaker_mapping[int(spk_key)] = info["name"]

    def get_speaker_name(self, spk_id: int) -> str:
        """获取说话人显示名称"""
        if spk_id in self.speaker_mapping:
            return self.speaker_mapping[spk_id]
        return f"spk {spk_id}"

    def import_speakers_to_mapper(self):
        """将当前说话人导入到映射器"""
        if self.speaker_mapper:
            spk_ids = list(self.speaker_stats.keys())
            self.speaker_mapper.import_speakers_to_meeting(self.date, self.session or "", spk_ids)
            print(f"✅ 已将 {len(spk_ids)} 位说话人导入到映射器")
        """将当前说话人导入到映射器（待后续确认）"""
        if self.speaker_mapper:
            spk_ids = list(self.speaker_stats.keys())
            self.speaker_mapper.import_from_meeting(self.date, spk_ids)
            print(f"✅ 已将 {len(spk_ids)} 位说话人导入到映射器")

    def load_transcripts(self, file_patterns: List[str]) -> int:
        """加载转录文件"""
        for pattern in file_patterns:
            files = sorted(self.recording_dir.glob(pattern))
            for filepath in files:
                try:
                    with open(filepath, 'r', encoding='utf-8') as f:
                        data = json.load(f)
                        if 'sentences' in data:
                            self._process_sentences(data['sentences'], filepath.name)
                except Exception as e:
                    print(f"⚠️  跳过文件 {filepath}: {e}")

        return len(self.all_sentences)

    def _process_sentences(self, sentences: List[Dict], source_file: str):
        """处理句子，提取时间线"""
        for sent in sentences:
            spk = sent.get('spk', -1)
            text = sent.get('text', '').strip()
            start_ms = sent.get('start', 0)
            end_ms = sent.get('end', 0)

            if not text:
                continue

            # 转换时间戳为 HH:MM:SS
            start_time = self._ms_to_time(start_ms)

            # 统计说话人信息
            self.speaker_stats[spk]["count"] += 1
            self.speaker_stats[spk]["words"] += len(text)
            if self.speaker_stats[spk]["first_mention"] is None:
                self.speaker_stats[spk]["first_mention"] = start_time

            # 添加到时间线（每句话）
            self.timeline.append({
                "time": start_time,
                "speaker": f"spk {spk}",
                "text": text,
                "speaker_id": spk
            })

            # 保存完整句子
            self.all_sentences.append({
                "speaker": f"spk {spk}",  # 将在生成时替换为实际姓名
                "speaker_id": spk,
                "text": text,
                "time": start_time,
                "source": source_file
            })

    def _ms_to_time(self, ms: int) -> str:
        """毫秒转 HH:MM:SS 格式"""
        hours = ms // 3600000
        minutes = (ms % 3600000) // 60000
        seconds = (ms % 60000) // 1000
        return f"{hours:02d}:{minutes:02d}:{seconds:02d}"

    def analyze_speakers(self) -> Dict:
        """分析说话人特征，推测角色"""
        analysis = {}

        for spk_id, stats in self.speaker_stats.items():
            avg_words = stats["words"] / stats["count"] if stats["count"] > 0 else 0

            # 简单的角色推测（基于发言模式）
            role = "待确认"
            if avg_words > 50:
                role = "主要发言者（可能是主持人/汇报人）"
            elif avg_words < 10:
                role = "简短回应者（可能是听众/偶尔发言）"
            else:
                role = "积极参与讨论者"

            analysis[spk_id] = {
                "发言次数": stats["count"],
                "总字数": stats["words"],
                "平均字数": f"{avg_words:.1f}",
                "首次发言": stats["first_mention"],
                "推测角色": role
            }

        return analysis

    def identify_keywords(self) -> Dict[str, List[Tuple[str, str, str]]]:
        """识别关键发言：想法、建议、行动"""
        keywords = {
            "想法": ["认为", "觉得", "看法", "观点", "我认为", "我觉得"],
            "建议": ["建议", "提议", "可以", "应该", "最好是", "不如"],
            "行动": ["我来", "我去", "负责", "跟进", "联系", "安排", "做一下", "弄一下"],
            "疑问": ["为什么", "怎么", "如何", "是不是", "对吗", "什么"],
            "同意": ["对", "是的", "好的", "没错", "同意", "可以"]
        }

        findings = {k: [] for k in keywords.keys()}

        for sent in self.all_sentences:
            text = sent["text"]
            speaker_id = sent["speaker_id"]
            speaker_name = self.get_speaker_name(speaker_id)
            time = sent["time"]

            for category, patterns in keywords.items():
                for pattern in patterns:
                    if pattern in text:
                        findings[category].append((time, speaker_name, text))
                        break

        return findings

    def generate_summary(self, llm_url: str = "http://localhost:11434/api/generate",
                        llm_model: str = "qwen3:4b") -> str:
        """生成会议纪要"""

        # 分析说话人
        speaker_analysis = self.analyze_speakers()

        # 识别关键发言
        key_findings = self.identify_keywords()

        # 构建时间线摘要（每5分钟或关键话题）
        timeline_summary = self._build_timeline_summary()

        # 准备 LLM prompt
        prompt = self._build_prompt(speaker_analysis, key_findings, timeline_summary)

        # 调用 LLM 生成纪要
        summary, success = self._call_llm(prompt, llm_url, llm_model)

        # 组合最终输出
        output = self._format_output(speaker_analysis, timeline_summary, summary, success)

        return output

    def _build_timeline_summary(self, interval_minutes: int = 5) -> List[Dict]:
        """构建时间线摘要"""
        # 按时间间隔合并
        summary = []
        current_batch = []
        last_time = None

        for item in self.timeline:
            if last_time is None:
                current_batch.append(item)
                last_time = item["time"]
                continue

            # 检查是否超过间隔
            if self._time_diff_minutes(last_time, item["time"]) >= interval_minutes:
                # 合并当前批次
                if current_batch:
                    summary.append(self._merge_timeline_batch(current_batch))
                current_batch = [item]
                last_time = item["time"]
            else:
                current_batch.append(item)

        # 处理最后一批
        if current_batch:
            summary.append(self._merge_timeline_batch(current_batch))

        return summary

    def _time_diff_minutes(self, time1: str, time2: str) -> float:
        """计算时间差（分钟）"""
        h1, m1, s1 = map(int, time1.split(':'))
        h2, m2, s2 = map(int, time2.split(':'))
        diff = (h2 * 3600 + m2 * 60 + s2) - (h1 * 3600 + m1 * 60 + s1)
        return diff / 60

    def _merge_timeline_batch(self, batch: List[Dict]) -> Dict:
        """合并一个时间批次的发言"""
        if not batch:
            return {}

        # 取开始时间
        start_time = batch[0]["time"]

        # 按说话人分组
        by_speaker = defaultdict(list)
        for item in batch:
            by_speaker[item["speaker_id"]].append(item["text"])

        # 生成摘要（使用映射的姓名）
        speakers_summary = []
        for spk_id, texts in by_speaker.items():
            combined = " ".join(texts)
            # 截断长文本
            if len(combined) > 100:
                combined = combined[:97] + "..."
            speaker_name = self.get_speaker_name(spk_id)
            speakers_summary.append(f"{speaker_name}: {combined}")

        return {
            "time": start_time,
            "summary": "; ".join(speakers_summary)
        }

    def _build_prompt(self, speaker_analysis: Dict, key_findings: Dict, timeline_summary: List[Dict]) -> str:
        """构建 LLM prompt（优化大小）"""
        # 提取最有价值的信息
        key_speakers = sorted(speaker_analysis.items(), key=lambda x: x[1]["发言次数"], reverse=True)[:3]

        prompt = """你是一个专业的会议记录员。请根据以下会议信息，生成符合指定模板的会议纪要。

【会议概况】
"""

        prompt += f"- 总发言数: {len(self.all_sentences)} 条\n"
        prompt += f"- 说话人数: {len(speaker_analysis)} 位\n\n"

        prompt += "【主要说话人】\n"
        for spk_id, stats in key_speakers:
            speaker_name = self.get_speaker_name(spk_id)
            prompt += f"- {speaker_name} (spk {spk_id}): {stats['发言次数']}次发言，{stats['推测角色']}\n"

        # 只选择最关键的建议和行动
        prompt += "\n【关键建议】(前3条)\n"
        for time, speaker, text in key_findings.get("建议", [])[:3]:
            prompt += f"- [{time}] {speaker}: {text[:50]}...\n"

        prompt += "\n【关键行动】(前3条)\n"
        for time, speaker, text in key_findings.get("行动", [])[:3]:
            prompt += f"- [{time}] {speaker}: {text[:50]}...\n"

        # 添加说话人映射信息
        if self.speaker_mapping:
            prompt += "\n【说话人映射】\n"
            for spk_id, name in self.speaker_mapping.items():
                prompt += f"- spk {spk_id} = {name}\n"

        prompt += "\n【会议进程】\n"
        for item in timeline_summary[:10]:  # 减少到10条
            # 截断过长的摘要
            summary = item['summary']
            if len(summary) > 150:
                summary = summary[:147] + "..."
            prompt += f"- [{item['time']}] {summary}\n"

        prompt += """
请根据以上信息，生成完整的会议纪要。要求：
1. 全程使用中文
2. 说话人请使用实际姓名（如果已映射），否则用 "spk 0", "spk 1" 表示
3. 不确定的地方标注"（存疑：...）"
4. 执行摘要要简洁有力（3-5句话）
5. 主要讨论点要区分发起人和参与讨论的人
6. 决策事项和行动项要标注负责人
7. 时间线放在最后

注意：如果说话人已映射到姓名，请在纪要中使用姓名而非 spk X。

输出格式：

# 会议纪要

**日期**: [YYYY-MM-DD]
**时间**: [HH:MM] - [HH:MM]
**参会人员**: [待OCR识别后补充]

---

## 一、执行摘要（Executive Summary）

[3-5句话概括会议核心内容]

**会议目的**: [为什么开这个会]

**关键结论**: [会议达成的最重要的结论]

**下一步行动**: [最重要的1-2个行动项]

---

## 二、会议主题

[一句话概括会议讨论的核心话题]

---

## 三、主要讨论点

### 3.1 [话题一]
- **发起人**: spk X
- **核心观点**: ...
- **讨论过程**:
  - spk Y 提出：...
  - spk Z 补充：...
- **结论**: ...

（更多话题...）

---

## 四、决策事项

| 决策内容 | 提出人 | 备注 |
|----------|--------|------|
| [决策1] | spk X | ... |
| [决策2] | spk Y | ... |

---

## 五、行动项

| 行动内容 | 负责人 | 截止时间 | 状态 |
|----------|--------|----------|------|
| [ ] [行动1] | spk X | - | 待办 |
| [ ] [行动2] | spk Y | - | 待办 |

---

## 六、说话人对照表（待OCR识别确认）

| 编号 | 发言特征 | 推测角色 |
|------|----------|----------|
| spk 0 | [发言次数X次，平均字数Y] | [角色] |
| spk 1 | [发言次数X次，平均字数Y] | [角色] |

> **注意**: 当前说话人为 AI 识别的 spk0/spk1，需要结合会议截图 OCR 识别后确认具体姓名。

---

## 七、存疑/待确认

- [存疑点1] - [原因：转录不清晰/上下文缺失等]
- [存疑点2] - [原因：...）

---

## 八、会议时间线（Timeline）

| 时间 | 说话人 | 内容摘要 |
|------|--------|----------|
[详细时间线]

请直接输出会议纪要，不要有任何额外的解释或开场白。
"""

        return prompt

    def _call_llm(self, prompt: str, url: str, model: str) -> Tuple[str, bool]:
        """调用 LLM 生成内容，返回 (结果, 是否成功)

        Includes retry logic with exponential backoff for transient failures.
        """
        last_error = None

        for attempt in range(MAX_RETRIES + 1):
            try:
                response = requests.post(
                    url,
                    json={
                        "model": model,
                        "prompt": prompt,
                        "stream": False
                    },
                    timeout=180
                )

                # Check for retryable status codes
                if response.status_code in RETRY_STATUS_CODES:
                    if attempt < MAX_RETRIES:
                        delay = RETRY_DELAYS[attempt]
                        print(f"⚠️  LLM调用返回 {response.status_code}，{delay}秒后重试 (尝试 {attempt + 1}/{MAX_RETRIES})...")
                        time.sleep(delay)
                        continue
                    else:
                        print(f"⚠️  LLM调用失败: HTTP {response.status_code} (已重试 {MAX_RETRIES} 次)")
                        return "", False

                result = response.json()
                content = result.get("response", "")

                # 检查是否有效响应
                if content and len(content) > 100 and not content.startswith("["):
                    return content, True
                else:
                    return "", False

            except requests.exceptions.Timeout:
                last_error = "请求超时"
                if attempt < MAX_RETRIES:
                    delay = RETRY_DELAYS[attempt]
                    print(f"⚠️  LLM调用超时，{delay}秒后重试 (尝试 {attempt + 1}/{MAX_RETRIES})...")
                    time.sleep(delay)
                continue
            except requests.exceptions.ConnectionError as e:
                last_error = f"连接错误: {e}"
                if attempt < MAX_RETRIES:
                    delay = RETRY_DELAYS[attempt]
                    print(f"⚠️  LLM连接失败，{delay}秒后重试 (尝试 {attempt + 1}/{MAX_RETRIES})...")
                    time.sleep(delay)
                continue
            except Exception as e:
                last_error = str(e)
                break

        print(f"⚠️  LLM调用失败: {last_error}")
        return "", False

    def _format_output(self, speaker_analysis: Dict, timeline_summary: List[Dict], llm_summary: str, llm_success: bool) -> str:
        """格式化最终输出"""
        # 如果 LLM 失败，生成改进的备用版本
        if not llm_success:
            return self._generate_fallback_summary(speaker_analysis, timeline_summary)

        return llm_summary

    def _generate_fallback_summary(self, speaker_analysis: Dict, timeline_summary: List[Dict]) -> str:
        """生成备用摘要（LLM失败时）"""
        key_findings = self.identify_keywords()

        # 找出主要说话人
        main_speakers = sorted(speaker_analysis.items(), key=lambda x: x[1]["发言次数"], reverse=True)[:3]

        lines = [
            "# 会议纪要",
            "",
            f"**日期**: {self.date}",
            "**时间**: [自动识别]",
            "**参会人员**: [待OCR识别后补充]",
            "",
            "---",
            "",
            "## 一、执行摘要（Executive Summary）",
            "",
            f"本次会议共识别 **{len(self.all_sentences)}** 条发言，涉及 **{len(speaker_analysis)}** 位说话人。",
            "",
            "**会议主题**: [待人工确认]（基于关键词分析推测）"
        ]

        # 添加推测主题
        if key_findings.get("建议"):
            lines.append(f"- 讨论了 {len(key_findings['建议'])} 个建议事项")
        if key_findings.get("行动"):
            lines.append(f"- 识别到 {len(key_findings['行动'])} 个行动项")

        lines.extend([
            "",
            "**关键结论**: [待人工补充]",
            "",
            "**下一步行动**: [见下方行动项]",
            "",
            "---",
            "",
            "## 二、会议主题",
            "",
            "[待人工确认 - 请根据时间线内容填写]",
            "",
            "---",
            "",
            "## 三、主要讨论点",
            "",
            "### 3.1 讨论要点（基于关键词识别）"
        ])

        # 添加识别到的建议
        if key_findings.get("建议"):
            lines.extend(["", "**建议事项**:"])
            for time, speaker, text in key_findings["建议"][:5]:
                lines.append(f"- [{time}] **{speaker}**: {text[:80]}...")

        # 添加识别到的疑问
        if key_findings.get("疑问"):
            lines.extend(["", "**提出的问题**:"])
            for time, speaker, text in key_findings["疑问"][:5]:
                lines.append(f"- [{time}] **{speaker}**: {text[:80]}...")

        lines.extend([
            "",
            "---",
            "",
            "## 五、行动项（基于关键词识别）",
            "",
            "| 行动内容 | 提及人 | 时间 | 状态 |",
            "|----------|--------|------|------|"
        ])

        # 添加识别到的行动
        if key_findings.get("行动"):
            for time, speaker, text in key_findings["行动"][:10]:
                # 简化文本
                action = text[:60] + "..." if len(text) > 60 else text
                lines.append(f"| {action} | {speaker} | {time} | 待确认 |")
        else:
            lines.append("| [待人工补充] | - | - | 待办 |")

        lines.extend([
            "",
            "---",
            "",
            "## 六、说话人对照表（待OCR识别确认）",
            "",
            "| 编号 | 发言特征 | 推测角色 |",
            "|------|----------|----------|"
        ])

        for spk_id, stats in speaker_analysis.items():
            lines.append(f"| spk {spk_id} | {stats['发言次数']}次发言，平均{stats['平均字数']}字 | {stats['推测角色']} |")

        lines.extend([
            "",
            "---",
            "",
            "## 七、存疑/待确认",
            "",
            "- LLM 服务不可用，无法生成智能摘要",
            "- 说话人具体身份需要 OCR 识别或人工确认",
            "- 会议主题需要人工确认",
            "",
            "---",
            "",
            "## 八、会议时间线（Timeline）",
            "",
            "| 时间 | 说话人 | 内容摘要 |",
            "|------|--------|----------|"
        ])

        for item in timeline_summary:
            # 截断过长的摘要
            summary = item['summary']
            if len(summary) > 200:
                summary = summary[:197] + "..."
            lines.append(f"| {item['time']} | {summary} |")

        return "\n".join(lines)


def main():
    import sys
    import argparse

    parser = argparse.ArgumentParser(description="会议纪要生成器")
    parser.add_argument("recording_dir", help="录音目录路径")
    parser.add_argument("date", help="日期 (YYYY-MM-DD)")
    parser.add_argument("session", nargs="?", choices=["morning", "afternoon", "full"], help="会议时段")
    parser.add_argument("--interactive", "-i", action="store_true", help="交互式映射说话人")
    parser.add_argument("--import", action="store_true", dest="import_speakers", help="导入说话人到映射器")

    args = parser.parse_args()

    recording_dir = args.recording_dir
    date = args.date
    session = args.session

    generator = MeetingSummaryGenerator(recording_dir, date, session)

    # 根据session选择文件
    if session == "morning":
        patterns = ["*10*_merged.json", "*11*_merged.json", "*12*_merged.json"]
        output_name = "morning"
    elif session == "afternoon":
        patterns = ["*14*_merged.json", "*15*_merged.json", "*16*_merged.json"]
        output_name = "afternoon"
    else:
        patterns = ["*_merged.json"]
        output_name = "full"

    print(f"📂 正在读取转录文件...")
    count = generator.load_transcripts(patterns)
    print(f"✅ 已加载 {count} 条发言")

    print(f"📊 正在分析说话人...")
    speaker_analysis = generator.analyze_speakers()
    for spk_id, stats in speaker_analysis.items():
        name_info = f" ({generator.get_speaker_name(spk_id)})" if spk_id in generator.speaker_mapping else ""
        print(f"   spk {spk_id}{name_info}: {stats['发言次数']}次发言，{stats['推测角色']}")

    # 导入说话人到映射器
    if args.import_speakers:
        generator.import_speakers_to_mapper()

    # 交互式映射
    if args.interactive and SPEAKER_MAPPER_AVAILABLE:
        interactive_mapping(generator.speaker_mapper, date, session or "", dict(generator.speaker_stats))
        # 重新加载映射
        generator._load_existing_mappings()

    print(f"📝 正在生成会议纪要...")
    summary = generator.generate_summary()

    output_file = f"{recording_dir}/会议纪要-{output_name}.md"
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(summary)

    print(f"✅ 会议纪要已保存: {output_file}")

    # 显示说话人映射命令提示
    if not args.interactive and SPEAKER_MAPPER_AVAILABLE:
        print(f"\n💡 提示: 如需映射说话人姓名，可运行:")
        print(f"   python3 scripts/speaker_mapper.py set --date {date} --session {session or 'full'} --spk <spk_id> --name <姓名>")
        print(f"   python3 scripts/generate_meeting_summary.py {recording_dir} {date} {session or 'full'} --interactive")


if __name__ == "__main__":
    main()
