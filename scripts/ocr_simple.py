#!/usr/bin/env python3
"""
简单的 OCR 工具，使用 macOS Vision 框架
通过 applescript 调用系统快捷指令或使用第三方工具
"""

import subprocess
import sys
import re
from pathlib import Path


def ocr_with_vision_framework(image_path: str) -> str:
    """使用 macOS Vision 框架进行 OCR

    通过 Swift 代码调用 Vision 框架
    """
    swift_code = f'''
import Vision
import Foundation

let imageData = try Data(contentsOf: URL(fileURLWithPath: "{image_path}"))
let handler = VNImageRequestHandler(data: imageData, options: [:])

let request = VNRecognizeTextRequest()
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.recognitionLevel = .accurate

try handler.perform([request])

if let results = request.results {{
    for result in results {{
        if let obs = result as? VNRecognizedTextObservation,
           let candidate = obs.topCandidates(1).first {{
            print(candidate.string)
        }}
    }}
}}
'''

    # 运行 Swift 代码
    result = subprocess.run(
        ["swift", "-"],
        input=swift_code,
        capture_output=True,
        text=True,
        timeout=30
    )

    if result.returncode == 0:
        return result.stdout.strip()
    else:
        return ""


def ocr_with_tesseract(image_path: str) -> str:
    """使用 tesseract OCR（如果已安装）"""
    try:
        result = subprocess.run(
            ["tesseract", image_path, "stdout", "-l", "chi_sim+eng"],
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.stdout.strip()
    except FileNotFoundError:
        return ""
    except Exception as e:
        return ""


def extract_chinese_names(text: str) -> list:
    """从文本中提取中文姓名"""
    # 简单的中文姓名模式（2-4个汉字）
    names = re.findall(r'[\u4e00-\u9fff]{2,4}', text)

    # 过滤常见非姓名词
    stop_words = {
        "会议", "讨论", "决定", "行动", "问题", "方案", "系统", "项目",
        "时间", "日期", "负责人", "参与者", "待办", "完成", "确认",
        "记录", "整理", "发送", "接收", "审核", "批准", "这是", "那个",
        "什么", "怎么", "为什么", "因为", "所以", "但是", "然后", "接着"
    }

    filtered = [n for n in names if n not in stop_words]

    return filtered


def main():
    if len(sys.argv) < 2:
        print("用法: python3 ocr_simple.py <image_path>")
        sys.exit(1)

    image_path = sys.argv[1]

    if not Path(image_path).exists():
        print(f"错误: 文件不存在 - {image_path}")
        sys.exit(1)

    print(f"🔍 正在识别: {image_path}")

    # 尝试 Vision 框架
    text = ocr_with_vision_framework(image_path)

    # 如果失败，尝试 tesseract
    if not text:
        text = ocr_with_tesseract(image_path)

    if text:
        print(f"\n📝 识别文本:")
        print(text)

        names = extract_chinese_names(text)
        if names:
            print(f"\n👤 可能的姓名: {', '.join(set(names))}")
    else:
        print("⚠️  OCR 失败，请确保已安装相关工具")


if __name__ == "__main__":
    main()
