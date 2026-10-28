// 手机号 / 密码的前端校验。
//
// 单独抽出来是因为登录页和注册页要用**完全相同**的一套规则。两边各写一份，
// 迟早有一边先改、另一边留在旧口径上，而用户感知到的只是「这边说不行、
// 那边又说行了」。
//
// 阈值不是自己定的，都取自后端 —— 前端放宽只会在提交时才被服务端打回，
// 徒增一次往返：
//   手机号  ^1[3-9]\d{9}$   ← app/services/auth.py normalize_phone
//   密码    >= 6 位         ← app/services/auth.py MIN_PASSWORD_LEN
const PHONE_RE = /^1[3-9]\d{9}$/;
const MIN_PASSWORD_LEN = 6;

function trimPhone(value) {
  return String(value || '').trim();
}

/**
 * @param {string} phone
 * @returns {string} 错误文案；空串表示通过
 */
function checkPhone(phone) {
  return PHONE_RE.test(trimPhone(phone)) ? '' : '请输入正确的 11 位手机号';
}

/**
 * @param {string} password
 * @returns {string} 错误文案；空串表示通过
 */
function checkPassword(password) {
  return String(password || '').length >= MIN_PASSWORD_LEN
    ? ''
    : `密码至少 ${MIN_PASSWORD_LEN} 位`;
}

/**
 * 确认密码比对。后端没有这一项（注册语义走的是登录接口，见 pages/register），
 * 所以它纯粹是一道前端防线：让用户不必等一次服务端往返才发现两次输入不同。
 *
 * @param {string} password
 * @param {string} confirm
 * @returns {string} 错误文案；空串表示通过
 */
function checkConfirm(password, confirm) {
  if (!confirm) return '请再次输入密码';
  return password === confirm ? '' : '两次输入的密码不一致';
}

module.exports = {
  PHONE_RE,
  MIN_PASSWORD_LEN,
  trimPhone,
  checkPhone,
  checkPassword,
  checkConfirm,
};
