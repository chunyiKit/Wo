// 登录页：用已有的手机号 + 密码登录 Wo 账号，并把当前微信身份绑到这个账号上。
// 底部小字跳注册页（pages/register）。
//
// 后端语义是「登录即注册」（`/auth/wechat/bind` 内部走 login_or_register，与 App
// 的 `/auth/login` 一致）：手机号不存在时会直接建号。既然页面上已经分成登录 /
// 注册两个入口，这里就不能默默换个身份 —— 建了号必须如实告诉用户（见 submit 里
// 对 `is_new` 的处理），否则他以为登进了那个有数据的老账号。
const { bindWithPhone } = require('../../utils/auth');
const { trimPhone, checkPhone, checkPassword } = require('../../utils/credential');

const app = getApp();

Page({
  data: {
    phone: '',
    password: '',
    loading: false,
    error: '',
  },

  onPhoneInput(e) {
    this.setData({ phone: e.detail.value, error: '' });
  },

  onPasswordInput(e) {
    this.setData({ password: e.detail.value, error: '' });
  },

  /** 底部小字 → 注册页。用 navigateTo，因为用户很可能还会返回继续登录。 */
  goRegister() {
    if (this.data.loading) return;
    wx.navigateTo({ url: '/pages/register/register' });
  },

  async submit() {
    if (this.data.loading) return;

    const phone = trimPhone(this.data.phone);
    const { password } = this.data;

    // 逐项拦下，只报第一个问题 —— 一次列一堆红字反而没人看。
    const invalid = checkPhone(phone) || checkPassword(password);
    if (invalid) {
      this.setData({ error: invalid });
      return;
    }

    this.setData({ loading: true, error: '' });
    wx.showLoading({ title: '正在登录', mask: true });
    try {
      const res = await bindWithPhone(phone, password);
      wx.hideLoading();
      app.setToken(res.token);
      await app.refresh();
      this.setData({ loading: false });

      if (res.is_new) {
        // 让用户看清再进：reLaunch 会立刻盖掉 toast，所以延后一点再跳转。
        wx.showToast({
          title: '这个手机号还没有账号，已为你创建一个',
          icon: 'none',
          duration: 2000,
        });
        setTimeout(() => wx.reLaunch({ url: '/pages/home/home' }), 1200);
        return;
      }
      wx.reLaunch({ url: '/pages/home/home' });
    } catch (e) {
      wx.hideLoading();
      this.setData({
        loading: false,
        error: e.message || '登录失败，请稍后重试',
      });
    }
  },
});
