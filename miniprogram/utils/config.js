// 后端地址。这是全项目唯一需要改地址的地方。
//
// 正式发布前必须确认三件事（**都已确认完毕**）：
//   1. baseUrl 是**已备案的域名 + HTTPS**（小程序不接受裸 IP，也不接受自签证书）
//   2. 微信公众平台 → 开发 → 开发管理 → 开发设置 里，把该域名加进
//      「request 合法域名」「uploadFile 合法域名」「downloadFile 合法域名」（已加），
//      并把 COS 域名额外加进 downloadFile（已加，否则图片全白）
//   3. project.config.json 的 setting.urlCheck 改回 true（已改）
//
// ⚠️ 切到 development 连本地后端时，必须把 urlCheck 改回 false —— 本地是
// http + localhost，两者都不在白名单里，否则工具会直接报「不在合法域名列表」。
const ENV = 'production';

const HOSTS = {
  production: 'https://wo.chunyi-work.online',
  development: 'http://localhost:8000',
};

module.exports = {
  env: ENV,
  baseUrl: HOSTS[ENV],
};
