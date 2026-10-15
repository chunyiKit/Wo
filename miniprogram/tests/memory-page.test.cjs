const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const source = stripTypeScriptTypes(fs.readFileSync(path.join(__dirname, '../pages/memories/index.ts'), 'utf8'))
  .replace(/import[\s\S]*?from ['"][^'"]+['"];?/g, '');
function pageFixture(options = {}) {
  let page, activeEpoch = 1, resolve, reject, listener = null;
  const downloads = [], previews = [];
  const response = new Promise((a, b) => { resolve = a; reject = b; });
  vm.runInNewContext(source, {
    Page(value) { page = value; }, theme() { return 'cinema'; },
    epoch() { return activeEpoch; }, assertEpoch(value) { if (value !== activeEpoch) throw Error('SESSION_CHANGED'); },
    onSessionChange(callback) { listener = callback; return () => { listener = null; }; },
    getSession() { return { user: { id: 'user-a' }, familyId: 'family-a' }; },
    api() { return response; }, familyPath() { return '/family/memories'; },
    hydrateAvatars(rows) { return options.hydrate ? Promise.resolve(rows) : new Promise(() => {}); },
    async privateMedia(url) { downloads.push(url); return options.download ? options.download(url) : 'local:' + url; },
    wx: { previewImage(value) { previews.push(value); } },
  });
  page._epoch = 1; page._scope = { userId: 'user-a', familyId: 'family-a' };
  page.setData = data => {
    for (const [key, value] of Object.entries(data)) {
      const match = /^items\[(\d+)\]\.media\[(\d+)\]\.local$/.exec(key);
      if (match) page.data.items[Number(match[1])].media[Number(match[2])].local = value;
      else page.data[key] = value;
    }
  };
  page.onLoad();
  return { page, resolve, reject, downloads, previews, switchAccount() { activeEpoch++; listener?.(); }, hasListener() { return !!listener; } };
}
test('refresh keeps current cards and authenticated thumbnails on screen', async () => {
  const fixture = pageFixture(); const { page } = fixture;
  page.data.loaded = true;
  page.data.items = [{ id: 'm1', title: '旧标题', author_avatar_url: 'local-avatar', avatarSource: '/avatar?v=1', media: [{ id: 'p1', kind: 'photo', url: '/raw', local: 'private-local-photo' }] }];
  const refresh = page.load();
  assert.equal(page.data.loaded, true); assert.equal(page.data.items[0].title, '旧标题');
  fixture.resolve([{ id: 'm1', title: '新标题', author_avatar_url: '/avatar?v=1', media: [{ id: 'p1', kind: 'photo', url: '/raw' }] }]);
  await refresh;
  assert.equal(page.data.items[0].title, '新标题');
  assert.equal(page.data.items[0].author_avatar_url, 'local-avatar');
  assert.equal(page.data.items[0].media[0].local, 'private-local-photo');
});
test('refresh failure preserves old data and reports a recoverable inline message', async () => {
  const fixture = pageFixture(); const { page } = fixture;
  page.data.loaded = true; page.data.items = [{ id: 'm1', title: '保留' }];
  const refresh = page.load(); fixture.reject(Error('offline')); await refresh;
  assert.equal(page.data.items[0].title, '保留'); assert.equal(page.data.loaded, true);
  assert.match(page.data.refreshError, /offline|加载失败/); assert.equal(page.data.loading, false);
});
test('late previous-account response cannot render any old private data', async () => {
  const fixture = pageFixture(); const { page } = fixture;
  const refresh = page.load(); fixture.switchAccount();
  fixture.resolve([{ id: 'private', title: '前一账号私密照片', media: [] }]); await refresh;
  assert.equal(page.data.items.length, 0); assert.equal(page.data.loaded, false);
});
test('initial fetch failure allows retry without showing an empty successful state', async () => {
  const fixture = pageFixture(); const { page } = fixture;
  const refresh = page.load(); fixture.reject(Error('offline')); await refresh;
  assert.equal(page.data.loaded, false); assert.equal(page.data.items.length, 0);
  assert.ok(page.data.error); assert.equal(page.data.loading, false);
});
test('session event immediately clears private cards, draft and editor before onShow', () => {
  const fixture = pageFixture(); const { page } = fixture;
  page.data.items = [{ id: 'private' }]; page.data.draft = { clientId: 'old-draft' };
  page.data.loaded = true; page.data.editor = true; page.data.saving = true;
  fixture.switchAccount();
  assert.equal(page.data.items.length, 0); assert.equal(page.data.draft, null);
  assert.equal(page.data.editor, false); assert.equal(page.data.saving, false);
  assert.equal(page._scope, null); assert.equal(page._epoch, -1);
  page.onUnload(); assert.equal(fixture.hasListener(), false);
});
function manyPhotos() {
  return Array.from({ length: 50 }, (_, memory) => ({
    id: `memory-${memory}`, title: '回忆',
    media: Array.from({ length: 9 }, (_, image) => ({ id: `photo-${image}`, kind: 'photo', url: `/memory-${memory}/photo-${image}` })),
  }));
}
test('automatic hydration downloads only eight covers rather than 450 full-size photos', async () => {
  const fixture = pageFixture({ hydrate: true }); const { page } = fixture;
  const rows = manyPhotos(); page.data.items = rows;
  await page.hydrate(rows, 1, 0);
  assert.equal(fixture.downloads.length, 8);
  assert.deepEqual(fixture.downloads, Array.from({ length: 8 }, (_, i) => `/memory-${i}/photo-0`));
  assert.equal(page.data.items[8].media[0].local, undefined);
});
test('tapping a placeholder downloads only that memory gallery and previews selected image', async () => {
  const fixture = pageFixture(); const { page } = fixture;
  page.data.items = manyPhotos();
  await page.previewImage({ currentTarget: { dataset: { memory: 'memory-20', media: 'photo-4' } } });
  assert.equal(fixture.downloads.length, 9);
  assert.ok(fixture.downloads.every(url => url.startsWith('/memory-20/')));
  assert.equal(fixture.previews.length, 1); assert.equal(fixture.previews[0].urls.length, 9);
  assert.equal(fixture.previews[0].current, 'local:/memory-20/photo-4');
});
test('account switch while gallery downloads cannot open previous private images', async () => {
  let complete;
  const pending = new Promise(resolve => { complete = resolve; });
  const fixture = pageFixture({ download: () => pending }); const { page } = fixture;
  page.data.items = manyPhotos();
  const preview = page.previewImage({ currentTarget: { dataset: { memory: 'memory-20' } } });
  fixture.switchAccount(); complete('private-old-photo'); await preview;
  assert.equal(fixture.previews.length, 0); assert.equal(page.data.items.length, 0);
});
