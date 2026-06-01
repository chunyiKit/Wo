## ADDED Requirements

### Requirement: 多模态消息内容

共享 AI 模块的消息 `AiMessage` SHALL 支持图片输入:`content` 字段 MUST 接受 `str`(纯文本)或内容块列表(文本块 + 图片块)。图片块 MUST 能携带以 base64 `data:` URL 形式内联的图片数据。

#### Scenario: 文本+图片消息

- **WHEN** 调用方构造一条同时含文本和一张图片的用户消息并调用 `ai_complete`
- **THEN** 系统 SHALL 将其序列化为 provider 的 OpenAI 兼容多模态格式(文本块 + `image_url` 块),并返回模型对图片的分析结果

#### Scenario: 仅图片或多图

- **WHEN** 消息内容块列表包含一张或多张图片块
- **THEN** 系统 SHALL 按顺序将每个图片块转为对应的 `image_url` 块发送给模型

### Requirement: 纯文本调用向后兼容

对 `content` 为 `str` 的既有调用方(如 movie 插件),多模态扩展 MUST NOT 改变其请求体与行为。`str` 内容的序列化结果 SHALL 与扩展前逐字节一致。

#### Scenario: 既有纯文本调用不受影响

- **WHEN** 调用方以纯字符串 `content` 调用 `ai_complete` / `ai_complete_text`
- **THEN** 系统 SHALL 生成与多模态扩展前相同的请求体,模型行为不变

### Requirement: 多模态模型配置

系统 SHALL 使用支持视觉的模型档处理含图片的请求,模型标识 MUST 可通过配置项设定。未配置 API key 时,系统 SHALL 抛出"未配置"语义的错误,而非静默失败或重试。

#### Scenario: 未配置凭据

- **WHEN** AI provider 的 API key 为空且收到任意请求
- **THEN** 系统 SHALL 抛出 `AiNotConfiguredError`,调用方据此按"功能不可用"处理
