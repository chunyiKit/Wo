// 请求与登录共用会话代次，避免退出、换号后的迟到响应写回旧数据。
const TOKEN_KEY = 'token';
const MANUAL_LOGOUT_KEY = 'manual_logout';
let generation = 0;

function getToken() {
  return wx.getStorageSync(TOKEN_KEY) || '';
}

function setToken(token) {
  generation += 1;
  wx.setStorageSync(TOKEN_KEY, token);
  wx.removeStorageSync(MANUAL_LOGOUT_KEY);
}

function clearToken() {
  generation += 1;
  wx.removeStorageSync(TOKEN_KEY);
}

function snapshot() {
  return { generation, token: getToken() };
}

function isCurrent(scope) {
  return scope.generation === generation && scope.token === getToken();
}

function staleSessionError() {
  const error = new Error('登录状态已变化，请重试');
  error.code = 'SESSION_CHANGED';
  return error;
}

function assertCurrent(scope) {
  if (!isCurrent(scope)) throw staleSessionError();
}

function markManualLogout() {
  wx.setStorageSync(MANUAL_LOGOUT_KEY, true);
}

function canSilentLogin() {
  return !wx.getStorageSync(MANUAL_LOGOUT_KEY);
}

module.exports = {
  getToken, setToken, clearToken, snapshot, isCurrent, assertCurrent,
  staleSessionError, markManualLogout, canSilentLogin,
};
