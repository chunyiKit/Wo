// 插件注册表：后端 plugin_id → 小程序分包页面。
//
// 为什么映射表放在小程序侧（而不是后端 manifest 加字段）：
// 后端一个插件加个字段要改 `PluginManifest`、迁移、重发后端；而小程序本来就必须
// 为每个插件建一个分包目录。把映射放在这里，接入新插件的成本收敛到小程序单侧 ——
// 后端零改动。代价是两边可能不同步，所以下面 `entryFor` 对未注册插件返回 null，
// 卡片会显示「暂未开放」而不是跳到一个 404 的空白页。
//
// 接入一个新插件要做的全部事情：
//   1. 新建 package-<id>/ 分包目录并写页面
//   2. app.json 的 subpackages 里加一条
//   3. 下面 REGISTRY 加一行
// 主包不动，符合「一个插件一个分包」的分包策略（主包只放账号与壳）。
const REGISTRY = {
  memory: {
    // P1 只有骨架；P2 接时间线 / 详情（读）；P3 接新建 / 编辑 / 上传 / 留言（写）。
    path: '/package-memory/pages/timeline/timeline',
    stage: 'readwrite',
  },
};

/**
 * 取插件在小程序里的落地页；未接入返回 null。
 * @param {string} pluginId 后端的 plugin_id
 * @returns {{path: string, stage: string} | null}
 */
function entryFor(pluginId) {
  return REGISTRY[pluginId] || null;
}

/**
 * 拼出带家庭上下文的跳转地址。插件路由都是 /families/{fid}/plugins/<id>/... ，
 * 页面需要知道自己在哪个家庭里工作。
 * @returns {string | null}
 */
function pageUrlFor(pluginId, familyId) {
  const entry = entryFor(pluginId);
  if (!entry) return null;
  const query = familyId ? '?familyId=' + encodeURIComponent(familyId) : '';
  return entry.path + query;
}

/** 已接入的插件 id 列表（调试 / 空态提示用）。 */
function supportedIds() {
  return Object.keys(REGISTRY);
}

module.exports = { REGISTRY, entryFor, pageUrlFor, supportedIds };
