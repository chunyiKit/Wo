## Context

项目已有成熟的插件平台:每个插件 = `manifest.py + models.py + routes.py + service.py + __init__.py`,在 `registry.register` 注册,首页卡片由 registry 的 preview 钩子组合。已有的可复用基础设施:

- **共享 AI 模块** `app/services/ai`:provider-agnostic,`ai_complete` / `ai_complete_text`,当前后端为 Kimi(Moonshot,OpenAI 兼容)。**但 `AiMessage.content` 是纯 `str`,不支持图片**。`movie` 插件示范了"后台任务调 AI → 写 `ai_status` (ready/failed) → 独立 DB session → 绝不抛异常崩溃"的范式。
- **blob 存储抽象** `app/core/storage`:照片走 COS 私有桶 + 预签名 URL(memory/photo 插件已用)。
- **提醒范式** `app/plugins/subscription/reminders.py`:lifespan 启动轮询循环,每轮 `check_due_*` 计算到期、幂等通知(`last_notified_*`)、滚动 `next_due`。
- **完全空白**:天气、定位——无任何现成代码。

本插件横跨"共享层"与"插件层",且引入 1 个外部依赖(和风天气)与 1 处向后兼容敏感的共享层改动(AI 多模态),故需要本设计文档。

## Goals / Non-Goals

**Goals:**
- 多模态能力沉淀在 `app/services/ai`,**任何插件**可传图片;movie 等纯文本调用方零改动、行为不变。
- 天气能力沉淀为独立共享模块 `app/services/weather`,镜像 ai 模块结构,带缓存/限流,Provider 可配置;只供应天气数据,不含业务逻辑。
- 植物插件实现"建档 → 拍照记录 → AI 看图+天气分析 → 养护建议 → 浇水/施肥到期提醒"闭环;周期由用户定、AI 给建议值。

**Non-Goals:**
- 不做植物图鉴/社区/电商。
- 不记录"谁添加/养护"该植物(无需接头像)。
- weather 模块**不**做天气预报多日聚合、不做植物相关推断(那是 plant 插件的事)。
- 不做传感器硬件接入(温湿度计等);环境量来自天气 API + 用户填的摆放。
- 首版不做"AI 看多张历史照片对比";趋势以**历史记录的文本摘要**喂给模型,降低 token 成本(见 Open Questions)。

## Decisions

### D1. AI 多模态:`content` 扩展为联合类型,向后兼容

`AiMessage.content: str` → `str | list[ContentPart]`,其中 `ContentPart` 为
`{type: "text", text: str}` 或 `{type: "image", image: <data-url 或 url>}`。

- `to_dict()` / `build_payload()`:`content` 为 `str` 时**原样输出**(老调用方字节级不变);为 `list` 时转成 OpenAI 兼容的 `[{"type":"text",...}, {"type":"image_url","image_url":{"url": ...}}]`。
- 新增便捷构造器(如 `AiMessage.with_image(text, image_data_url)`)或在 service 层加 `ai_complete_vision(...)`,让 plant 插件调用直观。
- 图片以 base64 `data:` URL 传入模型(植物照片在我们 COS 私有桶,模型无法直接拉取私有 URL,故内联 base64 最稳)。**注意:base64 只是喂模型的临时载体,不是存储方式**——照片本体仍持久化在 COS(见 D4 数据流),两者是"同一份图、两个用途"。
- `config.kimi_model`:`kimi-k2.5` → K2.6 多模态档(精确 model id 实现时按和风/Moonshot 平台当时文档核对)。

**备选**:① 新建独立 `AiVisionMessage` 类型——否决,割裂接口、service 要分叉。② 只在 plant 插件内手搓 vision 请求——否决,违背"共享层"原则,别的插件无法复用。

### D2. 天气模块:镜像 `services/ai` 的结构

```
app/services/weather/
  types.py     WeatherProvider(Protocol) + WeatherSnapshot + WeatherError / WeatherNotConfiguredError
  service.py   get_weather(lat, lon) → WeatherSnapshot   ← 插件唯一入口
  qweather.py  QWeatherClient.from_settings, configured 守卫, httpx 调用
  __init__.py
```

- `WeatherSnapshot`(frozen dataclass):温度、湿度、UV/光照、降水、天况文字、观测时间、数据来源位置。
- **缓存**:service 层按 `round(lat,lon)` 量化 key + TTL(默认数十分钟,config 可调),进程内字典即可(低并发,见 user 背景);避免每条记录都打和风。
- **限流/降级**:key 未配置 → 抛 `WeatherNotConfiguredError`,调用方当"功能不可用"处理而非崩溃(对齐 ai 模块语义)。和风请求失败 → 返回 `None`/抛 `WeatherError`,plant 侧降级为"无天气,仅看图分析"。
- weather 模块**不 import** 任何 plant 代码;plant 单向依赖 weather。

**备选**:高德天气(env 里有 amap skill,省一个 key)——否决,粒度到市/区且无实时湿度/UV,喂给视觉模型上下文太薄。和风免费开发版额度对家用足够。

### D3. 数据模型:Plant 1—N PlantLog + 家庭级默认环境

```
Plant (一株植物)                         PlantLog (一条养护记录)
  family_id (隔离键)                        plant_id (FK)
  name / species(可AI识别)                  created_at
  cover photo (storage key + version)        photo (storage key + version)
  placement: 室内/阳台/朝南窗… (枚举)         env_snapshot: JSON(当时天气+摆放)
  water_interval_days  (用户设, AI建议)       ai_status: pending/ready/failed
  fert_interval_days   (用户设, AI建议)       ai_assessment: text(状态点评)
  next_water_due / next_fert_due (date)       ai_advice: JSON(浇水/施肥/修剪建议)
  last_notified_water_due / _fert_due          ai_suggested_water_days / _fert_days
                                               note: 用户备注
家庭级默认环境 (存一次):location(lat/lon/城市)。Plant 默认继承, placement 可逐株覆盖。
```

- 家庭级默认环境存哪:首选独立小表 `plant_family_settings`(family_id 主键,放 location);不塞进 `InstalledPlugin.config`,因为它是结构化、会演进的数据。实现时二选一,design 记首选。
- 照片走 `storage` 抽象,key 形如 `plant/{family_id}/{plant_id}/{log_id}.jpg`,带 version 便于缓存失效(对齐项目头像/海报约定)。

### D4. AI 编排(在 `plugins/plant/service.py`,植物逻辑留在插件层)

照片数据流(一份图、两个用途):

```
用户上传照片
   │
   ├─(1)持久化──▶ COS 私有桶  storage.put("plant/{fid}/{pid}/{log_id}.jpg")
   │             PlantLog.photo_storage_key + version  ← 历史档, 给前端时间线展示/看趋势
   │             【请求内同步完成, 即使后续 AI 失败, 照片记录也已存住】
   │
   └─(2)喂模型──▶ 读回该 bytes → base64 data URL → 多模态消息
                 【仅后台分析临时使用, 不另存, 用完即弃】
```

新建 PlantLog(用户上传照片)后:
- **请求内**:先把照片经 `storage.put` 持久化到 COS,落 `photo_storage_key + version`,创建记录(`ai_status=pending`),再调度后台任务。照片持久化与 AI 分析解耦——AI 失败不影响历史照片留存。
- **后台任务**(照 movie 范式,独立 DB session,绝不抛异常):
  1. 取该植物的位置 → `weather.get_weather(...)`(失败则降级,记 env_snapshot 中天气为空)。
  2. 从 COS 读回本条照片 bytes → base64;组多模态消息:system(植物养护专家,只输出 JSON)+ user(照片 image 块 + 文本:品种/摆放/天气/近 N 条历史摘要)。
  3. `ai_complete(vision messages)` → 解析 JSON:状态点评、浇水/施肥/修剪建议、**建议浇水/施肥间隔天数**。
  4. 写回 `ai_status=ready` + 各字段;**不自动改用户已设的周期**,把 `ai_suggested_*_days` 作为"建议值"展示,用户一键采纳才落到 `Plant.*_interval_days` 并重算 `next_*_due`。
  5. 任何异常吞进 `ai_status=failed`,绝不崩后台任务。

"根据天气+品种推浇水周期建议"等判断**只在此处**,不进 weather/ai 共享层。

### D5. 浇水/施肥提醒:照搬 subscription 轮询

lifespan 启动 `run_plant_reminder_loop`;每轮 `check_due_plants(today)`:对每株 `next_water_due <= today` 且未就该日期通知过的,发家庭通知"🌿 该给『绿萝』浇水了",置 `last_notified_water_due`,滚动 `next_water_due += water_interval_days`。施肥同理。`check_*` 接受 `today` 参数便于确定性测试。

### D6. 定位:Flutter geolocator,安卓优先

前端用 `geolocator` 取设备经纬度(安卓优先,iOS 兼容),首次进入植物插件或设置默认环境时请求权限;经纬度上送后端存为家庭级默认环境。`AndroidManifest.xml` 加 `ACCESS_FINE/COARSE_LOCATION`,iOS `Info.plist` 加 `NSLocationWhenInUseUsageDescription`。无权限时降级为手填城市(可后续做)。

## Risks / Trade-offs

- **[共享 AI 改动破坏 movie 等纯文本调用方]** → `content` 联合类型,`str` 分支序列化逻辑保持不变;补单测覆盖"传 str 时 payload 与改动前逐字节一致"。
- **[私有 COS 照片模型拉不到]** → 内联 base64 data URL,不传 URL;注意单图体积(上传前压缩,见 Open Questions)。
- **[base64 大图撑爆 token / 超时]** → 前端上传即压缩到合理分辨率;后端对喂给模型的图再设上限;`ai_timeout` 已较宽。
- **[和风免费额度/限流]** → service 层缓存(同位置数十分钟复用)+ 量化 key;失败降级为"无天气、仅看图"。
- **[K2.6 model id / 和风 API host 我记忆可能过时]** → 实现阶段以平台当时文档为准核对(见 Open Questions)。
- **[多家庭并发轮询性能]** → user 背景为低并发,简单全表轮询足够;与 subscription 同量级,不提前优化。

## Migration Plan

1. 共享层先行且独立可验:扩展 `services/ai` 多模态(+单测保证向后兼容)→ 新建 `services/weather`(+单测,key 空时 NotConfigured)。这两步不依赖 plant,可单独 merge。
2. alembic migration 建 `plant` / `plant_log` / `plant_family_settings` 表。
3. plant 插件后端:models → service(编排)→ routes → reminders → manifest + registry 注册 + 首页预览;`app.main` lifespan 挂提醒循环。
4. 前端:数据模型/API client → 列表/详情/拍照记录/周期设置页 → 定位权限 + 平台清单声明。
5. config / `app.env.example` 增加和风 key 等;`CHANGELOG.md` 顶部补一行;`pubspec.yaml` 版本按需递增。
6. 回滚:plant 插件默认 `published` 可设 False 下架;共享层改动向后兼容,无需回滚 movie。

## Open Questions

- **历史趋势喂法**:首版用"近 N 条记录的文本摘要"还是"上一张+本张两图对比"?默认文本摘要(省 token),按效果再加图。
- **精确 K2.6 model id 与和风 API host/鉴权**(JWT vs APIKey、专属 host):实现时以平台最新文档核对。
  - ✅ 已核实(部署验证):和风新版控制台账号用**专属 API Host** + key 作为 query 参数;
    共享 `devapi.qweather.com` 会 403 "Invalid Host"。`QWEATHER_BASE_URL` 必须形如
    `https://<专属host>.qweatherapi.com/v7`(漏 `/v7` 会 404)。已在 `config.py` /
    `app.env.example` 注明。
- **家庭默认环境存储**:独立表 vs `InstalledPlugin.config`——倾向独立表,落地时确认。
- **照片压缩参数**(分辨率/质量上限):前端上传与后端送模型各设一档,具体值实现时定。
- **修剪类建议是否也做提醒**:首版只做浇水/施肥到期提醒,修剪仅作为 AI 文字建议(可后续扩展)。
