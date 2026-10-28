// 设计 token：与 App 端 lib/theme/wo_tokens.dart 的浅色板一一对应。
//
// 为什么要复制一份而不是随便配色：首页卡片墙要和 App 首页「看起来是同一个 App」，
// 卡片底色 = 插件 color_token 以 16% 透明度叠在卡片白底上（App 里是
// `Color.alphaBlend(colorForToken(t).withValues(alpha: .16), bgElev)`）。
// 用户在 App 和小程序之间来回切时，颜色不该跳变。
//
// 只带浅色：微信内绝大多数是浅色场景，且 App 默认也是浅色。
// 若要支持深色，加一套 dark 值并在 app.js 里读 wx.getSystemInfoSync().theme 切换。

// 插件分类色（对应 WoTokens.*Light）。未知的 token 一律回退 accent。
const TOKEN_COLORS = {
  photo: '#E8DCC8',
  money: '#E8D4A8',
  anniv: '#F0C4B4',
  chore: '#D6DCC8',
  pet: '#E8D0E0',
  memory: '#DDCFC0',
  stock: '#C8D2E0',
  movie: '#D9CCDF',
  calendar: '#BFD8D2',
  subscribe: '#C3C8EA',
  plant: '#C6DCC0',
  retire: '#AFD8CE',
  expiry: '#CBC6DA',
  travel: '#CBDAD2',
  accent: '#A85D2D',
};

// 语义强调色（预算见底、临期等），对应 warningLight / dangerLight。
const TONE_COLORS = {
  warning: '#C98A00',
  danger: '#C0392B',
};

// 中性色（对应 light* 系列）。
const NEUTRAL = {
  bg: '#F8F1E7',
  bgElev: '#FFFFFF',
  fg: '#302219',
  fgMid: '#736052',
  fgDim: '#7D6655',
  accent: '#A85D2D',
  accentDeep: '#915025',
  hairline: '#E7DED3',
};

function hexToRgb(hex) {
  const s = String(hex).replace('#', '');
  const full =
    s.length === 3
      ? s
          .split('')
          .map((c) => c + c)
          .join('')
      : s;
  return [
    parseInt(full.slice(0, 2), 16),
    parseInt(full.slice(2, 4), 16),
    parseInt(full.slice(4, 6), 16),
  ];
}

function rgbToHex(rgb) {
  return (
    '#' +
    rgb
      .map((v) => {
        const n = Math.max(0, Math.min(255, Math.round(v)));
        return n.toString(16).padStart(2, '0');
      })
      .join('')
      .toUpperCase()
  );
}

/**
 * src 以 alpha 叠在 dst 上（Flutter Color.alphaBlend 的等价实现）。
 * 结果 = src * alpha + dst * (1 - alpha)，逐通道。
 */
function alphaBlend(src, dst, alpha) {
  const a = hexToRgb(src);
  const b = hexToRgb(dst);
  return rgbToHex([
    a[0] * alpha + b[0] * (1 - alpha),
    a[1] * alpha + b[1] * (1 - alpha),
    a[2] * alpha + b[2] * (1 - alpha),
  ]);
}

/** 分类色原色（用于图标、细线等需要纯色的地方）。 */
function tokenColor(token) {
  return TOKEN_COLORS[token] || TOKEN_COLORS.accent;
}

/**
 * 卡片底色：分类色 16% 叠白。与 App _WidgetCard 的算法一致。
 * 在 JS 里算而不是硬编码十六进制，是为了避免手算出错，也方便以后调 alpha。
 */
function cardBg(token, alpha = 0.16) {
  return alphaBlend(tokenColor(token), NEUTRAL.bgElev, alpha);
}

/** secondary 的强调色；无 tone 返回 null，调用方回退到 fgMid。 */
function toneColor(tone) {
  return tone ? TONE_COLORS[tone] || null : null;
}

module.exports = {
  TOKEN_COLORS,
  TONE_COLORS,
  NEUTRAL,
  tokenColor,
  cardBg,
  toneColor,
  alphaBlend,
};
