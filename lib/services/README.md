# 可选外部服务与本地事实源的边界

这些客户端独立于本地 SQLite、账户、启动及插件状态，不在构造时创建请求或写文件。调用者注入原始 `http.Client`、本地配置读取函数和授权定位函数；不要注入带全局认证/自动重定向的 HTTP 包装器。调用者负责将需要保留的查询结果、片单状态、旅行原照与生成结果写本地，服务客户端不接受本地家庭/设备身份作为远端授权替代。

这是 2026-11-20 重建阶段的独立模块，**尚未接入手机 UI**，不代表相应真机功能已完成。所有测试使用合成数据和 MockClient，未调用真实服务。

## 仓库接口审计

| 能力 | 仓库现有实现 | 此模块允许的调用 |
| --- | --- | --- |
| 电影片库 | `backend/app/plugins/movie/routes.py` 的 GET `/api/v1/families/{family}/plugins/movie/discover`、`/discover/genres`、`/discover/poster`。需后端会话和家庭成员身份 | 仅这三个查询 GET。远端 endpoint、remoteFamilyId 和 bearer token 必须显式配置，与新本地家庭分离。后端 `already_added` 来自旧云片单，必须丢弃并由本地 TMDB ID 集合重新计算 |
| 添加/补充电影 | POST `/movies/from_tmdb`、`/movies/{id}/enrich` 会写云端 Movie、安排后台补充 | 不提供这些方法，不发送本地片单、备注或看过状态。现有后端没有纯单电影详情查询端点；从 discover 选中条目时本地保存已返回的元数据。需要额外详情时不能悄悄借用会写库的 POST |
| 天气 | `backend/app/plugins/plant/routes.py` 旧 GET `/weather` 读取云端 `PlantFamilySettings` 坐标，PUT `/settings` 持久化坐标；`backend/app/services/weather/qweather.py` 使用 QWeather `/weather/now` 和可选 `/indices/1d?type=5` | 同一 QWeather 供应商，显式选择当前 v1 或兼容 v7，不自动 fallback。v1 使用纬度在先的两位小数 path；v7 使用经度在先的 location 与公制 unit。凭据放 header。每次仅一个天气 GET，不写旧云设置或额外上传位置 |
| 旅行风格图 | `backend/app/services/ai/image_client.py` 为已配置模型的 `/images/generations` 协议；旧 `travel/routes.py` 会上传/写库，`travel/service.py` 生成成功后还删除原照 | 直接调用本机显式配置的模型。只执行生成，不调用云旅行 CRUD/文件上传/后台任务接口，不删除原照。原照、记录、生成结果由调用者本地保存 |
| 植物分析 | 旧日志上传会排云端 AI 任务 | 本模块没有植物分析客户端，不扩大该远程用法 |

未验证当前真实供应商的商用配置或准确率。天气 adapter 已核对官方 v1/显式 v7 文档（见下文），不能把地理定位本身当成天气来源；真实端点/凭据/协议适配仍需要明确配置，缺配置仅此服务返回 `notConfigured`。

## 调用契约

`MovieCatalogueClient`：

- `genres()` → `[{id, name}]`。
- `discover(genreIds, sort, page, locallyAddedTmdbIds)` → `[{tmdb_id,title,overview,release_date,tmdb_rating,poster_url,already_added}]`。本地集合不会回传后端，服务返回的片单状态不能覆盖本地数据。
- `poster('/name.jpg')` → `GeneratedImage`。只接受已有代理的文件路径，拒绝 URL、目录穿越及其它返回海报域名，不自动加载结果中的任意地址。

`WeatherClient.current()`：

- `loadConfig()` 先于定位 callback；未配置不弹定位请求。`locateWithPermission()` 必须由设备权限流程提供，拒绝/未授权返回 null，不能回落到旧云坐标。
- 结果兼容已有 `PlantWeather` 字段：`available,temp_c,feels_like_c,condition,humidity_pct,precip_mm,wind_*,pressure_hpa,visibility_km,cloud_pct,dew_point_c,uv_index,observed_at,latitude,longitude`。v1 自带实时 UV，保留数值 0；显式 v7 没有该字段，返回 null，空/无效主体不伪报可用。
- `WeatherServiceConfig` 必须显式传 `protocol: WeatherProtocol.currentV1`（优先）或 `cityBasedV7`（兼容），baseUrl 仅为 API host origin；`apiKey` 与 `bearerToken` 二选一，仅请求 header 使用。凭据从本机安全存储读取，不加入 URL、结果或普通设置。v1 失败不会换 v7 重新发送位置。
- v1 `/weather/v1/current/{lat2}/{lon2}`：消费字段逐项核对单位，湿度/云量比例转百分比、m/s 转 km/h、m 转 km；缺省可选字段保留 null，未知单位、非有限/越界数值拒绝。v7 `/v7/weather/now?location=lon2,lat2&unit=m` 保持其已声明公制单位，单 GET，不额外请求日指数冒称实时 UV。
- 规范来源：[Current Weather v1](https://dev.qweather.com/en/docs/api/weather/weather-current/)、[官方认证](https://dev.qweather.com/en/docs/configuration/authentication/)、[单位](https://dev.qweather.com/en/docs/resource/unit/)、[v7 兼容接口](https://dev.qweather.com/en/docs/api/weather/weather-now-webapi-v7/)。官方已提示 v7 将被弃用；本模块没有推测具体停用日期。返回保留 `provider/protocol/attributions`，接入层应展示数据来源，不自动抓取 attribution URL。

`ConfiguredImageClient.generate(image, prompt, consent)`：

- `loadConfig()` 返回当前启用的 app 图片模型：baseUrl、model、私有 key、已向用户展示的供应商输入留存说明，以及可选结果下载 origin 白名单。
- `PreparedModelImage` 是仅供模型的图片副本，调用者先用设备编码器重新编码、明确移除元数据；不会改动本地原照。本边界支持 PNG/JPEG/WebP，并拒绝已列明 JPEG APP1/APP13/COM、PNG EXIF/文本、WebP EXIF/XMP；不支持的格式拒绝。这个字节扫描不等于全格式解码，也不保证识别所有私有/隐写数据，不能声称所有文件的 metadata 已清除。图像解码/实际渲染校验仍由手机控制器负责。
- 每次必须传 `ImageGenerationConsent`，同意项绑定当前配置 endpoint 与留存说明，且必须明确允许源图提交、已查看供应商政策。更换 endpoint/说明时旧同意失效。不能在启动、保存旅行记录或加载列表时自动提交。
- JSON 与仓库现有图片模型契约一致：`model,prompt,image(data URI),size,response_format=b64_json,watermark=false`。不发送 family/device/旅行记录，也不调用 `/files` 等输入持久化接口。请求 `Cache-Control: no-store` 仅是缓存提示，**不能保证供应商不记录/不保留输入**；不发送并不能保证有效的未知 `store=false` 参数。UI 必须展示所选服务的真实政策，不能把客户端无写库方法冒充供应商零留存。
- 返回图像字节与由 magic 检测的 MIME，调用者保存到本地并保持原照。返回下载 URL 仅允许配置 endpoint origin 或明确 allowlist，下载请求不含模型 key，也不跟随重定向。

## 失败和重试

`ExternalServiceException.failure` 区分未配置、定位拒绝、输入无效、缺同意、网络、HTTP 与响应错误。对外文本不含请求 URL、key、位置、提示词或响应正文。模型发送后发生超时/错误会设置 `requestMayHaveBeenSent=true`；没有自动重发，避免不知情地重复提交私有照片/产生费用。超时不能推断供应商未处理。

限制：JSON/图像响应有字节上限，响应流总时限会取消等待，认证请求不跟随 3xx。配置、网络或服务失败必须由接入层转成该服务的可重试状态，不能清空本地记录或阻塞 bootstrap。供应商查询结果的本地保存策略由本地数据层负责。
