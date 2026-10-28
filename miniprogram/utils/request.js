// 统一请求层：拼地址、带 Bearer、拆信封、抛错。
//
// 后端所有响应都是 {success, data, error, meta} 信封（对齐 App 端的 ApiClient）：
// 业务层只拿到 `data`，信封与错误由这里统一处理，页面里不重复写判断。
//
// `upload()` 是给二进制用的另一条通道：小程序的 `wx.request` 发不了文件，只能
// 走 `wx.uploadFile`（发送 multipart/form-data）。它好在**支持自定义请求头**，
// 所以 Bearer 照带、后端的 `POST .../media` 一个字都不用改（P3 因此零后端改动）。
const { baseUrl } = require('./config');
const API_PREFIX = '/api/v1';
const TIMEOUT = 15000;
// 上传比查询慢得多：照片走微信默认 60s，视频 20MB~100MB 远远不够。
const UPLOAD_TIMEOUT = 120000;

// 会话被服务端撤销/过期时的回调。由 app.js 注入，避免工具层反向依赖 App。
let onSessionInvalid = null;
function setSessionInvalidHandler(fn) {
  onSessionInvalid = fn;
}

function buildError(res) {
  const body = res.data;
  const err = (body && body.error) || {};
  // 没有信封说明请求根本没到 FastAPI（nginx 413、网关 502、证书错误……）。
  // 这时状态码是唯一线索，照着它给一句人话，比「请求失败」有用得多。
  let message = err.message;
  if (!message) {
    if (res.statusCode === 413) message = '文件太大，服务器拒绝了这次上传';
    else if (res.statusCode === 502 || res.statusCode === 504) message = '服务暂时不可用，请稍后重试';
    else if (res.statusCode) message = `请求失败（${res.statusCode}）`;
    else message = '请求失败';
  }
  const error = new Error(message);
  error.code = err.code || 'UNKNOWN';
  error.statusCode = res.statusCode;
  error.details = err.details || null;
  return error;
}

/** 丢弃已换号的登录响应时，仅撤销该响应新签发的会话。 */
function discardLoginToken(url, body) {
  const token = body && body.data && body.data.token;
  if (!url.startsWith('/auth/') || !token) return;
  wx.request({
    url: baseUrl + API_PREFIX + '/auth/logout', method: 'POST',
    header: { Authorization: 'Bearer ' + token },
    timeout: TIMEOUT,
    fail() {},
  });
}

/** 三条请求通道共用会话检查、信封解析与失效处理。 */
function send(o, withMeta, isUpload) {
  const { snapshot, isCurrent, staleSessionError } = require('./session');
  const scope = o.sessionScope || snapshot();
  const url = o.url.startsWith('/') ? o.url : '/' + o.url;
  const header = Object.assign(
    isUpload ? { Accept: 'application/json' }
      : { 'Content-Type': 'application/json', Accept: 'application/json' },
    scope.token ? { Authorization: 'Bearer ' + scope.token } : {},
    o.header || {}
  );
  return new Promise((resolve, reject) => {
    if (!isCurrent(scope)) {
      reject(staleSessionError());
      return;
    }
    const callbacks = {
      url: baseUrl + API_PREFIX + url,
      header,
      timeout: o.timeout || (isUpload ? UPLOAD_TIMEOUT : TIMEOUT),
      success(res) {
        let body = res.data;
        if (isUpload && typeof body === 'string') {
          try { body = JSON.parse(body); } catch (e) { body = null; }
        }
        if (!isCurrent(scope)) {
          discardLoginToken(url, body);
          reject(staleSessionError());
          return;
        }
        if (body && body.success === true) {
          resolve(withMeta ? { data: body.data, meta: body.meta || null } : body.data);
          return;
        }
        const error = buildError({ data: body, statusCode: res.statusCode });
        if (error.statusCode === 401 && error.details && error.details.session_invalid
            && header.Authorization === 'Bearer ' + scope.token) {
          if (typeof onSessionInvalid === 'function') onSessionInvalid();
        }
        reject(error);
      },
      fail(err) {
        if (!isCurrent(scope)) {
          reject(staleSessionError());
          return;
        }
        const error = new Error(isUpload ? '上传失败，请检查网络后重试' : '网络连接失败，请检查网络后重试');
        error.code = 'NETWORK_ERROR';
        error.raw = err;
        reject(error);
      },
    };
    if (!isUpload) {
      wx.request(Object.assign(callbacks, { method: o.method || 'GET', data: o.data }));
      return;
    }
    const task = wx.uploadFile(Object.assign(callbacks, {
      filePath: o.filePath, name: o.name || 'file', formData: o.formData || {},
    }));
    if (task && typeof task.onProgressUpdate === 'function' && typeof o.onProgress === 'function') {
      task.onProgressUpdate((r) => { if (isCurrent(scope)) o.onProgress(r || {}); });
    }
  });
}

function request(o) { return send(o, false, false); }
function requestWithMeta(o) { return send(o, true, false); }
function upload(o) { return send(o, false, true); }

module.exports = { request, requestWithMeta, upload, setSessionInvalidHandler };
