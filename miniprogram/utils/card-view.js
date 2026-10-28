// 已安装插件 → 卡片视图模型的纯函数转换。
//
// 单独抽出来的原因：这里是唯一把后端 JSON 掰成视图的地方，做成纯函数后
// 可以脱离小程序环境（node）直接喂真实 payload 验证，不必起开发者工具。
const { cardBg, toneColor, NEUTRAL } = require('./theme');
const { pageUrlFor } = require('./plugin-registry');

/** 后端 layout 的 cw/ch 可能越界（旧数据），统一夹到 1..4。 */
function clamp(n, fallback) {
  const v = Number(n);
  if (!isFinite(v)) return fallback;
  return Math.min(4, Math.max(1, Math.round(v)));
}

// 首页卡片最多铺几张封面。后端 preview 也只给 5 张，这里再夹一次，
// 是因为「渲染几张」是视图层的决定，不该随服务端改动而漂移。
const MAX_COVERS = 5;

// preview.image_urls 的每一项都是后端的原始字节端点：
//   /api/v1/families/<fid>/plugins/memory/memories/<mid>/media/<mediaId>/raw
// 这个地址要 Authorization 头，<image> 用不了；所以我们只把它当「是哪几张」
// 的清单，真正的可直连地址由 media-url.js 拿去换预签名 URL。
// 用末尾匹配而不是整串匹配，后端哪天加 query 或改成绝对地址都不受影响。
const MEDIA_RAW_RE = /\/media\/([0-9a-fA-F-]{36})\/raw(?:\?.*)?$/;

/**
 * @param {string[]} imageUrls 后端 preview.image_urls
 * @returns {string[]} media id 列表（去重、保序、最多 MAX_COVERS 张）
 */
function coverIds(imageUrls) {
  const out = [];
  (imageUrls || []).forEach((u) => {
    const m = MEDIA_RAW_RE.exec(String(u || ''));
    if (!m) return;
    if (out.indexOf(m[1]) < 0) out.push(m[1]);
  });
  return out.slice(0, MAX_COVERS);
}

/**
 * @param {object} installed  bootstrap 里的一条 installed_plugins
 * @param {string} familyId   当前家庭 id，用于拼插件页的 query
 */
function toCard(installed, familyId) {
  const plugin = (installed && installed.plugin) || {};
  const preview = (installed && installed.preview) || {};
  const layout = (installed && installed.layout) || {};
  const cw = clamp(layout.cw, 2);
  const ch = clamp(layout.ch, 2);
  const url = pageUrlFor(installed.plugin_id, familyId);
  const primary = preview.primary || '';
  const compact = ch <= 1;
  // 矮卡只有一行高（184rpx），铺图会把文字挤没，所以不参与封面。
  const photoIds = compact ? [] : coverIds(preview.image_urls);

  return {
    id: installed.id,
    pluginId: installed.plugin_id,
    name: plugin.name || installed.plugin_id,
    // App 用的是统一细线图标字体；小程序没有那套图标，退回到插件 emoji
    //（preview.emoji 优先 —— 纪念日用的是具体某个纪念日的 emoji 而非插件的 🎂）。
    icon: String(preview.emoji || plugin.emoji || '').trim(),
    bg: cardBg(preview.color_token || plugin.color_token),
    primary: primary,
    secondary: preview.secondary || '',
    secondaryColor: toneColor(preview.secondary_tone) || NEUTRAL.fgMid,
    secondaryBold: !!preview.secondary_tone,
    // 记账金额在 App 里用更大字号突出，小程序保持一致。
    isMoney: installed.plugin_id === 'accounting' && primary.indexOf('¥') === 0,
    cw: cw,
    ch: ch,
    compact: compact,
    // 封面：photoIds 是「要哪几张」，photos 是换好直链后的 [{id, url}]。
    // 直链要额外一次请求，所以初始为空 —— 页面先按无图渲染，图到了再补丁
    // 上去。这样首屏文字不必等图片，弱网下也只是慢一点、不会卡住。
    photoIds: photoIds,
    photos: [],
    available: !!url,
    url: url,
  };
}

/** 过滤掉被停用的卡片后批量转换。 */
function toCards(list, familyId) {
  return (list || [])
    .filter((p) => p && p.enabled !== false)
    .map((p) => toCard(p, familyId));
}

module.exports = { clamp, coverIds, toCard, toCards };
