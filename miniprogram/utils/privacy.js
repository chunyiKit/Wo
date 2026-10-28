// 隐私合规（提审硬性要求，2023-10-17 起对所有小程序生效）。
//
// 背景：只要小程序调用了「隐私接口」（我们用 wx.chooseMedia，对应相册/摄像头），
// 就必须先在 MP 后台配置《小程序用户隐私保护指引》并声明对应的信息类型，
// 否则调用会直接失败：errno 112 "api scope is not declared in the privacy agreement"。
//
// 用户在同意之前，微信会在隐私接口被调用时弹**官方弹窗**（我们不做处理也会弹）。
// 这里做的两件事是官方弹窗之外的补充：
//   1. 提供一个「读隐私指引」的入口（审核要求：小程序内要有固定可访问的入口）
//   2. 让页面能提前知道「用户还没同意」，从而在合适的时机提示，
//      而不是等用户辛辛苦苦选完照片才被弹窗打断。

/** 打开 MP 后台配置的《小程序用户隐私保护指引》。未配置时安静失败。 */
function openPrivacyContract() {
  if (!wx.openPrivacyContract) return;
  wx.openPrivacyContract({
    fail() {
      wx.showToast({ title: '隐私指引暂未开放', icon: 'none' });
    },
  });
}

/**
 * 用户是否还有待同意的隐私指引。
 * 低版本基础库（< 2.32.3）没有这个接口 —— 那时也不会拦截隐私接口，
 * 所以按「已同意」处理是安全的。
 */
function needsPrivacyAuthorization() {
  return new Promise((resolve) => {
    if (!wx.getPrivacySetting) return resolve(false);
    wx.getPrivacySetting({
      success: (res) => resolve(!!res.needAuthorization),
      fail: () => resolve(false),
    });
  });
}

module.exports = { openPrivacyContract, needsPrivacyAuthorization };
