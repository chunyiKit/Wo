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

function authHeader() {
  const token = wx.getStorageSync('token');
  return token ? { Authorization: 'Bearer ' + token } : {};
}

/**
 * 发一个请求，成功 resolve `data`。
 * @param {object} o  {url, method, data, header, timeout}
 */
function request(o) {
  const url = o.url.startsWith('/') ? o.url : '/' + o.url;
  return new Promise((resolve, reject) => {
    wx.request({
      url: baseUrl + API_PREFIX + url,
      method: o.method || 'GET',
      data: o.data,
      timeout: o.timeout || TIMEOUT,
      header: Object.assign(
        { 'Content-Type': 'application/json', Accept: 'application/json' },
        authHeader(),
        o.header || {}
      ),
      success(res) {
        const body = res.data;
        if (body && body.success === true) {
          resolve(body.data);
          return;
        }
        const error = buildError(res);
        if (error.statusCode === 401 && error.details && error.details.session_invalid) {
          if (typeof onSessionInvalid === 'function') onSessionInvalid();
        }
        reject(error);
      },
      fail(err) {
        const error = new Error('网络连接失败，请检查网络后重试');
        error.code = 'NETWORK_ERROR';
        error.raw = err;
        reject(error);
      },
    });
  });
}

/**
 * 同上，但额外带回信封里的 `meta`（分页游标 / 总数）。
 * 分页接口用这个；普通接口用 request。
 */
function requestWithMeta(o) {
  const url = o.url.startsWith('/') ? o.url : '/' + o.url;
  return new Promise((resolve, reject) => {
    wx.request({
      url: baseUrl + API_PREFIX + url,
      method: o.method || 'GET',
      data: o.data,
      timeout: o.timeout || TIMEOUT,
      header: Object.assign(
        { 'Content-Type': 'application/json', Accept: 'application/json' },
        authHeader(),
        o.header || {}
      ),
      success(res) {
        const body = res.data;
        if (body && body.success === true) {
          resolve({ data: body.data, meta: body.meta || null });
          return;
        }
        const error = buildError(res);
        if (error.statusCode === 401 && error.details && error.details.session_invalid) {
          if (typeof onSessionInvalid === 'function') onSessionInvalid();
        }
        reject(error);
      },
      fail(err) {
        const error = new Error('网络连接失败，请检查网络后重试');
        error.code = 'NETWORK_ERROR';
        error.raw = err;
        reject(error);
      },
    });
  });
}

/**
 * 上传一个文件（multipart/form-data），成功 resolve `data`。
 *
 * 注意**不要**手动设 Content-Type：multipart 需要带 boundary，微信会自动填。
 *
 * @param {object} o
 *   {url, filePath, name, formData, timeout, onProgress}
 *   onProgress 收到 `{progress}`（0-100），用于大视频的进度提示。
 */
function upload(o) {
  const url = o.url.startsWith('/') ? o.url : '/' + o.url;
  return new Promise((resolve, reject) => {
    const task = wx.uploadFile({
      url: baseUrl + API_PREFIX + url,
      filePath: o.filePath,
      name: o.name || 'file',
      formData: o.formData || {},
      timeout: o.timeout || UPLOAD_TIMEOUT,
      // 刻意不设 Content-Type：multipart 的 boundary 由微信生成。
      header: Object.assign({ Accept: 'application/json' }, authHeader(), o.header || {}),
      success(res) {
        // uploadFile 的响应体是字符串，不像 wx.request 会自动按 JSON 解析。
        let body = res.data;
        if (typeof body === 'string') {
          try {
            body = JSON.parse(body);
          } catch (e) {
            body = null;
          }
        }
        if (body && body.success === true) {
          resolve(body.data);
          return;
        }
        const error = buildError({ data: body, statusCode: res.statusCode });
        if (error.statusCode === 401 && error.details && error.details.session_invalid) {
          if (typeof onSessionInvalid === 'function') onSessionInvalid();
        }
        reject(error);
      },
      fail(err) {
        const error = new Error('上传失败，请检查网络后重试');
        error.code = 'NETWORK_ERROR';
        error.raw = err;
        reject(error);
      },
    });

    // 返回值在个别运行环境里可能拿不到，拿不到就退化为「只有完成回调」。
    if (task && typeof task.onProgressUpdate === 'function' && typeof o.onProgress === 'function') {
      task.onProgressUpdate((r) => o.onProgress(r || {}));
    }
  });
}

module.exports = { request, requestWithMeta, upload, setSessionInvalidHandler };
