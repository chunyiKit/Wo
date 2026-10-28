// 注册页：手机号 + 密码 + 确认密码，创建一个新 Wo 账号并把当前微信身份绑上去。
// 底部小字返回登录页（pages/bind）。
//
// 后端没有独立的注册端点 —— `/auth/wechat/bind` 内部是 login_or_register（与 App
// 的 `/auth/login` 同语义），所以这里提交的是同一个接口。由此带来两处必须诚实
// 处理的地方：
//
//   1. 手机号没人注册过 → 服务端建号并返回 is_new=true，正常路径
//   2. 手机号已经注册过 → 服务端按登录处理并返回 is_new=false
//
// 第 2 种情况不报错也不让用户重填 —— 密码既然校验通过，说明就是这个手机号的主人，
// 把他踢回登录页再输一遍纯属折腾。改为如实提示「已注册，已为你登录」再进首页。
//
// 确认密码只在前端比对（密码根本不会被拆成两次提交），它的唯一价值是让用户不必
// 等一次服务端往返才发现两次输入不一致 —— 见 utils/credential.js。
const { bindWithPhone } = require('../../utils/auth');
const {
  trimPhone,
  checkPhone,
  checkPassword,
  checkConfirm,
} = require('../../utils/credential');

const app = getApp();

// toast 之后再进首页，不然 reLaunch 会立刻把提示盖掉。
const REHOME_DELAY = 1400;

Page({
  data: {
    phone: '',
    password: '',
    confirm: '',
    loading: false,
    error: '',
  },

  onPhoneInput(e) {
    this.setData({ phone: e.detail.value, error: '' });
  },

  onPasswordInput(e) {
    this.setData({ password: e.detail.value, error: '' });
  },

  onConfirmInput(e) {
    this.setData({ confirm: e.detail.value, error: '' });
  },

  /**
   * 底部小字 → 登录页。优先返回（通常就是从登录页跳过来的，输入还在），
   * 直接编译进本页时没有上一页，才退化为跳转。
   */
  goLogin() {
    if (this.data.loading) return;
    wx.navigateBack({
      fail() {
        wx.navigateTo({ url: '/pages/bind/bind' });
      },
    });
  },

  async submit() {
    if (this.data.loading) return;

    const phone = trimPhone(this.data.phone);
    const { password, confirm } = this.data;

    // 逐项拦下，只报第一个问题 —— 一次列一堆红字反而没人看。
    const invalid = checkPhone(phone) || checkPassword(password) || checkConfirm(password, confirm);
    if (invalid) {
      this.setData({ error: invalid });
      return;
    }

    this.setData({ loading: true, error: '' });
    wx.showLoading({ title: '正在注册', mask: true });
    try {
      const res = await bindWithPhone(phone, password);
      wx.hideLoading();
      app.setToken(res.token);
      await app.refresh();
      this.setData({ loading: false });

      wx.showToast({
        title: res.is_new ? '账号已创建' : '这个手机号已经注册过了，已为你登录',
        icon: res.is_new ? 'success' : 'none',
        duration: res.is_new ? 1500 : 2000,
      });
      setTimeout(() => wx.reLaunch({ url: '/pages/home/home' }), REHOME_DELAY);
    } catch (e) {
      wx.hideLoading();
      this.setData({
        loading: false,
        error: e.message || '注册失败，请稍后重试',
      });
    }
  },
});
