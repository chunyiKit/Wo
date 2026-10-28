// 全局：会话令牌 + 首屏聚合数据（bootstrap）。
//
// 小程序没有 App 端 WoSession 那样的 ChangeNotifier，所以约定：
// 登录态与首屏数据放 globalData，页面在 onShow 里读；跨页面需要刷新时直接
// 调 app.refresh()，不做全局事件总线（当前页面量级用不上）。
const { request } = require('./utils/request');
const { snapshot, assertCurrent, markManualLogout } = require('./utils/session');
const {
  getToken,
  setToken,
  clearToken,
} = require('./utils/auth');

App({
  globalData: {
    user: null,
    family: null,
    families: [],
    // 已安装插件（含 preview），首页卡片墙的数据源。由 loadBootstrap 填充。
    plugins: [],
    pluginCount: 0,
    unreadCount: 0,
    wechatBound: false,
  },

  onLaunch() {
    // 令牌失效时（服务端撤销 / 改密 / 解绑）统一清理，页面只需处理跳转。
    require('./utils/request').setSessionInvalidHandler(() => {
      this.handleSessionInvalid();
    });
  },

  getToken,
  setToken(token) {
    setToken(token);
    this.clearSessionData();
  },
  clearToken() {
    clearToken();
    this.clearSessionData();
  },

  handleSessionInvalid() {
    this.clearToken();
    wx.reLaunch({ url: '/pages/index/index' });
  },

  /** 清空会话相关的 globalData。退出 / 掉线 / 解绑都走这里，避免漏字段。 */
  clearSessionData() {
    this.globalData.user = null;
    this.globalData.family = null;
    this.globalData.families = [];
    this.globalData.plugins = [];
    this.globalData.pluginCount = 0;
    this.globalData.unreadCount = 0;
    this.globalData.wechatBound = false;
    // 直链是签发给当前账号的，换账号后必须作废 —— 否则会以别人的身份
    // 拿到（或复用）指向私密对象的 URL。
    require('./utils/media-url').clearMediaCache();
  },

  /** 拉首屏聚合数据。401 由请求层的 setSessionInvalidHandler 统一处理。 */
  async loadBootstrap() {
    const scope = snapshot();
    const data = await request({ url: '/me/bootstrap' });
    assertCurrent(scope);
    this.globalData.user = data.user || null;
    this.globalData.family = data.current_family || null;
    this.globalData.families = data.families || [];
    this.globalData.plugins = data.installed_plugins || [];
    this.globalData.pluginCount = (data.installed_plugins || []).length;
    this.globalData.unreadCount = data.unread_count || 0;
    return data;
  },

  /** 查当前账号的微信绑定状态。 */
  async loadWechatBinding() {
    const scope = snapshot();
    const data = await request({ url: '/me/wechat' });
    assertCurrent(scope);
    this.globalData.wechatBound = !!data.bound;
    return data;
  },

  /** 重新拉首屏 + 绑定状态。页面 onShow 里调。 */
  async refresh() {
    const scope = snapshot();
    await this.loadBootstrap();
    assertCurrent(scope);
    await this.loadWechatBinding();
    assertCurrent(scope);
  },

  /** 手动退出立即清本地，撤销旧会话在后台完成，保持退出状态直至用户主动登录。 */
  async logout() {
    markManualLogout();
    const revocation = getToken()
      ? request({ url: '/auth/logout', method: 'POST' }) : Promise.resolve();
    this.clearToken();
    wx.reLaunch({ url: '/pages/index/index' });
    try {
      await revocation;
    } catch (e) {
      // 离线退出：服务端撤销不了就算了，本地必须清干净。
    }
  },
});
