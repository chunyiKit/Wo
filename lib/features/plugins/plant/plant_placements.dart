/// 摆放位置候选标签的默认值,仅用于后端数据到达前的首帧占位。
///
/// 真正的候选列表**全家共享、存在后端**(`plant_family_settings.placements`),
/// 由 `WoApi.plantSettings` / `updatePlantSettings` 读写;后端在未自定义时也会
/// 回退到同一套默认值。这个标签文本会作为环境信息发给 AI 分析植物状态。
const List<String> kDefaultPlacements = ['室内', '南阳台', '朝南窗', '朝北窗', '室外'];
