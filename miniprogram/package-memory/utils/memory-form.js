// 回忆表单的选项与上限 —— 与 App 的 lib/features/plugins/memory/memory_edit_page.dart
// 逐项对齐。两边是同一张表、同一份校验（后端 max_length / 容量），展示口径不一致
// 会让用户困惑：「App 里还能再打 5 个字，小程序这边却截断了」。
//
// 上限同时记着后端的值：模型的 max_length 与 config 的
// max_upload_bytes(20MB) / memory_video_max_bytes(100MB)。前端预检只是让用户早点
// 知道，真正的判决在服务端。

// 心情：单点 emoji，可再点一次取消（对齐 App 的 _moods）。
const MOODS = ['😍', '🥹', '🤤', '😌', '😆', '🥰', '😭', '🤔'];

// 可见范围：后端只认 family / couple / private 三个值。
const VISIBILITIES = [
  { value: 'family', icon: '🏡', label: '全家' },
  { value: 'private', icon: '🔒', label: '只我自己' },
  { value: 'couple', icon: '💞', label: '我和 TA' },
];

const LIMITS = {
  title: 80, // 必填
  body: 2000,
  location: 80,
  comment: 500,
  mediaCount: 9, // 一条回忆最多挂几个媒体（照片 + 视频合计）
};

// 单个文件大小上限（字节）。照片走通用上传限制，视频有自己的、更宽松的一档。
const CAPS = {
  photo: 20 * 1024 * 1024,
  video: 100 * 1024 * 1024,
};

/** 可读 compression size 文案，如 '20MB'。 */
function capLabel(bytes) {
  return `${Math.round(bytes / (1024 * 1024))}MB`;
}

module.exports = { MOODS, VISIBILITIES, LIMITS, CAPS, capLabel };
