// 日期文案 —— 与 App 侧 lib/features/plugins/memory/memory_media.dart 逐字对齐，
// 两边显示同一个回忆时不能出现「App 说昨天、小程序说 5 月 24 日」。
//
// event_date 是 `2026-05-25` 这种纯日期字符串。不能用 new Date(iso) 解析：
// 它会被当成 UTC 午夜，在东八区变成当天早上 8 点，跨时区/跨设备会出现差一天
// 的诡异 bug。所以手动切分，按本地时区构造。

const MONTH_NAMES = [
  '一月',
  '二月',
  '三月',
  '四月',
  '五月',
  '六月',
  '七月',
  '八月',
  '九月',
  '十月',
  '十一月',
  '十二月',
];

function parseDay(value) {
  const parts = String(value || '').slice(0, 10).split('-');
  if (parts.length < 3) return null;
  const y = Number(parts[0]);
  const m = Number(parts[1]);
  const d = Number(parts[2]);
  if (!y || !m || !d) return null;
  return new Date(y, m - 1, d);
}

/** 条目上的日期：今天 / 昨天 / 前天 / N 天前 / 上周 / X 月 X 日。 */
function memoryDateLabel(value) {
  const date = parseDay(value);
  if (!date) return '';

  const now = new Date();
  const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const diff = Math.round((today - date) / 86400000);

  if (diff === 0) return '今天';
  if (diff === 1) return '昨天';
  if (diff === 2) return '前天';
  if (diff > 2 && diff < 7) return `${diff} 天前`;
  if (diff >= 7 && diff < 14) return '上周';
  return `${date.getMonth() + 1} 月 ${date.getDate()} 日`;
}

/** 分组标题：六月 · 2026。 */
function memoryMonthLabel(value) {
  const date = parseDay(value);
  if (!date) return '未标日期';
  return `${MONTH_NAMES[date.getMonth()]} · ${date.getFullYear()}`;
}

/** 详情页用的完整日期：2026 年 5 月 25 日。 */
function memoryFullDate(value) {
  const date = parseDay(value);
  if (!date) return '';
  return `${date.getFullYear()} 年 ${date.getMonth() + 1} 月 ${date.getDate()} 日`;
}

/**
 * JS Date → `YYYY-MM-DD`（按本地时区，不走 toISOString：那会先转 UTC，
 * 东八区的晚上会写成第二天）。新建回忆时给 picker 用。
 */
function toDayString(date) {
  if (!date) return '';
  const m = date.getMonth() + 1;
  const d = date.getDate();
  return `${date.getFullYear()}-${m < 10 ? '0' + m : m}-${d < 10 ? '0' + d : d}`;
}

module.exports = {
  memoryDateLabel,
  memoryMonthLabel,
  memoryFullDate,
  parseDay,
  toDayString,
};
