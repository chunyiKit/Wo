// 启动引导页：决定「直接进主页」还是「去绑定」。
//
// 顺序：本地有 token → 先试 bootstrap（顺带验证 token 还有效）→ 有效就进主页；
// 无效或没有 token → wx.login 静默登录 → 已绑定进主页 / 未绑定显示引导。
const { silentLogin, canSilentLogin } = require('../../utils/auth');
const { openPrivacyContract } = require('../../utils/privacy');

const app = getApp();

Page({
  data: {
    status: 'loading', // loading | unbound | error
    message: '正在进入…',
  },

  async onLoad() {
    if (app.getToken()) {
      try {
        await app.refresh();
        return this.enter();
      } catch (e) {
        if (e.code === 'SESSION_CHANGED') return;
        // token 失效或网络抖动：清空后走微信静默登录，不要卡在空白页。
        app.clearToken();
      }
    }
    if (!canSilentLogin()) {
      this.setData({ status: 'unbound', message: '你已退出登录' });
      return;
    }
    await this.tryWechatLogin();
  },

  async tryWechatLogin() {
    this.setData({ status: 'loading', message: '正在进入…' });
    try {
      const res = await silentLogin();
      if (res.bound) {
        app.setToken(res.token);
        await app.refresh();
        return this.enter();
      }
      this.setData({
        status: 'unbound',
        message: '这个微信还没有绑定 Wo 账号',
      });
    } catch (e) {
      this.setData({
        status: 'error',
        message: e.message || '微信登录失败，请重试',
      });
    }
  },

  enter() {
    // home 是 tabBar 页，用 switchTab 进入（reLaunch 也能进，但 switchTab
    // 语义更准：进入的是壳的首页，而不是一次性页面）。
    wx.switchTab({ url: '/pages/home/home' });
  },

  goBind() {
    wx.navigateTo({ url: '/pages/bind/bind' });
  },

  // 提审合规：登录前让用户能读到隐私指引，且不能默认勾选同意。
  openPrivacy() {
    openPrivacyContract();
  },
});
