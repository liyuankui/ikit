#!/usr/bin/env python3
"""
说话人映射管理器
- 按会议存储说话人映射（spk_id -> 姓名）
- 支持增量学习
- 支持OCR识别参会人

重要：不同会议的 spk_id 是独立的，需要按会议标识区分
"""

import json
import os
from pathlib import Path
from datetime import datetime
from typing import Dict, List, Optional, Tuple
import subprocess
import re


class SpeakerMapper:
    """说话人映射管理器（按会议存储）"""

    def __init__(self, config_dir: str = None):
        if config_dir is None:
            config_dir = os.path.expanduser("~/.config/ikit")

        self.config_dir = Path(config_dir)
        self.config_dir.mkdir(parents=True, exist_ok=True)

        self.speakers_file = self.config_dir / "speakers.json"
        self.all_meetings = self._load_all_meetings()

    def _load_all_meetings(self) -> Dict:
        """加载所有会议映射"""
        if self.speakers_file.exists():
            try:
                with open(self.speakers_file, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                    return data.get("meetings", {})
            except Exception as e:
                print(f"⚠️  加载说话人映射失败: {e}")

        return {}

    def save_all_meetings(self):
        """保存所有会议映射"""
        data = {
            "updated_at": datetime.now().isoformat(),
            "version": "2.0",  # 按会议存储版本
            "meetings": self.all_meetings
        }

        with open(self.speakers_file, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def _get_meeting_key(self, date: str, session: str) -> str:
        """生成会议标识键"""
        if session:
            return f"{date}-{session}"
        return date

    def get_name(self, date: str, session: str, spk_id: int) -> Optional[str]:
        """获取说话人姓名

        Args:
            date: 日期 (YYYY-MM-DD)
            session: 时段 (morning/afternoon/full)
            spk_id: 说话人ID

        Returns:
            姓名或 None
        """
        meeting_key = self._get_meeting_key(date, session)
        meeting = self.all_meetings.get(meeting_key, {})
        return meeting.get(str(spk_id), {}).get("name")

    def set_name(self, date: str, session: str, spk_id: int, name: str, context: str = ""):
        """设置说话人姓名

        Args:
            date: 日期 (YYYY-MM-DD)
            session: 时段 (morning/afternoon/full)
            spk_id: 说话人ID
            name: 姓名
            context: 上下文备注
        """
        meeting_key = self._get_meeting_key(date, session)

        if meeting_key not in self.all_meetings:
            self.all_meetings[meeting_key] = {
                "date": date,
                "session": session,
                "created_at": datetime.now().isoformat()
            }

        spk_key = str(spk_id)
        if spk_key not in self.all_meetings[meeting_key]:
            self.all_meetings[meeting_key][spk_key] = {}

        self.all_meetings[meeting_key][spk_key]["name"] = name
        self.all_meetings[meeting_key][spk_key]["updated_at"] = datetime.now().isoformat()

        if context:
            if "contexts" not in self.all_meetings[meeting_key][spk_key]:
                self.all_meetings[meeting_key][spk_key]["contexts"] = []
            self.all_meetings[meeting_key][spk_key]["contexts"].append({
                "date": datetime.now().strftime("%Y-%m-%d"),
                "note": context
            })

        self.save_all_meetings()
        print(f"✅ 已映射 {meeting_key} 的 spk {spk_id} -> {name}")

    def get_meeting_mappings(self, date: str, session: str) -> Dict:
        """获取指定会议的所有映射

        Args:
            date: 日期 (YYYY-MM-DD)
            session: 时段 (morning/afternoon/full)

        Returns:
            {spk_id: {"name": ..., ...}} 字典
        """
        meeting_key = self._get_meeting_key(date, session)
        return self.all_meetings.get(meeting_key, {})

    def list_all_meetings(self) -> List[Dict]:
        """列出所有会议及其映射状态"""
        meetings = []
        for meeting_key, meeting_data in self.all_meetings.items():
            if not isinstance(meeting_data, dict):
                continue

            # 提取会议信息
            date = meeting_data.get("date", "unknown")
            session = meeting_data.get("session", "unknown")
            created = meeting_data.get("created_at", "unknown")

            # 统计映射数量
            mapped_count = 0
            for k, v in meeting_data.items():
                if k not in ["date", "session", "created_at", "updated_at", "contexts"] and isinstance(v, dict) and "name" in v:
                    mapped_count += 1

            meetings.append({
                "key": meeting_key,
                "date": date,
                "session": session,
                "mapped_count": mapped_count,
                "created": created[:10] if created else "unknown"
            })

        # 按日期排序
        meetings.sort(key=lambda x: x["date"], reverse=True)
        return meetings

    def list_meeting_speakers(self, date: str, session: str) -> List[Tuple]:
        """列出指定会议的说话人映射"""
        meeting_key = self._get_meeting_key(date, session)
        meeting = self.all_meetings.get(meeting_key, {})

        speakers = []
        for spk_key, data in meeting.items():
            if spk_key in ["date", "session", "created_at", "updated_at", "contexts"]:
                continue

            if isinstance(data, dict) and "name" in data:
                speakers.append((int(spk_key), data["name"], data.get("updated_at", "")))

        speakers.sort(key=lambda x: x[0])
        return speakers

    def import_speakers_to_meeting(self, date: str, session: str, spk_ids: List[int]):
        """将说话人ID导入到会议（待后续映射）"""
        meeting_key = self._get_meeting_key(date, session)

        if meeting_key not in self.all_meetings:
            self.all_meetings[meeting_key] = {
                "date": date,
                "session": session,
                "created_at": datetime.now().isoformat()
            }

        for spk_id in spk_ids:
            spk_key = str(spk_id)
            if spk_key not in self.all_meetings[meeting_key]:
                self.all_meetings[meeting_key][spk_key] = {
                    "imported_at": datetime.now().isoformat()
                }

        self.save_all_meetings()
        print(f"✅ 已将 {len(spk_ids)} 位说话人导入到会议 {meeting_key}")


def interactive_mapping(mapper: SpeakerMapper, date: str, session: str, speaker_stats: Dict):
    """交互式说话人映射

    Args:
        mapper: 说话人映射器
        date: 会议日期
        session: 会议时段
        speaker_stats: 说话人统计信息
    """
    print("\n" + "="*50)
    print(f"📝 说话人映射（{date} {session or 'full'}）")
    print("="*50)

    # 按发言次数排序
    sorted_speakers = sorted(
        speaker_stats.items(),
        key=lambda x: x[1].get("发言次数", 0),
        reverse=True
    )

    # 获取已有映射
    existing_mappings = mapper.get_meeting_mappings(date, session)

    for spk_id, stats in sorted_speakers:
        current_name = existing_mappings.get(str(spk_id), {}).get("name")

        print(f"\n🎤 spk {spk_id}:")
        print(f"   发言次数: {stats.get('发言次数', 0)}")
        print(f"   平均字数: {stats.get('平均字数', 0)}")
        print(f"   推测角色: {stats.get('推测角色', '未知')}")
        if current_name:
            print(f"   当前映射: {current_name} ✅")

        # 询问输入
        user_input = input(f"\n   输入姓名（或按跳过/留空）: ").strip()

        if user_input:
            if user_input.lower() in ["跳过", "skip", ""]:
                continue

            # 设置映射
            context = f"{stats.get('发言次数', 0)}次发言，{stats.get('推测角色', '未知')}"
            mapper.set_name(date, session, spk_id, user_input, context)

    print("\n✅ 映射完成！")


def main():
    import sys
    import argparse

    parser = argparse.ArgumentParser(description="说话人映射管理器（按会议存储）")
    parser.add_argument("command", choices=["list", "set", "get", "meetings", "interactive"], help="命令")
    parser.add_argument("--date", help="日期 (YYYY-MM-DD)")
    parser.add_argument("--session", choices=["morning", "afternoon", "full"], help="时段")
    parser.add_argument("--spk", type=int, help="说话人ID")
    parser.add_argument("--name", help="姓名")

    args = parser.parse_args()

    mapper = SpeakerMapper()

    if args.command == "meetings":
        # 列出所有会议
        meetings = mapper.list_all_meetings()
        print("\n📋 所有会议映射:")
        print("-" * 60)
        if not meetings:
            print("   （暂无会议映射）")
        else:
            for m in meetings:
                mapped = f"{m['mapped_count']} 人已映射" if m['mapped_count'] > 0 else "待映射"
                print(f"   {m['key']}: {mapped} ({m['created']})")

    elif args.command == "list":
        # 列出指定会议的映射
        if not args.date or not args.session:
            print("❌ 需要指定 --date 和 --session")
            print("   示例: python3 speaker_mapper.py list --date 2026-01-21 --session afternoon")
            return

        speakers = mapper.list_meeting_speakers(args.date, args.session)
        print(f"\n📋 {args.date} {args.session} 的说话人映射:")
        print("-" * 50)
        if not speakers:
            print("   （暂无映射）")
        else:
            for spk_id, name, updated in speakers:
                print(f"   spk {spk_id} → {name}")

    elif args.command == "set":
        # 设置映射
        if not all([args.date, args.session, args.spk is not None, args.name]):
            print("❌ 需要指定 --date, --session, --spk, --name")
            print("   示例: python3 speaker_mapper.py set --date 2026-01-21 --session afternoon --spk 0 --name 张三")
            return

        mapper.set_name(args.date, args.session, args.spk, args.name)

    elif args.command == "get":
        # 获取特定说话人
        if not all([args.date, args.session, args.spk is not None]):
            print("❌ 需要指定 --date, --session, --spk")
            return

        name = mapper.get_name(args.date, args.session, args.spk)
        if name:
            print(f"spk {args.spk} → {name}")
        else:
            print(f"spk {args.spk} 未映射")

    elif args.command == "interactive":
        print("❌ 交互模式需要从会议纪要生成器调用")
        print("   请使用: python3 generate_meeting_summary.py ... --interactive")


if __name__ == "__main__":
    main()
