// node --test miniprogram/tests/*.test.js
// 加载真实页面与工具模块，只替换微信 SDK，重放网络乱序与失败场景。
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ROOT = path.resolve(__dirname, '..');
const flush = () => new Promise(setImmediate);
const plain = (value) => JSON.parse(JSON.stringify(value));

function runtime(storage = new Map()) {
  const requests = [], uploads = [], logins = [], toasts = [], navigations = [];
  const modules = new Map();
  let app, page;
  const wx = {
    getStorageSync: (key) => storage.get(key),
    setStorageSync: (key, value) => storage.set(key, value),
    removeStorageSync: (key) => storage.delete(key),
    request(o) { requests.push(o); if (this.handleRequest) queueMicrotask(() => this.handleRequest(o)); },
    uploadFile(o) { uploads.push(o); return { onProgressUpdate() {} }; },
    login: (o) => logins.push(o),
    showToast: (o) => toasts.push(o),
    reLaunch: (o) => navigations.push(o.url),
    navigateBack() {}, switchTab() {},
    previewImage(o) { this.preview = o; },
  };
  const context = vm.createContext({
    wx, console, queueMicrotask, setTimeout() {},
    App: (o) => { app = o; }, Page: (o) => { page = o; }, getApp: () => app,
  });
  function load(relative, parent = path.join(ROOT, 'app.js')) {
    let filename = path.resolve(path.dirname(parent), relative);
    if (!path.extname(filename)) filename += '.js';
    if (modules.has(filename)) return modules.get(filename).exports;
    const module = { exports: {} };
    modules.set(filename, module);
    const run = vm.runInContext(
      '(function(require,module,exports){' + fs.readFileSync(filename, 'utf8') + '\n})',
      context, { filename }
    );
    run((name) => load(name, filename), module, module.exports);
    return module.exports;
  }
  load('./app'); app.onLaunch();
  return {
    wx, app, storage, requests, uploads, logins, toasts, navigations,
    load,
    page(relative) {
      load(relative);
      const instance = { ...page, data: plain(page.data) };
      instance.setData = (patch) => Object.assign(instance.data, patch);
      return instance;
    },
  };
}

function reply(request, data, statusCode = 200) {
  const body = statusCode < 400
    ? { success: true, data }
    : { success: false, error: { message: 'failure', code: 'UNAUTHORIZED', details: { session_invalid: true } } };
  request.success({ statusCode, data: request.filePath ? JSON.stringify(body) : body });
}

for (const channel of ['request', 'requestWithMeta', 'upload']) {
  for (const status of [200, 401]) {
    test(`${channel}: 换号后忽略旧会话的 ${status} 响应`, async () => {
      const r = runtime();
      r.app.setToken('A');
      const api = r.load('./utils/request');
      const pending = api[channel]({ url: '/me', filePath: 'test.png' });
      const rejected = assert.rejects(pending, { code: 'SESSION_CHANGED' });
      r.app.clearToken(); r.app.setToken('B');
      const old = channel === 'upload' ? r.uploads[0] : r.requests[0];
      reply(old, { private: 'A' }, status);
      await rejected;
      assert.equal(r.app.getToken(), 'B');
      assert.equal(r.navigations.length, 0);
    });
  }
}

test('相同 token 被清除再设置后也属于不同代次', async () => {
  const r = runtime(); r.app.setToken('A');
  const p = r.load('./utils/request').request({ url: '/me' });
  const rejected = assert.rejects(p, { code: 'SESSION_CHANGED' });
  r.app.clearToken(); r.app.setToken('A');
  reply(r.requests[0], { private: 'old generation' });
  await rejected;
});

test('迟到 bootstrap 不能把旧账号数据写回 globalData', async () => {
  const r = runtime(); r.app.setToken('A');
  const p = r.app.loadBootstrap();
  const rejected = assert.rejects(p, { code: 'SESSION_CHANGED' });
  r.app.setToken('B');
  r.app.globalData.user = { id: 'B' };
  reply(r.requests[0], { user: { id: 'A' }, families: [{ id: 'private-family' }] });
  await rejected;
  assert.equal(r.app.globalData.user.id, 'B');
  assert.deepEqual(plain(r.app.globalData.families), []);
});

test('迟到直链不能重新填充换号后已清空的媒体缓存', async () => {
  const r = runtime(); r.app.setToken('A');
  const media = r.load('./utils/media-url');
  const p = media.memoryMediaUrls('family', ['media']);
  const rejected = assert.rejects(p, { code: 'SESSION_CHANGED' });
  r.app.setToken('B');
  reply(r.requests[0], { urls: { media: 'https://private-A' } });
  await rejected;
  const next = media.memoryMediaUrls('family', ['media']);
  assert.equal(r.requests.length, 2);
  reply(r.requests[1], { urls: {} });
  assert.deepEqual(plain((await next).urls), {});
});

test('迟到登录响应仅撤销它新签发的 token，不影响当前账号', async () => {
  const r = runtime();
  const p = r.load('./utils/request').request({ url: '/auth/wechat/login', method: 'POST' });
  const rejected = assert.rejects(p, { code: 'SESSION_CHANGED' });
  r.app.setToken('B');
  reply(r.requests[0], { token: 'discarded-token' });
  await rejected;
  assert.equal(r.requests[1].header.Authorization, 'Bearer discarded-token');
  assert.ok(r.requests[1].url.endsWith('/auth/logout'));
  assert.equal(r.app.getToken(), 'B');
});

test('wx.login 等待期间退出后，不再发送旧的登录请求', async () => {
  const r = runtime();
  const p = r.load('./utils/auth').silentLogin();
  const rejected = assert.rejects(p, { code: 'SESSION_CHANGED' });
  r.app.clearToken();
  r.logins[0].success({ code: 'expired-flow' });
  await rejected;
  assert.equal(r.requests.length, 0);
});

test('手动退出立即清理，重启保持退出，旧登出响应不清除新账号', async () => {
  const r = runtime(); r.app.setToken('A');
  const pending = r.app.logout();
  assert.equal(r.app.getToken(), '');
  await r.page('./pages/index/index').onLoad();
  assert.equal(r.logins.length, 0);
  const restarted = runtime(r.storage);
  await restarted.page('./pages/index/index').onLoad();
  assert.equal(restarted.logins.length, 0);
  r.app.setToken('B');
  reply(r.requests[0], {}, 401);
  await pending;
  assert.equal(r.app.getToken(), 'B');
  assert.equal(r.load('./utils/auth').canSilentLogin(), true);
});

for (const failedIndex of [0, 1]) {
  test(`媒体删除第 ${failedIndex + 1} 项失败后，重试保留未完成队列`, async () => {
    const r = runtime(); r.app.setToken('A');
    const page = r.page('./package-memory/pages/edit/edit');
    page.familyId = 'family'; page.memoryId = 'memory'; page.removed = ['a', 'b'];
    Object.assign(page.data, { title: '回忆', canSave: true, loading: false, pending: [], media: [] });
    const attempts = { a: 0, b: 0 };
    r.wx.handleRequest = (o) => {
      if (o.method === 'DELETE') {
        const id = o.url.split('/').pop(); attempts[id] += 1;
        const fail = id === ['a', 'b'][failedIndex] && attempts[id] === 1;
        reply(o, {}, fail ? 503 : (id === 'b' ? 404 : 200));
      } else reply(o, { media: [] });
    };
    await page.onSave();
    assert.deepEqual(plain(page.removed), failedIndex === 0 ? ['a', 'b'] : ['b']);
    await page.onSave();
    assert.deepEqual(plain(page.removed), []);
    assert.deepEqual(attempts, failedIndex === 0 ? { a: 2, b: 1 } : { a: 1, b: 2 });
    assert.equal(r.toasts.at(-1).title, '已保存');
  });
}

test('点击第二张缩略图从第二张开始预览', () => {
  const r = runtime();
  const page = r.page('./package-memory/pages/timeline/timeline');
  page.data.groups = [{ items: [{ id: 'memory', allPhotoUrls: ['https://one', 'https://two'],
    photos: [{ id: 'one', url: 'https://one' }, { id: 'two', url: 'https://two' }] }] }];
  page.previewPhoto({ currentTarget: { dataset: { id: 'two', mid: 'memory' } } });
  assert.equal(r.wx.preview.current, 'https://two');
  assert.deepEqual(plain(r.wx.preview.urls), ['https://one', 'https://two']);
});

test('正文响应完成后换号，不再以新账号继续删除旧页面的媒体', async () => {
  const r = runtime(); r.app.setToken('A');
  const page = r.page('./package-memory/pages/edit/edit');
  page.familyId = 'family'; page.memoryId = 'memory'; page.removed = ['private-media'];
  Object.assign(page.data, { title: '回忆', canSave: true, loading: false });
  const pending = page.onSave();
  reply(r.requests[0], {});
  r.app.setToken('B');
  await pending;
  assert.equal(r.requests.length, 1);
  assert.deepEqual(plain(page.removed), ['private-media']);
});

test('COS 上传途中换号，不发送提交请求或回退上传到新账号', async () => {
  const r = runtime(); r.app.setToken('A');
  const page = r.page('./package-memory/pages/edit/edit');
  page.familyId = 'family';
  const pending = page.uploadOne('memory', { path: 'private.mp4', key: 'id', kind: 'video' });
  const rejected = assert.rejects(pending, { code: 'SESSION_CHANGED' });
  await flush();
  reply(r.requests[0], { url: 'https://cos.test', fields: {}, media_id: 'id', key: 'staged' });
  await flush();
  assert.equal(r.uploads.length, 1);
  r.app.setToken('B');
  r.uploads[0].success({ statusCode: 200, data: '' });
  await rejected;
  assert.equal(r.requests.length, 1);
  assert.equal(r.uploads.length, 1);
  assert.equal(r.app.getToken(), 'B');
});
