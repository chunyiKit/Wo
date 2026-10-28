// 回忆 · 时间线。
//
// 数据源与 App 首页卡片墙同源（/me/bootstrap），与 App 回忆列表同一个接口
// （GET /families/{fid}/plugins/memory/memories），所以两边看到的回忆完全一致，
// 包括 private 只对作者可见这条规则 —— 那在后端过滤，本页不做二次判断。
//
// 图片走 utils/media-url.js 换成预签名直链：<image> 发不出 Authorization 头，
// 直接喂 /raw 只会得到空白。
//
// 刷新口径（AGENTS.md：列表页不能「闪一下」）：
//   `_first` 只驱动首屏 loading；翻页 / 下拉 / onShow 都是**就地替换或追加**，
//   列表全程在屏。只有首屏失败后的「重试」才回到 loading。
const { requestWithMeta } = require('../../../utils/request');
const { memoryMediaUrls, memberAvatarUrl } = require('../../../utils/media-url');
const { memoryDateLabel, memoryMonthLabel } = require('../../utils/format');

const app = getApp();

const PAGE_SIZE = 20;
// 卡片上最多露几张图，多出来的用「+N」表示（App 的大卡也是这个思路）。
const THUMB_LIMIT = 3;

Page({
  data: {
    familyId: '',
    loading: true,
    loadingMore: false,
    error: '',
    empty: false,
    total: 0,
    hasMore: false,
    groups: [],
  },

  onLoad(query) {
    const familyId = (query && query.familyId) || '';
    const family = app.globalData.family;
    this.familyId = familyId || (family ? family.id : '');
    this.cursor = null;
    this.raw = [];
    this._loaded = false;

    this.setData({ familyId: this.familyId });
    if (!this.familyId) {
      this.setData({ loading: false, error: '没有可用的家庭，请回到首页重试' });
      return;
    }
    this.load({ first: true });
  },

  onShow() {
    // 从详情页返回时可能有新增/删除 —— 静默重拉第一页，不显示 loading。
    if (this._loaded) this.reloadSilently();
  },

  async onPullDownRefresh() {
    await this.reloadSilently();
    wx.stopPullDownRefresh();
  },

  onReachBottom() {
    if (this.data.hasMore && !this.data.loadingMore) this.loadMore();
  },

  // ---- 加载 ---------------------------------------------------------------

  /** 首屏 / 重试。 */
  async load(o) {
    const first = !!(o && o.first);
    if (first) this.setData({ loading: true, error: '' });

    try {
      const { data, meta } = await requestWithMeta({
        url: `/families/${this.familyId}/plugins/memory/memories?limit=${PAGE_SIZE}`,
      });
      this.raw = data || [];
      this.cursor = (meta && meta.cursor) || null;

      const groups = await this.toGroups(this.raw);
      this.setData({
        loading: false,
        error: '',
        empty: this.raw.length === 0,
        total: (meta && meta.total) || this.raw.length,
        hasMore: !!this.cursor,
        groups: groups,
      });
      this._loaded = true;
    } catch (e) {
      if (first) this.setData({ loading: false, error: e.message || '加载失败' });
    }
  },

  /** 下拉 / onShow：重拉第一页并就地替换，列表不闪。 */
  async reloadSilently() {
    try {
      const { data, meta } = await requestWithMeta({
        url: `/families/${this.familyId}/plugins/memory/memories?limit=${PAGE_SIZE}`,
      });
      this.raw = data || [];
      this.cursor = (meta && meta.cursor) || null;

      const groups = await this.toGroups(this.raw);
      this.setData({
        error: '',
        empty: this.raw.length === 0,
        total: (meta && meta.total) || this.raw.length,
        hasMore: !!this.cursor,
        groups: groups,
      });
    } catch (e) {
      // 静默刷新失败：保留屏幕上现有的列表，不打断用户。
    }
  },

  /** 翻页：追加到已有列表后面。 */
  async loadMore() {
    if (!this.cursor) return;
    this.setData({ loadingMore: true });
    try {
      const { data, meta } = await requestWithMeta({
        url:
          `/families/${this.familyId}/plugins/memory/memories` +
          `?limit=${PAGE_SIZE}&cursor=${encodeURIComponent(this.cursor)}`,
      });
      this.raw = this.raw.concat(data || []);
      this.cursor = (meta && meta.cursor) || null;

      // 重新分组而不是拼接分组：新一页可能落在已有月份里，也可能开新的月份。
      const groups = await this.toGroups(this.raw);
      this.setData({
        loadingMore: false,
        hasMore: !!this.cursor,
        total: (meta && meta.total) || this.raw.length,
        groups: groups,
      });
    } catch (e) {
      this.setData({ loadingMore: false });
      wx.showToast({ title: '加载更多失败', icon: 'none' });
    }
  },

  // ---- 视图模型 -----------------------------------------------------------

  /**
   * MemoryRead[] → 按月份分组的视图模型，并把媒体换成可直连的 URL。
   *
   * 一次批量换完所有直链（20 条 × 6 张 ≈ 120 个 URL 只发一个请求），
   * 不做成每张图一个请求 —— 那会直接把小程序请求并发打满。
   */
  async toGroups(list) {
    const familyId = this.familyId;

    const mediaIds = [];
    (list || []).forEach((m) => {
      (m.media || []).forEach((x) => {
        if (x.kind === 'photo') mediaIds.push(x.id);
      });
    });
    const { urls } = await memoryMediaUrls(familyId, mediaIds);

    // 作者头像：一个家庭通常两三个人，去重后各取一次。
    const authorIds = Array.from(new Set((list || []).map((m) => m.created_by).filter(Boolean)));
    const avatars = {};
    await Promise.all(
      authorIds.map(async (uid) => {
        avatars[uid] = await memberAvatarUrl(familyId, uid);
      })
    );

    const items = (list || []).map((m) => {
      const photos = (m.media || [])
        .filter((x) => x.kind === 'photo' && urls[x.id])
        .map((x) => ({ id: x.id, url: urls[x.id] }));
      const videoCount = (m.media || []).filter((x) => x.kind === 'video').length;

      // 渲染只露前 3 张，但预览要能看到全部 —— 两者分开存。
      const allUrls = photos.map((p) => p.url);

      return {
        id: m.id,
        title: m.title,
        body: m.body || '',
        mood: m.mood || '',
        location: m.location || '',
        dateLabel: memoryDateLabel(m.event_date),
        monthLabel: memoryMonthLabel(m.event_date),
        eventDate: m.event_date,
        private: m.visibility === 'private',
        authorName: m.author_name || '',
        authorEmoji: m.author_emoji || '',
        // 直链拿不到就回退 emoji —— 不能让头像位置留一个空洞。
        authorAvatar: avatars[m.created_by] || null,
        photos: photos.slice(0, THUMB_LIMIT),
        // 视频没有封面（后端不转码），只能记个数量。
        photoCount: allUrls.length,
        videoCount: videoCount,
        allPhotoUrls: allUrls,
        extraCount: allUrls.length > THUMB_LIMIT ? allUrls.length - THUMB_LIMIT : 0,
        commentCount: m.comment_count || 0,
      };
    });

    const groups = [];
    items.forEach((it) => {
      const last = groups[groups.length - 1];
      if (last && last.label === it.monthLabel) {
        last.items.push(it);
        last.count = last.items.length;
      } else {
        groups.push({ label: it.monthLabel, count: 1, items: [it] });
      }
    });
    return groups;
  },

  // ---- 交互 ---------------------------------------------------------------

  openDetail(e) {
    const id = e.currentTarget.dataset.id;
    if (!id) return;
    wx.navigateTo({
      url: `/package-memory/pages/detail/detail?familyId=${this.familyId}&id=${id}`,
      fail() {
        wx.showToast({ title: '打开失败，请重试', icon: 'none' });
      },
    });
  },

  /**
   * 点缩略图直接大图预览，不必先进详情 —— 看图是最常见的动作。
   * WXML 里用 catch:tap 绑定，避免冒泡到卡片的 openDetail。
   */
  previewPhoto(e) {
    const { id, mid } = e.currentTarget.dataset;
    const memory = this._findMemory(mid);
    if (!memory) return;

    const urls = memory.allPhotoUrls || [];
    if (!urls.length) return;
    const index = urls.indexOf(id);
    wx.previewImage({
      current: index >= 0 ? urls[index] : urls[0],
      urls: urls,
      fail() {
        wx.showToast({ title: '预览失败，请重试', icon: 'none' });
      },
    });
  },

  _findMemory(id) {
    for (const g of this.data.groups) {
      const hit = g.items.find((it) => it.id === id);
      if (hit) return hit;
    }
    return null;
  },

  onRetry() {
    this.load({ first: true });
  },

  /** 新建回忆。保存成功后编辑页会 navigateBack，本页 onShow 静默重拉第一页。 */
  onCreate() {
    if (!this.familyId) {
      wx.showToast({ title: '没有可用的家庭，请回到首页重试', icon: 'none' });
      return;
    }
    wx.navigateTo({
      url: `/package-memory/pages/edit/edit?familyId=${this.familyId}`,
      fail() {
        wx.showToast({ title: '打开失败，请重试', icon: 'none' });
      },
    });
  },

  onBack() {
    wx.navigateBack({
      fail() {
        wx.switchTab({ url: '/pages/home/home' });
      },
    });
  },
});
