// 回忆 · 新建 / 编辑。
//
// 这是 P3 的核心页，也是「回忆插件打通全链路」里「能写」的那一半：路径与时
// 间线、详情完全同源（同一个 family、同一套 Membership 校验），所以在小程序里
// 记下的回忆，App 的时间线立刻能看到，反之亦然。
//
// 保存顺序是有讲究的，不能随意调换：
//   1. 先存正文（POST /memories 或 PUT /memories/{id}）—— 媒体必须挂在已存在的
//      回忆上，端点就是 /memories/{id}/media，没有第 1 步就无处可挂；
//   2. 再删用户移除的旧媒体 —— 早于上传，避免格子里「删了又回来」的错觉；
//   3. 最后逐个上传新文件。
//
// 每一步都带 client_id（本地生成一次、重试不变，见 utils/uuid.js），所以任意一
// 步失败后**原地重按保存**是安全的：服务端会返回第一次创建的资源，不会多出一
// 条回忆或一张重复的照片。这也是为什么部分上传失败时页面不退出 —— 留在原地重
// 试，比替用户做决定更好。
const { request, upload } = require('../../../utils/request');
const { snapshot, assertCurrent } = require('../../../utils/session');
const { uploadDirect, isDirectDisabled } = require('../../../utils/cos-upload');
const { memoryMediaUrls } = require('../../../utils/media-url');
const { uuidV4 } = require('../../../utils/uuid');
const { needsPrivacyAuthorization } = require('../../../utils/privacy');
const { memoryFullDate, toDayString } = require('../../utils/format');
const {
  MOODS,
  VISIBILITIES,
  LIMITS,
  CAPS,
  capLabel,
} = require('../../utils/memory-form');

// 照片选原图动辄 5-10MB，在微信里既慢又容易超限；compressed 会走微信侧的压缩，
// 视觉上无损但体积能小一个量级。视频不受这个参数影响（微信始终给原文件）。
const SIZE_TYPES = ['compressed'];
// 拍摄视频的时长上限（秒）。相册里选的不受影响。
const MAX_VIDEO_SECONDS = 60;

function todayEnd() {
  // App 的日期选择器 lastDate = 今天 + 1 天（允许补记「明天」的计划），这里对齐。
  const d = new Date();
  d.setDate(d.getDate() + 1);
  return toDayString(d);
}

Page({
  data: {
    familyId: '',
    memoryId: '',
    editing: false,
    loading: true,
    saving: false,

    title: '',
    body: '',
    location: '',
    mood: '',
    visibility: 'family',
    eventDate: '',
    dateLabel: '',
    // picker 的边界。起点对齐 App（2000 年）；终点是明天。
    dateStart: '2000-01-01',
    dateEnd: '',

    moods: MOODS,
    visibilities: VISIBILITIES,
    limits: LIMITS,
    photoCap: capLabel(CAPS.photo),
    videoCap: capLabel(CAPS.video),

    // 已存在服务端的媒体（编辑时带过来）。kind=video 没有封面，只显示占位。
    media: [],
    // 本地新选、尚未上传的文件。key 同时用作上传的 client_id。
    pending: [],
    canAddMedia: true,
    canSave: false,

    progress: { done: 0, total: 0 },
  },

  onLoad(query) {
    // 真机上 familyId 一定由上一页带过来；开发者工具的「编译模式」直接打开本页
    // 时是空的，退回当前家庭 —— 否则每换一次 id 都要手填。
    const family = getApp().globalData.family;
    this.familyId = (query && query.familyId) || (family ? family.id : '');
    this.memoryId = (query && query.id) || '';
    // 标记为移除的旧媒体 id，保存时才真正发 DELETE。
    this.removed = [];
    // 新建时用同一个 client_id 重试，避免重复 POST 造出两条回忆。
    this.createKey = uuidV4();
    this._loaded = false;

    if (!this.familyId) {
      this.setData({ loading: false });
      wx.showToast({ title: '缺少家庭信息', icon: 'none' });
      return;
    }

    this.setData({
      familyId: this.familyId,
      memoryId: this.memoryId,
      editing: !!this.memoryId,
      dateEnd: todayEnd(),
      eventDate: toDayString(new Date()),
    });
    // 标题跟随模式，与 App 一致（App 的 AppBar 也是这两个文案）。
    wx.setNavigationBarTitle({ title: this.memoryId ? '编辑回忆' : '新的回忆' });
    this.refreshDerived();

    if (this.memoryId) this.load();
    else this.setData({ loading: false });
  },

  // ---- 编辑：载入已有内容 -------------------------------------------------

  async load() {
    this.setData({ loading: true });
    try {
      const m = await request({
        url: `/families/${this.familyId}/plugins/memory/memories/${this.memoryId}`,
      });
      this.setData({
        loading: false,
        title: m.title || '',
        body: m.body || '',
        location: m.location || '',
        mood: m.mood || '',
        visibility: m.visibility || 'family',
        eventDate: (m.event_date || '').slice(0, 10),
        media: [],
      });
      if (m.event_date) this.setData({ dateLabel: memoryFullDate(m.event_date) });
      this.refreshDerived();
      // 复用这次响应里的 media，不再多发一次详情请求。
      await this.applyMedia(m.media || []);
      this._loaded = true;
    } catch (e) {
      this.setData({ loading: false });
      wx.showToast({ title: e.message || '加载失败', icon: 'none' });
    }
  },

  /** 媒体列表 → 视图模型：换成 <image> 能用的直链（视频也要，留着做占位判断）。 */
  async applyMedia(list) {
    const { urls } = await memoryMediaUrls(
      this.familyId,
      list.map((x) => x.id)
    );
    this.setData({
      media: list.map((x) => ({
        id: x.id,
        kind: x.kind,
        url: urls[x.id] || '',
      })),
    });
    this.refreshDerived();
  },

  /** 保存后重拉媒体：以服务端为准，而不是拿本地的乐观结果充数。 */
  async reloadMedia(scope) {
    const m = await request({
      sessionScope: scope,
      url: `/families/${this.familyId}/plugins/memory/memories/${this.memoryId}`,
    });
    if (scope) assertCurrent(scope);
    await this.applyMedia(m.media || []);
  },

  // ---- 表单 ---------------------------------------------------------------

  /** 刷新所有由其它字段推导出来的状态（能否保存 / 能否继续加图 / 日期文案）。 */
  refreshDerived() {
    const totalMedia = this.data.media.length + this.data.pending.length;
    const next = {
      canSave: this.data.title.trim().length > 0,
      canAddMedia: totalMedia < LIMITS.mediaCount,
    };
    if (this.data.eventDate) next.dateLabel = memoryFullDate(this.data.eventDate);
    this.setData(next);
  },

  onInputTitle(e) {
    this.setData({ title: e.detail.value || '' });
    this.refreshDerived();
  },

  onInputBody(e) {
    this.setData({ body: e.detail.value || '' });
  },

  onInputLocation(e) {
    this.setData({ location: e.detail.value || '' });
  },

  onDateChange(e) {
    this.setData({ eventDate: e.detail.value || '' });
    this.refreshDerived();
  },

  onPickMood(e) {
    const v = e.currentTarget.dataset.v;
    // 再点一次同一个 = 取消（App 里心情是可选的，空串代表不设）。
    this.setData({ mood: this.data.mood === v ? '' : v });
  },

  onPickVisibility(e) {
    this.setData({ visibility: e.currentTarget.dataset.v || 'family' });
  },

  // ---- 媒体 ---------------------------------------------------------------

  async onAddMedia() {
    const remaining = LIMITS.mediaCount - this.data.media.length - this.data.pending.length;
    if (remaining <= 0) {
      wx.showToast({ title: `最多 ${LIMITS.mediaCount} 个`, icon: 'none' });
      return;
    }

    // wx.chooseMedia 是「隐私接口」。用户没同意过《用户隐私保护指引》时，微信会
    // 自己弹官方弹窗 —— 但那会发生在用户点完「＋」之后，很突兀。这里先打个招呼，
    // 让接下来的系统弹窗有铺垫（完整指引在「我的」页常驻，随时可看）。
    if (await needsPrivacyAuthorization()) {
      const go = await new Promise((resolve) => {
        wx.showModal({
          title: '需要你的同意',
          content:
            '从相册选照片或用相机拍摄，需要先阅读并同意《用户隐私保护指引》。完整指引可在「我的」页随时查看。',
          confirmText: '知道了',
          cancelText: '取消',
          success: (r) => resolve(!!r.confirm),
          fail: () => resolve(false),
        });
      });
      if (!go) return;
    }

    wx.chooseMedia({
      count: remaining,
      mediaType: ['image', 'video'],
      sourceType: ['album', 'camera'],
      sizeType: SIZE_TYPES,
      maxDuration: MAX_VIDEO_SECONDS,
      camera: 'back',
      success: (res) => this.acceptFiles(res.tempFiles || []),
      fail: (err) => {
        // 用户主动取消不算错误（errMsg 带 cancel），其余给个提示。
        const msg = (err && err.errMsg) || '';
        if (msg.indexOf('cancel') < 0) {
          wx.showToast({ title: '选择失败，请重试', icon: 'none' });
        }
      },
    });
  },

  /**
   * 把选好的临时文件收进待上传列表。超限的**在上传前就拦下**：让用户等两分钟
   * 换来一个 413，是很差的经验。真正的判决仍在服务端，这里只是预判。
   */
  acceptFiles(files) {
    const accepted = [];
    let skipped = 0;

    files.forEach((f) => {
      const isVideo = f.fileType === 'video';
      const cap = isVideo ? CAPS.video : CAPS.photo;
      if (f.size && f.size > cap) {
        skipped += 1;
        return;
      }
      accepted.push({
        key: uuidV4(),
        path: f.tempFilePath,
        kind: isVideo ? 'video' : 'photo',
        // 视频没有封面就用微信给的第一帧缩略图；照片直接用自己。
        thumb: f.thumbTempFilePath || f.tempFilePath,
        durationMs: isVideo && f.duration ? Math.round(f.duration * 1000) : null,
      });
    });

    if (skipped) {
      wx.showToast({
        title: `已跳过 ${skipped} 个超限文件（照片 ≤ ${capLabel(CAPS.photo)}、视频 ≤ ${capLabel(CAPS.video)}）`,
        icon: 'none',
      });
    }

    const next = this.data.pending.concat(accepted);
    this.setData({ pending: next });
    this.refreshDerived();
  },

  onRemoveExisting(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    this.removed.push(id);
    const media = this.data.media.filter((m) => m.id !== id);
    this.setData({ media: media });
    this.refreshDerived();
  },

  onRemovePending(e) {
    const key = e.currentTarget.dataset.key;
    if (!key) return;
    const pending = this.data.pending.filter((p) => p.key !== key);
    this.setData({ pending: pending });
    this.refreshDerived();
  },

  previewExisting(e) {
    const id = e.currentTarget.dataset.id;
    const hit = this.data.media.find((m) => m.id === id);
    if (!hit || !hit.url) return;
    wx.previewImage({
      urls: this.data.media.filter((m) => m.kind === 'photo' && m.url).map((m) => m.url),
      current: hit.url,
    });
  },

  previewPending(e) {
    const key = e.currentTarget.dataset.key;
    const hit = this.data.pending.find((p) => p.key === key);
    if (!hit) return;
    const sources = this.data.pending.map((p) => ({
      url: p.path,
      type: p.kind === 'video' ? 'video' : 'image',
    }));
    const index = this.data.pending.findIndex((p) => p.key === key);
    wx.previewMedia({
      sources: sources,
      current: index,
      fail() {
        wx.previewImage({ urls: [hit.path], current: hit.path });
      },
    });
  },

  // ---- 保存 ---------------------------------------------------------------

  async onSave() {
    if (!this.data.canSave || this.data.saving || this.data.loading) return;
    const scope = snapshot();

    const payload = {
      title: this.data.title.trim(),
      body: this.data.body.trim() || null,
      mood: this.data.mood || null,
      location: this.data.location.trim() || null,
      visibility: this.data.visibility,
      event_date: this.data.eventDate || null,
    };

    this.setData({ saving: true });
    try {
      let memoryId = this.memoryId;
      if (memoryId) {
        await request({
          sessionScope: scope,
          url: `/families/${this.familyId}/plugins/memory/memories/${memoryId}`,
          method: 'PUT',
          data: payload,
        });
        assertCurrent(scope);
      } else {
        const created = await request({
          sessionScope: scope,
          url: `/families/${this.familyId}/plugins/memory/memories`,
          method: 'POST',
          data: Object.assign({ client_id: this.createKey }, payload),
        });
        assertCurrent(scope);
        memoryId = created.id;
        this.memoryId = memoryId;
        this.setData({ memoryId: memoryId, editing: true });
      }

      // 删除用户移除的旧媒体。404 视为已完成（上一次重试可能已经删掉了）。
      const pendingRemoval = this.removed.slice();
      for (const id of pendingRemoval) {
        try {
          await request({
            sessionScope: scope,
            url: `/families/${this.familyId}/plugins/memory/memories/${memoryId}/media/${id}`,
            method: 'DELETE',
          });
        } catch (e) {
          if (e.statusCode !== 404) throw e;
        }
        assertCurrent(scope);
        this.removed = this.removed.filter((pendingId) => pendingId !== id);
      }

      const mediaTouched = pendingRemoval.length > 0 || this.data.pending.length > 0;
      const failedKeys = await this.uploadPending(memoryId, scope);

      // 媒体动过就从服务端重拉一遍：原先的占位、被服务端拒绝的文件各归各位，
      // 屏幕上剩的就是真实状态，不会出现「看着有图、其实没传上去」。
      // 纯文字改动不必多这一次往返。
      if (mediaTouched) await this.reloadMedia(scope);
      assertCurrent(scope);

      this.setData({
        saving: false,
        // 上传成功的移出待上传队列，失败的留下 —— 再按保存就是用同一个
        // client_id 重试，幂等。
        pending: this.data.pending.filter((p) => failedKeys.indexOf(p.key) >= 0),
      });
      this.refreshDerived();

      if (failedKeys.length) {
        wx.showToast({
          title: `回忆已保存，${failedKeys.length} 个文件上传失败，可重试`,
          icon: 'none',
        });
        return; // 留在页面让用户重试，不替他做决定。
      }

      wx.showToast({ title: '已保存', icon: 'success' });
      // 留半秒让 toast 露脸；navigateBack 失败说明这一页是「编译模式」直接打开的，
      // 没有上一页，退回首页而不是把用户困在表单里。
      setTimeout(() => {
        wx.navigateBack({
          fail() {
            wx.switchTab({ url: '/pages/home/home' });
          },
        });
      }, 500);
    } catch (e) {
      this.setData({ saving: false, progress: { done: 0, total: 0 } });
      wx.showToast({ title: e.message || '保存失败', icon: 'none' });
    }
  },

  /**
   * 逐个上传待传文件，返回上传失败的 key 列表。
   *
   * 刻意串行而不是并发：① 微信的 uploadFile 并发上传大文件时失败率明显上升；
   * ② 串行才能让「第 2/5 个」这种进度提示有意义；
   * ③ 服务端按 client_id 幂等，重试不会重复入账。
   */
  async uploadPending(memoryId, scope) {
    const failed = [];
    const list = this.data.pending;
    this.setData({ progress: { done: 0, total: list.length } });

    for (let i = 0; i < list.length; i += 1) {
      const item = list[i];
      const formData = { client_id: item.key };
      // 视频时长服务端不探测（不转码），由客户端补上。
      if (item.kind === 'video' && item.durationMs) {
        formData.duration_ms = String(item.durationMs);
      }
      try {
        await this.uploadOne(memoryId, item, scope);
      } catch (e) {
        // 登录态失效时不硬扛：后面的文件一样会失败，交给外层提示。
        if (e.statusCode === 401 || e.code === 'SESSION_CHANGED') throw e;
        failed.push(item.key);
      }
      this.setData({ progress: { done: i + 1, total: list.length } });
    }
    return failed;
  },

  /**
   * 传一个附件：**先试 COS 直传，失败退回经后端中转**。
   *
   * 直传是优化而不是唯一通路：票据过期、COS 域名漏配 uploadFile 白名单、
   * 弱网中断、服务端压根没开直传 —— 任何一种都不该让用户传不上一张照片。
   * 中转路径会重新按字节校验，所以两条路的落库结果是一致的，
   * 唯一的代价是直传留下的那个对象成了孤儿（无害：私有、无人引用）。
   */
  async uploadOne(memoryId, item, sessionScope) {
    const scope = sessionScope || snapshot();
    assertCurrent(scope);
    if (!isDirectDisabled()) {
      try {
        await uploadDirect({
          sessionScope: scope,
          familyId: this.familyId,
          memoryId: memoryId,
          filePath: item.path,
          clientId: item.key,
          kind: item.kind,
          durationMs: item.durationMs,
        });
        return;
      } catch (e) {
        if (e.statusCode === 401 || e.code === 'SESSION_CHANGED') throw e;
        // 其余原因统统静默回退，不打断整次保存。
      }
    }

    const formData = { client_id: item.key };
    // 视频时长服务端不探测（不转码），由客户端补上。
    if (item.kind === 'video' && item.durationMs) {
      formData.duration_ms = String(item.durationMs);
    }
    await upload({
      sessionScope: scope,
      url: `/families/${this.familyId}/plugins/memory/memories/${memoryId}/media`,
      filePath: item.path,
      name: 'file',
      formData: formData,
    });
  },
});
