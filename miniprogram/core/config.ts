// 仅公开配置。AppSecret、COS 密钥永远不能写入客户端。
export const config = {
  apiOrigin: 'https://trek.chunyi-work.online',
  // 用户已选定 trek；当前公开路由仍为 502，完成后端路由、迁移并获准真实联调后才开启。
  connectionReady: false,
  // 可选：放在已备案 HTTPS 静态域名的精简字体；空值使用系统字体。
  fontUrl: '',
};
export function origin(): string {
  if (!config.connectionReady) throw new Error('API 接入待完成：请先配置可信 HTTPS 证书与测试后端');
  const value = config.apiOrigin;
  if (!/^https:\/\/[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?(?::443)?$/i.test(value)
      || /\.(invalid|localhost)(?::443)?$/i.test(value)
      || /^https:\/\/[\d.]+(?::443)?$/.test(value)) {
    throw new Error('请先配置正式 HTTPS API 域名');
  }
  return value;
}
export function apiUrl(path: string): string {
  if (!/^\/(?:api\/v1\/)?[a-zA-Z]/.test(path) || path.includes('..') || path.includes('\\') || path.includes('#')) {
    throw new Error('无效的 API 路径');
  }
  return origin() + (path.startsWith('/api/v1/') ? path : '/api/v1' + path);
}
