## Why

家里养的植物缺乏一个统一的养护记录与判断工具:什么时候浇水、施肥、修剪全凭记忆,植物状态变差时也看不出趋势。本插件让用户给每株植物建档、定期拍照记录,由多模态 AI **看图**结合**实时天气环境**分析植物状态,给出养护建议,并把浇水/施肥变成可到期提醒的日程。

同时,"看图分析"和"获取天气"是通用能力——别的插件(日历、纪念日、首页卡片等)未来也会用到。因此这两块以**共享服务**的形态沉淀到 `app/services/`,植物插件只是第一个消费者。

## What Changes

- **扩展共享 AI 模块支持多模态**:`app/services/ai` 的 `AiMessage.content` 从 `str` 扩展为 `str | list[ContentPart]`(支持 text + image 块),`build_payload` 将 image 块转为 OpenAI 兼容的 `image_url`。现有纯文本调用方(movie 等)**保持向后兼容**。`config.kimi_model` 从 `kimi-k2.5` 升级到 K2.6 多模态档。
- **新增共享天气模块**:新建 `app/services/weather`,镜像 `app/services/ai` 的结构(Provider Protocol + Result + NotConfigured 错误 + service 入口 + 具体实现)。服务商为**和风天气 QWeather**,带 service 层缓存(同位置数十分钟复用)与限流。该模块只做"给定位置 → 返回此刻天气数据",不含任何植物逻辑。
- **新增植物日记插件 `plant`**:`Plant`(每株植物建档)+ `PlantLog`(每条状态记录)数据模型;拍照记录、AI 看图分析、浇水/施肥周期管理等路由;编排 weather + ai 的 service;浇水/施肥到期提醒(照搬 subscription 的轮询+滚动模式)。家庭级默认环境存一次定位,每株植物继承,可覆盖"摆放(室内/阳台/窗向)"。浇水/施肥周期**由用户设定,AI 给建议值**。

## Capabilities

### New Capabilities
- `ai-multimodal`: 共享 AI 模块支持图片输入(多模态消息),向后兼容纯文本调用,任何插件可 `ai_complete([文本+图片])`。
- `weather-service`: 共享天气服务模块,按位置返回实时天气数据(温度/湿度/UV/降水/天况),带缓存与限流,Provider 可配置。
- `plant-journal`: 植物日记插件——建档、拍照记录、AI 看图+天气分析养护状态、浇水/施肥周期与到期提醒。

### Modified Capabilities
<!-- 无既有 spec(openspec/specs/ 为空);AI 多模态以新 capability 形式描述。 -->

## Impact

- **共享层(其他插件受益)**
  - `app/services/ai/types.py`、`kimi.py`、`service.py`:多模态扩展(向后兼容)。
  - `app/services/weather/`:全新模块。
  - `app/core/config.py`:`kimi_model` 升级;新增 `weather_provider` / `qweather_api_key` / 天气缓存 TTL 等配置。
  - `backend/deploy/env/app.env.example`:补充和风天气 key 等新环境变量。
- **植物插件本体**
  - `app/plugins/plant/`:`manifest.py + models.py + routes.py + service.py + reminders.py + __init__.py`,并在 `registry.register` 注册、接入首页卡片预览。
  - alembic migration:新增 `plant` / `plant_log` 表及家庭级默认环境存储。
  - `app/main.py`:lifespan 中启动浇水/施肥提醒轮询循环(照 subscription 模式)。
- **前端 Flutter**
  - `lib/features/plugins/plant/`:植物列表 / 详情(养护时间线)/ 拍照记录 / 周期设置页。
  - 定位:引入 `geolocator`(安卓优先,iOS 兼容),`AndroidManifest.xml` / iOS `Info.plist` 增加定位权限声明。
  - `lib/data/` 模型与 API client 增加 plant 相关类型。
- **依赖**:后端新增和风天气需要的 HTTP 调用(复用 httpx);前端新增 `geolocator`。需在和风开放平台 [dev.qweather.com](https://dev.qweather.com) 注册取 API key。
- **文档**:`CHANGELOG.md` 顶部补一行;`backend/deploy/RELEASE.md` 如涉及新 env 则同步。
