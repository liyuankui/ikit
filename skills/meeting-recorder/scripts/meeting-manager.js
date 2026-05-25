#!/usr/bin/env node
/**
 * Meeting Manager - 管理定期会议信息
 *
 * 功能：
 * - list: 列出所有定期会议
 * - match: 根据当前时间匹配会议
 * - add: 添加新会议
 * - update: 更新会议信息
 * - history: 查看某会议的历史记录
 *
 * 配置：
 * - DATA_FILE: 默认使用同目录下的 ../data/recurrent-meetings.json
 * - JOURNAL_DIR: 设置环境变量 MEETING_JOURNAL_DIR 或修改下方默认值
 */

const fs = require('fs');
const path = require('path');

const DATA_FILE = path.join(__dirname, '../data/recurrent-meetings.json');

// 配置：journal 目录（存放会议纪要的目录）
// 优先读取环境变量，其次使用默认值 ~/journal
const JOURNAL_DIR = process.env.MEETING_JOURNAL_DIR || path.join(process.env.HOME, 'journal');

// 加载会议数据
function loadMeetings() {
  if (!fs.existsSync(DATA_FILE)) {
    return { meetings: [] };
  }
  return JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
}

// 保存会议数据
function saveMeetings(data) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2), 'utf8');
}

// 列出所有会议
function listMeetings() {
  const data = loadMeetings();
  console.log('\n📋 定期会议列表\n');
  if (data.meetings.length === 0) {
    console.log('  (暂无注册会议)');
    return;
  }
  data.meetings.forEach((m, i) => {
    console.log(`\n${i + 1}. ${m.name} (${m.name_zh || ''})`);
    console.log(`   ID: ${m.id}`);
    console.log(`   频率: ${m.frequency} | 时间: ${m.day_of_week} ${m.time_range}`);
    console.log(`   参会人: ${m.default_attendees?.join(', ') || 'N/A'}`);
  });
  console.log('');
}

// 匹配当前时间的会议
function matchMeeting() {
  const data = loadMeetings();
  const now = new Date();
  const days = ['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'];
  const currentDay = days[now.getDay()];
  const currentHour = now.getHours();

  console.log('\n🔍 匹配会议...\n');
  console.log(`   当前时间: ${now.toLocaleString()}`);
  console.log(`   星期: ${currentDay} | 小时: ${currentHour}:00\n`);

  const matches = data.meetings.filter(m => {
    if (m.day_of_week !== currentDay) return false;
    const startHour = parseInt(m.time_range.split('-')[0].split(':')[0]);
    return currentHour >= startHour && currentHour < startHour + 2; // 2小时窗口
  });

  if (matches.length === 0) {
    console.log('   ⚠️  未找到匹配的会议\n');
    return null;
  }

  matches.forEach(m => {
    console.log(`   ✅ ${m.name}`);
    console.log(`      ID: ${m.id}`);
    console.log(`      时间: ${m.time_range}`);
    console.log(`      参会人: ${m.default_attendees?.join(', ') || 'N/A'}`);
  });
  console.log('');

  return matches[0]; // 返回第一个匹配
}

// 添加新会议
function addMeeting(meeting) {
  const data = loadMeetings();
  const id = meeting.id || meeting.name.toLowerCase().replace(/\s+/g, '-');

  if (data.meetings.find(m => m.id === id)) {
    console.error(`\n❌ 会议 ID "${id}" 已存在\n`);
    process.exit(1);
  }

  const newMeeting = {
    id,
    name: meeting.name,
    name_zh: meeting.name_zh || '',
    frequency: meeting.frequency || 'weekly',
    day_of_week: meeting.day_of_week,
    time_range: meeting.time_range,
    timezone: meeting.timezone || 'UTC',
    description: meeting.description || '',
    calendar_link: meeting.calendar_link || '',
    default_attendees: meeting.default_attendees || [],
    keywords: meeting.keywords || [],
    intent_link: meeting.intent_link || '',
    workspace_link: meeting.workspace_link || '',
    created_at: new Date().toISOString().split('T')[0],
    last_updated: new Date().toISOString().split('T')[0]
  };

  data.meetings.push(newMeeting);
  saveMeetings(data);
  console.log(`\n✅ 已添加会议: ${newMeeting.name}\n`);
}

// 查看历史记录
function showHistory(meetingId) {
  const data = loadMeetings();
  const meeting = data.meetings.find(m => m.id === meetingId);

  if (!meeting) {
    console.error(`\n❌ 未找到会议: ${meetingId}\n`);
    process.exit(1);
  }

  console.log(`\n📜 ${meeting.name} - 历史记录\n`);

  if (!fs.existsSync(JOURNAL_DIR)) {
    console.log(`  ⚠️  Journal 目录不存在: ${JOURNAL_DIR}`);
    console.log(`  请设置 MEETING_JOURNAL_DIR 环境变量或创建目录\n`);
    return;
  }

  // 搜索 journal 目录中的相关文件
  const { execSync } = require('child_process');
  const keywords = meeting.keywords || [meeting.name, meeting.id];

  let searchCmd = `find ${JOURNAL_DIR} -name "*.md" -type f`;
  try {
    const files = execSync(searchCmd, { encoding: 'utf8' }).trim().split('\n');
    const matched = files.filter(f => {
      if (!f) return false;
      const content = fs.readFileSync(f, 'utf8');
      return keywords.some(kw => content.toLowerCase().includes(kw.toLowerCase()));
    });

    if (matched.length === 0) {
      console.log('  (暂无历史记录)\n');
      return;
    }

    matched.slice(0, 10).forEach(f => {
      const basename = path.basename(f);
      const stat = fs.statSync(f);
      console.log(`  📄 ${basename}`);
      console.log(`     修改: ${stat.mtime.toLocaleDateString()}`);
    });
  } catch (e) {
    console.log('  (搜索失败)\n');
  }
  console.log('');
}

// CLI
const command = process.argv[2] || 'list';

switch (command) {
  case 'list':
    listMeetings();
    break;
  case 'match':
    matchMeeting();
    break;
  case 'add':
    // 示例: node meeting-manager.js add --name "Weekly Standup" --day monday --time "10:00-11:00"
    const args = require('minimist')(process.argv.slice(3));
    addMeeting({
      name: args.name,
      name_zh: args.name_zh,
      frequency: args.frequency,
      day_of_week: args.day,
      time_range: args.time,
      description: args.description,
      default_attendees: args.attendees?.split(','),
      keywords: args.keywords?.split(',')
    });
    break;
  case 'history':
    showHistory(process.argv[3]);
    break;
  default:
    console.log(`
Usage: node meeting-manager.js <command>

Commands:
  list              列出所有定期会议
  match             匹配当前时间的会议
  add [options]     添加新会议
  history <id>      查看会议历史记录

Options for 'add':
  --name <name>         会议名称 (必需)
  --name_zh <name>      中文名称
  --frequency <freq>    频率 (weekly/biweekly/monthly)
  --day <day>           星期 (monday/tuesday/...)
  --time <range>        时间范围 (10:00-12:00)
  --description <desc>  描述
  --attendees <list>    参会人 (逗号分隔)
  --keywords <list>     关键词 (逗号分隔)

Environment Variables:
  MEETING_JOURNAL_DIR   Journal 目录路径 (默认: ~/journal)
`);
}
