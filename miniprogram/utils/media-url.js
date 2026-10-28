// 直链（headerless URL）获取与缓存。
//
// 为什么需要这一层：后端所有媒体端点（回忆 /raw、头像 /avatar）都要求
// `Authorization` 头，而小程序的 <image> 组件**发不出自定义请求头** —— 直接给
// 它 /raw 只会得到一张空白图。所以后端加了 C1–C3 三个「换预签名直链」的端点，
// 这里负责调它们、缓存结果、并在不支持直链的环境里安静降级。
//
// 缓存是必要的：一封时间线 20 条回忆 × 平均 6 张图 = 120 个 URL。预签名 URL
// 有有效期（后端 1 小时），所以按过期时间缓存，快过期时才重新取。
//
// ⚠️ 直链指向的是 COS 域名（不是后端域名），必须单独加进小程序后台的
//    downloadFile 合法域名白名单，否则真机上依然加载不出来。
const { request } = require('./request');
const { snapshot, isCurrent, assertCurrent, staleSessionError } = require('./session');

// 提前这么久就当作过期，避免"刚好在过期瞬间发出请求"导致图片裂图。
const REFRESH_MARGIN_MS = 5 * 60 * 1000;

const _mediaCache = new Map(); // mediaId -> {url, expiresAt}
const _avatarCache = new Map(); // `${familyId}:${userId}` -> {url, expiresAt}

// 后端存储不支持预签名（如本地盘部署）时置 true，之后不再反复打必然会
// 501 的接口 —— 否则每翻一页都要多一次失败请求。
let _unsupported = false;
let _scope = null;
let _cacheGeneration = 0;

function cacheScope() {
  if (!_scope || !isCurrent(_scope)) clearMediaCache();
  return { session: _scope, generation: _cacheGeneration };
}

function checkCacheScope(scope) {
  assertCurrent(scope.session);
  if (scope.generation !== _cacheGeneration) throw staleSessionError();
}

function _fresh(entry) {
  return !!entry && entry.expiresAt - Date.now() > REFRESH_MARGIN_MS;
}

function _expiresAt(iso) {
  const t = iso ? Date.parse(iso) : NaN;
  return isNaN(t) ? Date.now() + 3600 * 1000 : t;
}

/**
 * 拿一批回忆媒体的直链。
 *
 * @param {string} familyId
 * @param {string[]} mediaIds
 * @returns {Promise<object>} {urls: {mediaId: url}, ok: boolean}
 *   ok=false 表示这一批一张都没拿到（后端不支持直链或请求失败），
 *   调用方应显示占位图而不是空白。
 */
async function memoryMediaUrls(familyId, mediaIds) {
  const scope = cacheScope();
  const ids = (mediaIds || []).filter(Boolean);
  if (!ids.length || !familyId) return { urls: {}, ok: true };

  const urls = {};
  const missing = [];
  for (const id of ids) {
    const hit = _mediaCache.get(id);
    if (_fresh(hit)) urls[id] = hit.url;
    else missing.push(id);
  }

  if (missing.length && !_unsupported) {
    try {
      const data = await request({
        url: `/families/${familyId}/plugins/memory/media/urls`,
        method: 'POST',
        data: { media_ids: missing },
      });
      checkCacheScope(scope);
      const expiresAt = _expiresAt(data.expires_at);
      Object.keys(data.urls || {}).forEach((id) => {
        urls[id] = data.urls[id];
        _mediaCache.set(id, { url: data.urls[id], expiresAt });
      });
    } catch (e) {
      checkCacheScope(scope);
      // 501 = 存储后端不能预签名。记住它，后续页面直接走降级。
      if (e.statusCode === 501) _unsupported = true;
      // 其余失败（网络抖动）保留旧缓存，让页面至少显示已拿到的图。
    }
  }

  checkCacheScope(scope);
  return { urls, ok: !_unsupported && Object.keys(urls).length > 0 };
}

/**
 * 某个家庭成员头像的直链；没有头像（404）返回 null，调用方回退到 emoji。
 *
 * @returns {Promise<string|null>}
 */
async function memberAvatarUrl(familyId, userId) {
  const scope = cacheScope();
  if (!familyId || !userId) return null;

  const key = `${familyId}:${userId}`;
  const hit = _avatarCache.get(key);
  if (_fresh(hit)) return hit.url;
  if (hit) _avatarCache.delete(key);

  try {
    const data = await request({
      url: `/families/${familyId}/members/${userId}/avatar-url`,
    });
    checkCacheScope(scope);
    const url = data.url || null;
    if (url) _avatarCache.set(key, { url, expiresAt: _expiresAt(data.expires_at) });
    return url;
  } catch (e) {
    if (!isCurrent(scope.session) || scope.generation !== _cacheGeneration) return null;
    // 404 = 这位成员没传过头像是正常状态，不是错误。
    if (e.statusCode === 404) return null;
    if (e.statusCode === 501) _unsupported = true;
    return null;
  }
}

/** 当前登录用户自己的头像直链。 */
async function myAvatarUrl() {
  const scope = cacheScope();
  try {
    const data = await request({ url: '/me/avatar-url' });
    checkCacheScope(scope);
    return data.url || null;
  } catch (e) {
    return null;
  }
}

/** 直链是否可用（后端存储支持预签名）。供页面决定要不要显示占位图。 */
function directUrlsSupported() {
  return !_unsupported;
}

/** 退出登录 / 切换家庭时清空 —— URL 是跟账号绑定的，不能跨账号复用。 */
function clearMediaCache() {
  _scope = snapshot();
  _cacheGeneration += 1;
  _mediaCache.clear();
  _avatarCache.clear();
  _unsupported = false;
}

module.exports = {
  memoryMediaUrls,
  memberAvatarUrl,
  myAvatarUrl,
  directUrlsSupported,
  clearMediaCache,
};
