// 注销账号 —— 不可逆操作的页面。
//
// 清空账号身份和登录凭据；仍有成员的家庭保留历史内容与附件，提交者匿名展示。
// 页面必须说明保留范围、原有可见性及仅本人家庭的解散规则。
//
// 三道闸：说清楚后果 → 输当前密码 → 勾「我已知悉」。
// 密码这道是后端要求的（挡住拿到已登录手机的人），勾选这道是给人的最后一次
// 犹豫机会 —— 不可逆操作值得多一次停顿。
const { request } = require('../../utils/request');

const app = getApp();

Page({
  data: {
    password: '',
    agreed: false,
    submitting: false,
  },

  onPassword(e) {
    this.setData({ password: e.detail.value });
  },

  onToggleAgree(e) {
    this.setData({ agreed: !!e.detail.value.length });
  },

  canSubmit() {
    if (!this.data.password) {
      wx.showToast({ title: '请输入当前密码', icon: 'none' });
      return false;
    }
    if (!this.data.agreed) {
      wx.showToast({ title: '请先确认已知悉后果', icon: 'none' });
      return false;
    }
    return true;
  },

  async submit() {
    if (this.data.submitting || !this.canSubmit()) return;

    // 最后一道：密码已经输过、勾已经打过，这里再拦一次纯粹是因为不可逆。
    const go = await new Promise((resolve) => {
      wx.showModal({
        title: '永久注销',
        content: '账号与登录凭据将被清除。仍有成员的家庭会保留回忆、照片、留言及其他记录，并匿名显示提交者；原有可见范围不变。仅剩你一人的家庭会解散。确定继续吗？',
        confirmText: '注销',
        confirmColor: '#C0492B',
        cancelText: '再想想',
        success: (r) => resolve(!!r.confirm),
        fail: () => resolve(false),
      });
    });
    if (!go) return;

    this.setData({ submitting: true });
    wx.showLoading({ title: '正在注销', mask: true });

    try {
      const result = await request({
        url: '/me/delete-account',
        method: 'POST',
        data: { password: this.data.password },
      });
      wx.hideLoading();

      // 服务端已经作废了所有会话（App 端也一样），本地直接清掉回引导页。
      // 走 clearSessionData 而不是逐字段置空：直链缓存也是账号相关的，
      // 避免下一个账号继续使用本账号签发的媒体直链。
      app.clearToken();
      app.clearSessionData();

      const stats = result || {};
      const parts = [];
      if (stats.families_dissolved) parts.push(`解散了 ${stats.families_dissolved} 个家庭`);
      if (stats.ownerships_transferred) parts.push(`移交了 ${stats.ownerships_transferred} 个家庭的主理人`);

      wx.showModal({
        title: '账号已注销',
        content: '账号身份与登录凭据已清除。仍有成员的家庭中的历史内容和附件已保留，提交者匿名展示。'
          + (parts.length ? `已${parts.join('，')}。` : ''),
        showCancel: false,
        confirmText: '知道了',
        success: () => wx.reLaunch({ url: '/pages/index/index' }),
      });
    } catch (e) {
      wx.hideLoading();
      this.setData({ submitting: false });
      wx.showToast({ title: e.message || '注销失败，请重试', icon: 'none' });
    }
  },
});
