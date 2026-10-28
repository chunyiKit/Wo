// 回忆 · 详情：媒体 + 正文 + 留言（P2 读） + 评论/编辑/删除（P3 写）。
//
// 与列表页同一套规则：媒体走预签名直链（<image> 发不出 Authorization 头），
// 头像拿不到就回退 emoji，private 记忆的可见性由后端判断。
//
// 视频后端不转码、没有封面，所以：
//   · 轮播里只放照片；
//   · 视频做成一格「▶ 视频」入口，点开走 wx.previewMedia（混排照片与视频）。
//
// 写操作全部「发完就地重拉」，不做乐观插入：留言的作者头像、emoji、计数都由
// 服务端拼好，本地拼出来的东西迟早和真实响应不一致。
// 从编辑页返回时靠 onShow 静默重拉 —— 详情页转圈会让人以为改丢了。
const { request } = require('../../../utils/request');
const { memoryMediaUrls, memberAvatarUrl } = require('../../../utils/media-url');
const { memoryFullDate } = require('../../utils/format');
const { LIMITS } = require('../../utils/memory-form');

const app = getApp();

Page({
  data: {
    loading: true,
    error: '',
    familyId: '',
    memoryId: '',
    title: '',
    body: '',
    mood: '',
    location: '',
    fullDate: '',
    private: false,
    authorName: '',
    authorEmoji: '',
    authorAvatar: null,
    photos: [],
    videos: [],
    videoCount: 0,
    commentCount: 0,
    comments: [],
    // 当前用户在家庭里的 id —— 用来判断「这条留言是不是我发的」。
    myId: '',
    draft: '',
    sending: false,
    limits: LIMITS,
  },

  onLoad(query) {
    // 同上：编译模式直接打开详情页时 familyId 为空，退回当前家庭。
    const family = app.globalData.family;
    this.familyId = (query && query.familyId) || (family ? family.id : '');
    this.memoryId = (query && query.id) || '';
    this._loaded = false;
    this.setData({ familyId: this.familyId, memoryId: this.memoryId });

    if (!this.familyId || !this.memoryId) {
      this.setData({ loading: false, error: '缺少家庭或回忆信息' });
      return;
    }
    this.load();
  },

  onShow() {
    // 从编辑页返回、或别人刚留言：静默重拉。详情页内容变了却毫无反应最容易被
    // 当成「没保存成功」，所以这里宁可多一次请求。
    if (this._loaded) this.load({ silent: true });
  },

  async onPullDownRefresh() {
    await this.load({ silent: true });
    wx.stopPullDownRefresh();
  },

  async load(o) {
    const silent = !!(o && o.silent);
    if (!silent) this.setData({ loading: true, error: '' });

    try {
      const m = await request({
        url: `/families/${this.familyId}/plugins/memory/memories/${this.memoryId}`,
      });

      // 照片和视频都要换直链：视频虽然不在轮播里，但 previewMedia 也只认
      // 无头的 https 链接。
      const ids = (m.media || []).map((x) => x.id);
      const { urls } = await memoryMediaUrls(this.familyId, ids);

      const photos = [];
      const videos = [];
      (m.media || []).forEach((x) => {
        if (!urls[x.id]) return;
        if (x.kind === 'video') videos.push({ id: x.id, url: urls[x.id] });
        else photos.push({ id: x.id, url: urls[x.id] });
      });

      const me = app.globalData.user;
      const myId = me && me.id ? me.id : '';

      // 作者的头像：留言里出现的每个人去重后各取一次。
      const authorIds = Array.from(
        new Set(
          [m.created_by]
            .concat((m.comments || []).map((c) => c.author_id))
            .filter(Boolean)
        )
      );
      const avatars = {};
      await Promise.all(
        authorIds.map(async (uid) => {
          avatars[uid] = await memberAvatarUrl(this.familyId, uid);
        })
      );

      this.setData({
        loading: false,
        error: '',
        title: m.title || '',
        body: m.body || '',
        mood: m.mood || '',
        location: m.location || '',
        fullDate: memoryFullDate(m.event_date),
        private: m.visibility === 'private',
        authorName: m.author_name || '',
        authorEmoji: m.author_emoji || '',
        authorAvatar: m.created_by ? avatars[m.created_by] || null : null,
        photos: photos,
        videos: videos,
        videoCount: videos.length,
        commentCount: m.comment_count || 0,
        myId: myId,
        comments: (m.comments || []).map((c) => ({
          id: c.id,
          body: c.body,
          authorId: c.author_id || '',
          authorName: c.author_name || '',
          authorEmoji: c.author_emoji || '',
          authorAvatar: avatars[c.author_id] || null,
          mine: !!myId && c.author_id === myId,
        })),
      });
      this._loaded = true;
    } catch (e) {
      // 404 最常见的来源：这条回忆被删了，或者它是别人的 private 记忆。
      this.setData({
        loading: false,
        error: e.statusCode === 404 ? '这条回忆不存在或你没有权限查看' : e.message || '加载失败',
      });
    }
  },

  // ---- 看图 / 看视频 ------------------------------------------------------

  /** previewMedia 能混排照片与视频，所以统一走它；不支持时退回 previewImage。 */
  openGallery(e) {
    const id = e.currentTarget.dataset.id;
    const sources = this.data.photos
      .map((p) => ({ id: p.id, url: p.url, type: 'image' }))
      .concat(this.data.videos.map((v) => ({ id: v.id, url: v.url, type: 'video' })));
    if (!sources.length) return;

    const index = Math.max(
      0,
      sources.findIndex((s) => s.id === id)
    );
    wx.previewMedia({
      sources: sources.map((s) => ({ url: s.url, type: s.type })),
      current: index,
      fail: () => {
        const photoUrls = this.data.photos.map((p) => p.url);
        if (!photoUrls.length) return;
        wx.previewImage({
          urls: photoUrls,
          current: photoUrls[Math.min(index, photoUrls.length - 1)],
          fail() {
            wx.showToast({ title: '预览失败，请重试', icon: 'none' });
          },
        });
      },
    });
  },

  // ---- 留言 ---------------------------------------------------------------

  onCommentInput(e) {
    this.setData({ draft: e.detail.value || '' });
  },

  async onSendComment() {
    const body = (this.data.draft || '').trim();
    if (!body || this.data.sending) return;

    this.setData({ sending: true });
    try {
      await request({
        url: `/families/${this.familyId}/plugins/memory/memories/${this.memoryId}/comments`,
        method: 'POST',
        data: { body: body },
      });
      this.setData({ draft: '', sending: false });
      await this.load({ silent: true });
    } catch (e) {
      this.setData({ sending: false });
      wx.showToast({ title: e.message || '留言失败', icon: 'none' });
    }
  },

  onDeleteComment(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    wx.showModal({
      title: '删除留言',
      content: '删除后不可恢复。',
      confirmText: '删除',
      confirmColor: '#C0492B',
      success: async (res) => {
        if (!res.confirm) return;
        try {
          await request({
            url:
              `/families/${this.familyId}/plugins/memory/memories/${this.memoryId}` +
              `/comments/${id}`,
            method: 'DELETE',
          });
          await this.load({ silent: true });
        } catch (err) {
          // 403 = 不是自己发的（后端也拦），404 = 已经被删了。
          wx.showToast({ title: err.message || '删除失败', icon: 'none' });
        }
      },
    });
  },

  // ---- 编辑 / 删除 --------------------------------------------------------

  onEdit() {
    wx.navigateTo({
      url:
        `/package-memory/pages/edit/edit?familyId=${this.familyId}&id=${this.memoryId}`,
      fail() {
        wx.showToast({ title: '打开失败，请重试', icon: 'none' });
      },
    });
  },

  onDelete() {
    wx.showModal({
      title: '删除回忆',
      content: `确定删除「${this.data.title}」吗？照片和留言会一起删除，不可撤销。`,
      confirmText: '删除',
      confirmColor: '#C0492B',
      success: async (res) => {
        if (!res.confirm) return;
        wx.showLoading({ title: '删除中', mask: true });
        try {
          await request({
            url: `/families/${this.familyId}/plugins/memory/memories/${this.memoryId}`,
            method: 'DELETE',
          });
          wx.hideLoading();
          wx.showToast({ title: '已删除', icon: 'success' });
          setTimeout(() => {
            wx.navigateBack({
              fail() {
                wx.switchTab({ url: '/pages/home/home' });
              },
            });
          }, 500);
        } catch (e) {
          wx.hideLoading();
          wx.showToast({ title: e.message || '删除失败', icon: 'none' });
        }
      },
    });
  },

  onRetry() {
    this.load();
  },

  onBack() {
    wx.navigateBack({
      fail() {
        wx.switchTab({ url: '/pages/home/home' });
      },
    });
  },
});
