const { test, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');
const source = stripTypeScriptTypes(fs.readFileSync(path.join(__dirname, '../core/memory-draft.ts'), 'utf8'))
  .replace(/export /g, '');
let store, removed, context, draftApi, fileSystem;
beforeEach(() => {
  store = new Map(); removed = [];
  fileSystem = {
    removeSavedFile({ filePath, complete }) { removed.push(filePath); complete(); },
    getFileInfo({ success }) { success({ size: 500 }); },
    saveFile({ success }) { success({ savedFilePath: 'saved/private.jpg' }); },
  };
  let counter = 0;
  context = vm.createContext({
    wx: {
      getRandomValues({ success }) { success({ randomValues: Uint8Array.from({ length: 16 }, (_, i) => i + counter++).buffer }); },
      setStorageSync(key, value) { store.set(key, JSON.parse(JSON.stringify(value))); },
      getStorageSync(key) { return store.get(key); },
      getStorageInfoSync() { return { keys: [...store.keys()] }; },
      removeStorageSync(key) { store.delete(key); },
      getFileSystemManager() { return fileSystem; },
      getImageInfo({ success }) { success({ width: 4000, height: 3000 }); },
      compressImage({ success }) { success({ tempFilePath: 'compressed.jpg' }); },
    },
  });
  draftApi = vm.runInContext(source + '\n({newMemoryDraft, writeMemoryDraft, readMemoryDraft, clearMemoryDrafts, saveMemoryDraft, addMemoryImage, removeMemoryImage, draftKey})', context);
});
const scope = { userId: 'user-a', familyId: 'family-a' };
async function readyDraft() {
  const draft = await draftApi.newMemoryDraft(scope);
  draft.title = '一起看日落'; draft.visibility = 'family';
  await draftApi.addMemoryImage(draft, 'temp.jpg', () => {});
  return draft;
}

test('new drafts stay private and user/family manifests are isolated', async () => {
  const draft = await draftApi.newMemoryDraft(scope);
  assert.equal(draft.visibility, 'private');
  assert.match(draft.clientId, /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/);
  draftApi.writeMemoryDraft(draft);
  assert.equal(draftApi.readMemoryDraft({ ...scope, userId: 'user-b' }), null);
  assert.equal(draftApi.readMemoryDraft({ ...scope, familyId: 'family-b' }), null);
  assert.equal(draftApi.readMemoryDraft(scope).clientId, draft.clientId);
});
test('lost create and upload responses replay stable IDs, sharing happens only after attachments', async () => {
  const draft = await readyDraft();
  const memoryIds = new Set(), attachmentIds = new Set(), events = [];
  let createResponseLost = true, uploadResponseLost = true;
  const transport = {
    async create(fields) {
      events.push('create:' + fields.visibility); memoryIds.add(fields.client_id);
      if (createResponseLost) { createResponseLost = false; throw Error('response lost'); }
      return { id: fields.client_id };
    },
    async upload(id, attachment) {
      events.push('upload'); attachmentIds.add(attachment.id);
      if (uploadResponseLost) { uploadResponseLost = false; throw Error('response lost'); }
    },
    async update(id, fields) { events.push('update:' + fields.visibility); },
  };
  await assert.rejects(draftApi.saveMemoryDraft(draft, transport, () => {}), /response lost/);
  let recovered = draftApi.readMemoryDraft(scope);
  assert.equal(recovered.clientId, draft.clientId);
  await assert.rejects(draftApi.saveMemoryDraft(recovered, transport, () => {}), /response lost/);
  recovered = draftApi.readMemoryDraft(scope);
  assert.equal(recovered.attachments[0].id, draft.attachments[0].id);
  assert.equal(await draftApi.saveMemoryDraft(recovered, transport, () => {}), true);
  assert.equal(memoryIds.size, 1); assert.equal(attachmentIds.size, 1);
  assert.equal(events.at(-1), 'update:family');
  assert.equal(events.filter(e => e === 'update:family').length, 1);
  assert.equal(store.size, 0); assert.deepEqual(removed, ['saved/private.jpg']);
});
test('partial success persists upload progress and skips completed attachments on manual retry', async () => {
  const draft = await readyDraft();
  const second = { id: 'second-id', path: 'saved/second.jpg', size: 600, uploaded: false };
  draft.attachments.push(second);
  let fail = true; const ids = [];
  const transport = {
    async create() { return { id: 'memory-id' }; },
    async upload(id, attachment) { ids.push(attachment.id); if (attachment.id === second.id && fail) { fail = false; throw Error('offline'); } },
    async update() {},
  };
  await assert.rejects(draftApi.saveMemoryDraft(draft, transport, () => {}), /offline/);
  const restored = draftApi.readMemoryDraft(scope);
  assert.equal(restored.attachments[0].uploaded, true);
  assert.equal(restored.attachments[1].uploaded, false);
  await draftApi.saveMemoryDraft(restored, transport, () => {});
  assert.equal(ids.filter(id => id === draft.attachments[0].id).length, 1);
  assert.equal(ids.filter(id => id === second.id).length, 2);
});
test('account switch during upload prevents final sharing and never rewrites a deleted manifest', async () => {
  const draft = await readyDraft();
  let current = true, updated = false;
  const check = () => { if (!current) throw Error('SESSION_CHANGED'); };
  const transport = {
    async create() { return { id: 'memory-id' }; },
    async upload() { current = false; await draftApi.clearMemoryDrafts(); },
    async update() { updated = true; },
  };
  await assert.rejects(draftApi.saveMemoryDraft(draft, transport, check), /SESSION_CHANGED/);
  assert.equal(updated, false); assert.equal(store.size, 0);
});
test('oversized compressed images never reach saved storage', async () => {
  const draft = await draftApi.newMemoryDraft(scope);
  fileSystem.getFileInfo = ({ success }) => success({ size: 10 * 1024 * 1024 + 1 });
  let saved = false;
  fileSystem.saveFile = () => { saved = true; };
  await assert.rejects(draftApi.addMemoryImage(draft, 'temp.jpg', () => {}), /10 MB/);
  assert.equal(saved, false); assert.equal(draft.attachments.length, 0);
});
test('scope change while saveFile completes removes the orphan and does not persist draft', async () => {
  const draft = await draftApi.newMemoryDraft(scope);
  let current = true;
  fileSystem.saveFile = ({ success }) => { current = false; success({ savedFilePath: 'saved/orphan.jpg' }); };
  await assert.rejects(draftApi.addMemoryImage(draft, 'temp.jpg', () => { if (!current) throw Error('SESSION_CHANGED'); }), /SESSION_CHANGED/);
  assert.deepEqual(removed, ['saved/orphan.jpg']); assert.equal(store.size, 0);
});
test('logout cleanup only removes the selected scope and its local files', async () => {
  const draft = await readyDraft();
  const other = { ...draft, userId: 'user-b', attachments: [{ ...draft.attachments[0], path: 'saved/b.jpg' }] };
  draftApi.writeMemoryDraft(other);
  await draftApi.clearMemoryDrafts('user-a', 'family-a');
  assert.equal(draftApi.readMemoryDraft(scope), null);
  assert.equal(draftApi.readMemoryDraft({ ...scope, userId: 'user-b' }).userId, 'user-b');
  assert.deepEqual(removed, ['saved/private.jpg']);
});
test('parallel save taps cannot issue duplicate requests', async () => {
  const draft = await readyDraft();
  let unblock; const wait = new Promise(resolve => { unblock = resolve; });
  let calls = 0;
  const transport = { async create() { calls++; await wait; return { id: 'memory-id' }; }, async upload() {}, async update() {} };
  const first = draftApi.saveMemoryDraft(draft, transport, () => {});
  assert.equal(await draftApi.saveMemoryDraft(draft, transport, () => {}), false);
  unblock(); await first; assert.equal(calls, 1);
});

for (const [label, width, height, expectedWidth, expectedHeight] of [
  ['landscape', 4000, 3000, 1920, 1440],
  ['portrait', 3000, 4000, 1440, 1920],
  ['small image', 800, 600, 800, 600],
]) {
  test(`compression preserves ${label} aspect ratio without enlargement`, async () => {
    const draft = await draftApi.newMemoryDraft(scope);
    context.wx.getImageInfo = ({ success }) => success({ width, height });
    let options;
    context.wx.compressImage = value => { options = value; value.success({ tempFilePath: 'compressed.jpg' }); };
    await draftApi.addMemoryImage(draft, 'original.jpg', () => {});
    assert.equal(options.compressedWidth, expectedWidth);
    assert.equal(options.compressedHeight, expectedHeight);
  });
}
test('retry after lost final share response hides the record before uploading new attachments', async () => {
  const draft = await readyDraft();
  const events = []; let serverVisibility = 'private'; let loseShare = true;
  const transport = {
    async create(fields) { serverVisibility = fields.visibility; return { id: draft.clientId }; },
    async upload(id, attachment) { events.push(`upload:${attachment.id}:${serverVisibility}`); },
    async update(id, fields) {
      serverVisibility = fields.visibility; events.push(`visibility:${fields.visibility}`);
      if (fields.visibility === 'family' && loseShare) { loseShare = false; throw Error('share response lost'); }
    },
  };
  await assert.rejects(draftApi.saveMemoryDraft(draft, transport, () => {}), /share response lost/);
  assert.equal(serverVisibility, 'family');
  const recovered = draftApi.readMemoryDraft(scope);
  recovered.attachments.push({ id: 'new-image', path: 'saved/new.jpg', size: 10, uploaded: false });
  const split = events.length;
  await draftApi.saveMemoryDraft(recovered, transport, () => {});
  assert.deepEqual(events.slice(split), ['visibility:private', 'upload:new-image:private', 'visibility:family']);
});
test('failed acknowledgement when reverting to private blocks any new upload', async () => {
  const draft = await readyDraft(); draft.memoryId = draft.clientId;
  let uploads = 0;
  const transport = {
    async create() { throw Error('unexpected create'); },
    async upload() { uploads++; },
    async update(id, fields) { assert.equal(fields.visibility, 'private'); throw Error('offline'); },
  };
  await assert.rejects(draftApi.saveMemoryDraft(draft, transport, () => {}), /offline/);
  assert.equal(uploads, 0); assert.ok(draftApi.readMemoryDraft(scope));
});
