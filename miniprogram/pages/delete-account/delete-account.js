// 注销账号 —— 不可逆操作的页面。
//
// 合规要求：微信《常见拒绝情形》3.4.1「在用户注销账号后应相应删除相关数据」。
// 后端已经按「全部删除」实现（内容、媒体对象、身份数据一并清除），所以这一页
// 的职责是**让用户在按下之前真正知道自己会失去什么**，而不是藏一句话就行。
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
        content: '账号将被注销，所有回忆、照片与留言会被永久删除，且无法恢复。确定继续吗？',
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
      // 漏清会留下指向已删对象的 URL。
      app.clearToken();
      app.clearSessionData();

      const stats = result || {};
      const parts = [];
      if (stats.families_dissolved) parts.push(`解散了 ${stats.families_dissolved} 个家庭`);
      if (stats.ownerships_transferred) parts.push(`移交了 ${stats.ownerships_transferred} 个家庭的主理人`);
      if (stats.storage_objects_deleted) parts.push(`删除了 ${stats.storage_objects_deleted} 个文件`);

      wx.showModal({
        title: '账号已注销',
        content: parts.length ? `已清除你的全部数据：${parts.join('，')}。` : '已清除你的全部数据。',
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
