/// 路由路径常量。集中放一处，避免业务里散落 magic string。
class WoRoutes {
  WoRoutes._();

  // 启动 / 引导 / 登录
  static const splash = '/';
  static const onboarding = '/onboarding';
  static const login = '/login';

  // 加入 / 创建家庭
  static const joinLanding = '/join';
  static const joinByCode = '/join/code';
  static const joinByScan = '/join/scan';
  static const createFamily = '/join/create';

  // 主壳子（底 Tab）
  static const home = '/home';
  static const messages = '/messages';
  static const me = '/me';

  // 二级页
  static const marketplace = '/marketplace';
  static const pluginDetail = '/marketplace/plugin/:id';
  static const familyManage = '/home/family';
  static const familyInvite = '/home/family/invite';
  static const settings = '/me/settings';
  static const appearance = '/me/settings/appearance';
  static const notificationPrefs = '/me/settings/notifications';
  static const changePassword = '/me/settings/password';
  static const about = '/me/about';
  static const notifications = '/notifications';

  static String pluginDetailFor(String id) => '/marketplace/plugin/$id';

}
