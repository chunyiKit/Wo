// 微信登录与会话管理。
//
// 首登策略 A（手机号 + 密码后绑定）：
//   1. wx.login() 拿一次性 code
//   2. POST /auth/wechat/login  —— 已绑定就直接拿 token，零输入进主页
//   3. 未绑定 → 用户填手机号/密码 → POST /auth/wechat/bind 一次性完成登录+绑定
//
// code 是一次性的（5 分钟有效）。第 2 步消耗掉一个之后，第 3 步必须重新
// wx.login() 取新 code，所以下面每次提交都现取，不做缓存。
const { request } = require('./request');
const { getToken, setToken, clearToken, snapshot, assertCurrent, canSilentLogin } = require('./session');

/** 取一个一次性的 wx.login code。 */
function loginCode() {
  return new Promise((resolve, reject) => {
    wx.login({
      success(res) {
        if (res.code) resolve(res.code);
        else reject(new Error('微信登录失败：' + (res.errMsg || '未知错误')));
      },
      fail(err) {
        reject(new Error('微信登录失败：' + (err.errMsg || '未知错误')));
      },
    });
  });
}

/**
 * 静默登录。返回 {bound, user, token}；bound=false 表示这个微信身份还没绑定
 * 任何 Wo 账号，调用方应引导去绑定页。
 */
async function silentLogin() {
  const scope = snapshot();
  const code = await loginCode();
  assertCurrent(scope);
  const res = await request({ url: '/auth/wechat/login', method: 'POST', data: { code } });
  assertCurrent(scope);
  return res;
}

/**
 * 手机号 + 密码登录（或注册）并绑定当前微信身份。
 * 返回 {user, token, is_new}。
 */
async function bindWithPhone(phone, password) {
  const scope = snapshot();
  const code = await loginCode();
  assertCurrent(scope);
  const res = await request({
    url: '/auth/wechat/bind',
    method: 'POST',
    data: { code, phone: (phone || '').trim(), password },
  });
  assertCurrent(scope);
  return res;
}

module.exports = {
  getToken,
  setToken,
  clearToken,
  canSilentLogin,
  loginCode,
  silentLogin,
  bindWithPhone,
};
