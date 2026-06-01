## ADDED Requirements

### Requirement: 按位置返回实时天气

共享天气模块 SHALL 提供一个入口,给定地理位置(经纬度)返回该位置此刻的天气快照。天气快照 MUST 包含温度、湿度、紫外线/光照指数、降水情况与天况描述。该模块 MUST NOT 包含任何业务/插件特定逻辑(如植物养护推断)。

#### Scenario: 获取某位置天气

- **WHEN** 调用方传入有效经纬度调用天气入口
- **THEN** 系统 SHALL 返回含温度、湿度、UV/光照、降水、天况的天气快照

#### Scenario: 仅供应数据

- **WHEN** 任意插件依赖天气模块
- **THEN** 天气模块 SHALL 只返回天气数据,且 MUST NOT 反向依赖任何具体插件

### Requirement: 缓存与限流

天气模块 SHALL 在服务层缓存查询结果:同一(量化后的)位置在可配置的 TTL 内 MUST 复用已缓存的天气快照,而非每次都调用外部 API。TTL MUST 可通过配置项设定。

#### Scenario: TTL 内复用缓存

- **WHEN** 在 TTL 内对同一位置发起第二次天气查询
- **THEN** 系统 SHALL 返回缓存结果,且 MUST NOT 再次调用外部天气 API

### Requirement: Provider 可配置与降级

天气服务商 MUST 可通过配置项切换,调用方代码不变。未配置凭据时,系统 SHALL 抛出"未配置"语义的错误;外部 API 调用失败时,系统 SHALL 以明确的错误或空结果返回,使调用方能够降级处理而非崩溃。

#### Scenario: 未配置凭据

- **WHEN** 天气 provider 的凭据为空且收到查询
- **THEN** 系统 SHALL 抛出"未配置"语义错误,调用方据此按"天气不可用"降级

#### Scenario: 外部 API 失败

- **WHEN** 外部天气 API 返回错误或超时
- **THEN** 系统 SHALL 返回可识别的失败信号,且 MUST NOT 让调用方进程崩溃
