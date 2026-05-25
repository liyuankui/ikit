#!/usr/bin/env node

/**
 * 合并 iKit 会议转录 JSON 文件
 *
 * 用法: ./merge-transcripts.js <recording-directory> [hour-prefix]
 *
 * 参数:
 *   - recording-directory: 录音目录路径（如 ~/recordings/2026-03-10）
 *   - hour-prefix: 可选，时间前缀过滤（如 "16" 只处理 16:xx 的文件）
 *
 * 示例:
 *   ./merge-transcripts.js ~/recordings/2026-03-10     # 合并所有文件
 *   ./merge-transcripts.js ~/recordings/2026-03-10 16  # 只合并 16:xx 的文件
 *
 * 文件名格式: 20260310-HHMMSS.json
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

function mergeTranscripts(directory, hourPrefix = null) {
  const files = fs.readdirSync(directory);

  // 先尝试匹配 _mic.json 格式，如果找不到再用新格式
  let jsonFiles = files.filter(f => f.endsWith('_mic.json')).sort();

  if (jsonFiles.length === 0) {
    // 新格式：20260310-HHMMSS.json
    jsonFiles = files.filter(f => /^\d{8}-\d{6}\.json$/.test(f)).sort();
  }

  // 按时间前缀筛选
  if (hourPrefix) {
    const prefix = String(hourPrefix).padStart(2, '0');
    jsonFiles = jsonFiles.filter(f => {
      // 匹配 20260310-16... 格式中的小时部分
      const match = f.match(/^\d{8}-(\d{2})\d{4}/);
      return match && match[1] === prefix;
    });
    console.log(`🕒 筛选时间: ${prefix}:xx - ${parseInt(prefix) + 1}:xx`);
  }

  if (jsonFiles.length === 0) {
    console.log(`❌ 未找到转录文件 (*.json) 在 ${directory}`);
    if (hourPrefix) {
      console.log(`   提示: 尝试不指定时间前缀，或检查时间范围`);
    }
    return { fullText: '', sentences: [] };
  }

  console.log(`📁 找到 ${jsonFiles.length} 个转录文件`);

  const allSentences = [];
  const fullTexts = [];

  for (const jsonFile of jsonFiles) {
    const filePath = path.join(directory, jsonFile);
    try {
      const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));

      // 旧格式有 text 字段
      if (data.text) {
        fullTexts.push(data.text);
      }

      // 新格式只有 sentences
      if (data.sentences) {
        allSentences.push(...data.sentences);
        // 从 sentences 合并 text
        if (!data.text) {
          fullTexts.push(data.sentences.map(s => s.text).join(''));
        }
      }
      console.log(`  ✓ ${jsonFile}: ${data.sentences?.length || 0} 句`);
    } catch (e) {
      console.log(`  ⚠️ 跳过: ${jsonFile} (${e.message})`);
    }
  }

  const fullText = fullTexts.join('\n');
  return { fullText, sentences: allSentences, fileCount: jsonFiles.length };
}

// CLI
const args = process.argv.slice(2);

if (args.length < 1) {
  console.log('用法: merge-transcripts.js <recording-directory> [hour-prefix]');
  console.log('');
  console.log('参数:');
  console.log('  recording-directory  录音目录（如 ~/recordings/2026-03-10）');
  console.log('  hour-prefix          可选，时间前缀（如 "16" 只处理 16:xx 文件）');
  console.log('');
  console.log('示例:');
  console.log('  ./merge-transcripts.js ~/recordings/2026-03-10      # 合并所有');
  console.log('  ./merge-transcripts.js ~/recordings/2026-03-10 16   # 只合并 16:xx');
  process.exit(1);
}

const directory = args[0].replace(/^~/, process.env.HOME);
const hourPrefix = args[1]; // 可选

console.log('🔄 合并转录文件...');
console.log(`📂 目录: ${directory}`);
if (hourPrefix) {
  console.log(`🕒 时间筛选: ${hourPrefix}:xx`);
}
console.log('');

const { fullText, sentences, fileCount } = mergeTranscripts(directory, hourPrefix);

console.log('');
console.log('📊 统计:');
console.log(`  - 文件数: ${fileCount}`);
console.log(`  - 总句子数: ${sentences.length}`);
console.log(`  - 总字符数: ${fullText.length}`);
console.log('');
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
console.log(fullText);
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
