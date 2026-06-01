## 1. 共享层:AI 多模态扩展(独立可 merge)

- [x] 1.1 在 `app/services/ai/types.py` 将 `AiMessage.content` 扩展为 `str | list[ContentPart]`,定义 text/image 内容块类型
- [x] 1.2 更新 `to_dict()`:`str` 分支保持原样输出,`list` 分支转 OpenAI 兼容 `[{type:text}, {type:image_url,...}]`
- [x] 1.3 在 `app/services/ai/kimi.py` 的 `build_payload` 支持多模态消息;新增便捷入口(`ai_complete_vision` 或 `AiMessage.with_image`)
- [x] 1.4 `app/core/config.py` 将 `kimi_model` 升级到 K2.6 多模态档(以平台当时文档核对精确 id)
- [x] 1.5 单测:纯文本 `content` 序列化结果与改动前逐字节一致(向后兼容回归)
- [x] 1.6 单测:文本+图片消息正确转为 `image_url` 块;未配置 key 抛 `AiNotConfiguredError`

## 2. 共享层:天气服务模块(独立可 merge)

- [x] 2.1 新建 `app/services/weather/types.py`:`WeatherProvider`(Protocol)、`WeatherSnapshot`、`WeatherError` / `WeatherNotConfiguredError`
- [x] 2.2 新建 `app/services/weather/qweather.py`:`QWeatherClient.from_settings` + `configured` 守卫 + httpx 调用(核对和风 API host/鉴权)
- [x] 2.3 新建 `app/services/weather/service.py`:`get_weather(lat, lon)` 入口 + provider 选择
- [x] 2.4 在 service 层加缓存(量化经纬度 key + 可配 TTL)与失败降级
- [x] 2.5 `app/core/config.py` 新增 `weather_provider` / `qweather_api_key` / 天气缓存 TTL;`backend/deploy/env/app.env.example` 同步补充
- [x] 2.6 单测:同位置 TTL 内复用缓存不重复调用;未配置抛 NotConfigured;API 失败返回可识别信号

## 3. 植物插件:数据模型与 migration

- [x] 3.1 新建 `app/plugins/plant/models.py`:`Plant`(family_id/name/species/cover/placement/water_interval_days/fert_interval_days/next_water_due/next_fert_due/last_notified_*)
- [x] 3.2 `PlantLog`(plant_id/created_at/photo/env_snapshot/ai_status/ai_assessment/ai_advice/ai_suggested_*_days/note)
- [x] 3.3 家庭级默认环境存储(首选独立表 `plant_family_settings`,family_id 主键,存 location)
- [x] 3.4 编写 alembic migration 建上述表

## 4. 植物插件:service 编排(植物逻辑留在此层)

- [x] 4.1 `app/plugins/plant/service.py`:植物/记录的增删查、周期设置、采纳 AI 建议(重算 next_*_due)
- [x] 4.2 新增记录:请求内先 `storage.put` 持久化照片到 COS(落 `photo_storage_key+version`)、创建记录(`ai_status=pending`),再调度后台任务——照片留存与 AI 解耦
- [x] 4.3 后台分析任务(照 movie 范式:独立 DB session、`ai_status`、绝不抛异常)
- [x] 4.4 编排:取位置→`weather.get_weather`(失败降级)→从 COS 读回照片 bytes 转 base64→组多模态消息(品种/摆放/天气/历史摘要)→`ai_complete`
- [x] 4.5 解析 AI 返回 JSON(状态点评/浇水/施肥/修剪建议/建议间隔),写回记录;不自动改用户周期

## 5. 植物插件:路由、提醒、注册

- [x] 5.1 `app/plugins/plant/routes.py`:建植物 / 列表 / 详情 / 新增记录(上传照片)/ 取分析 / 设周期 / 采纳建议 / 设默认环境
- [x] 5.2 照片读写走 `storage` 抽象,key `plant/{family_id}/{plant_id}/{log_id}.jpg` 带 version
- [x] 5.3 `app/plugins/plant/reminders.py`:`check_due_plants(today)` + `run_plant_reminder_loop`(照搬 subscription:幂等通知 + 周期滚动)
- [x] 5.4 `app.main` lifespan 启动提醒轮询循环
- [x] 5.5 `manifest.py` + `__init__.py` 调 `registry.register`;首页卡片 preview 钩子
- [x] 5.6 后端测试:路由 CRUD、提醒到期幂等与滚动、分析失败降级

## 6. 前端 Flutter

- [x] 6.1 `lib/data/` 增加 Plant / PlantLog 模型与 API client 方法
- [x] 6.2 `lib/features/plugins/plant/`:植物列表页
- [x] 6.3 植物详情页(养护时间线:照片+AI状态点评+建议)
- [x] 6.4 拍照/选图记录页(上传前压缩到合理分辨率)
- [x] 6.5 周期设置页(用户设浇水/施肥周期 + 一键采纳 AI 建议值)
- [x] 6.6 默认环境/摆放设置;接入 `geolocator` 取定位
- [x] 6.7 权限声明:`AndroidManifest.xml` 定位权限;iOS `Info.plist` `NSLocationWhenInUseUsageDescription`

## 7. 收尾

- [x] 7.1 `CHANGELOG.md` 顶部条目补一行(植物日记插件);按需递增 `pubspec.yaml` version
- [x] 7.2 端到端自测:建植物→拍照记录→AI 分析出建议→设周期→到期提醒
- [x] 7.3 `backend/deploy/RELEASE.md` 如涉及新 env 同步说明
