// 我的：P0 的验收页 —— 证明「同一个账号、同一个家庭」。
// 展示头像、昵称、当前家庭、微信绑定状态，以及解绑 / 退出 / 隐私指引。
//
// 头像走 `/me/avatar-url` 拿预签名直链（<image> 发不出 Authorization 头，
// 必须走直链）；没传过头像时安静回退到 emoji。
const { request } = require('../../utils/request');
const { myAvatarUrl } = require('../../utils/media-url');
const { openPrivacyContract } = require('../../utils/privacy');

const app = getApp();

Page({
  data: {
    loading: true,
    error: '',
    user: null,
    family: null,
    familyCount: 0,
    bound: false,
    hasUnionid: false,
    myAvatar: '', // 预签名直链；空则显示 emoji
  },

  onLoad() {
    this._loaded = false;
  },

  async onShow() {
    await this.load();
  },

  // 「我的」是 tabBar 页，每次切回来都会 onShow。首屏才转圈，之后静默更新，
  // 否则每次切 tab 都闪一下加载态。
  async load() {
    const first = !this._loaded;
    if (first) this.setData({ loading: true, error: '' });

    try {
      await app.refresh();
      this.setData({
        loading: false,
        error: '',
        user: app.globalData.user,
        family: app.globalData.family,
        familyCount: (app.globalData.families || []).length,
        bound: app.globalData.wechatBound,
      });
      this._loaded = true;
      // 头像不参与首屏的成败判断：拿不到就继续用 emoji，不转圈也不报错。
      this.loadAvatar();
    } catch (e) {
      if (first) this.setData({ loading: false, error: e.message || '加载失败' });
    }
  },

  async onPullDownRefresh() {
    await this.load();
    wx.stopPullDownRefresh();
  },

  onRetry() {
    this._loaded = false;
    this.load();
  },

  // 直链有 1 小时缓存，但「没传过头像是常态」返回的是 404、不进缓存 ——
  // 所以自己记一下，免得每次切 tab 都白打一次请求。
  async loadAvatar() {
    if (this.data.myAvatar || this._avatarMiss) return;
    const url = await myAvatarUrl();
    if (url) this.setData({ myAvatar: url });
    else this._avatarMiss = true;
  },

  // 直链过期 / COS 域名漏配 / 对象已删 —— 都安静回退 emoji。一张头像不值得
  // 打断页面，而且这正是「降级不留破图」的意义。
  onAvatarError() {
    this._avatarMiss = true;
    this.setData({ myAvatar: '' });
  },

  // 提审合规：隐私指引要有个固定入口，不能只在弹窗里出现一次。
  openPrivacy() {
    openPrivacyContract();
  },

  goDeleteAccount() {
    wx.navigateTo({ url: '/pages/delete-account/delete-account' });
  },

  onUnbind() {
    wx.showModal({
      title: '解绑微信',
      content: '解绑后小程序会被退出，下次进入需要重新用手机号登录。App 不受影响。',
      confirmText: '解绑',
      confirmColor: '#C0492B',
      success: async (res) => {
        if (!res.confirm) return;
        wx.showLoading({ title: '处理中', mask: true });
        try {
          await request({ url: '/me/wechat', method: 'DELETE' });
          wx.hideLoading();
          // 服务端已撤销本小程序的所有会话，本地直接清掉回引导页。
          app.clearToken();
          app.globalData.user = null;
          app.globalData.family = null;
          wx.reLaunch({ url: '/pages/index/index' });
        } catch (e) {
          wx.hideLoading();
          wx.showToast({ title: e.message || '解绑失败', icon: 'none' });
        }
      },
    });
  },

  onLogout() {
    wx.showModal({
      title: '退出登录',
      content: '小程序会回到登录引导页。',
      confirmText: '退出',
      success: (res) => {
        if (res.confirm) app.logout();
      },
    });
  },
});
