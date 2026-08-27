## ADDED Requirements

### Requirement: 家庭拥有独立宠物身份
系统 SHALL 使用独立 Pet 资源表示家庭中的宠物；Pet MUST 归属且隔离于一个 family，并且 MUST NOT 依赖 User 或 Membership 才能存在。Pet 档案 SHALL 至少支持名称、emoji、照片、物种、品种、性别、生日/估算标记、到家日、绝育状态和备注，其中仅名称为必填。

#### Scenario: 管理员添加宠物
- **WHEN** Owner 或 Admin 在家庭管理中填写宠物名称并保存
- **THEN** 系统 SHALL 为当前 family 创建 Pet，且不创建 User、Membership 或邀请

#### Scenario: 跨家庭访问宠物
- **WHEN** 某家庭成员使用另一 family 的 Pet id 请求详情或照片
- **THEN** 系统 SHALL 返回 404，且 MUST NOT 泄漏该 Pet 是否存在

### Requirement: 家庭管理按类别展示家人与宠物
家庭管理 SHALL 将人类 Membership 和 Pet 分成“家人”“宠物”两个类别展示；`member_count` MUST 只统计 active 人类 Membership，系统 SHALL 单独返回 `pet_count`。Pet 行 SHALL 展示照片或 emoji 回退、名称以及可用的品种/年龄摘要。

#### Scenario: 查看含多类成员的家庭
- **WHEN** 一个 family 有 2 个 active Membership 和 1 个 active Pet
- **THEN** 家庭管理 SHALL 显示 2 位家人与 1 只宠物，`member_count` 为 2 且 `pet_count` 为 1

#### Scenario: 从家庭管理进入宠物资料
- **WHEN** 用户点击宠物类别中的某只宠物
- **THEN** 系统 SHALL 打开该 Pet 的资料或宠物日常入口，而不是成员角色编辑页

### Requirement: 宠物与人类权限边界明确
Pet MUST NOT 登录、接受邀请、持有家庭角色、成为 Owner/Admin、接收通知或出现在仅接受 User 的成员指派器中。只有 Owner/Admin SHALL 能创建、修改或归档 Pet；所有 active 人类成员 SHALL 能查看 Pet。

#### Scenario: 创建人类邀请
- **WHEN** Owner 或 Admin 创建家庭邀请
- **THEN** 可选角色 SHALL 仅包含 admin、member、child，且 MUST NOT 包含 pet

#### Scenario: 普通成员编辑宠物身份
- **WHEN** 非 Owner/Admin 的成员尝试修改或归档 Pet
- **THEN** 系统 SHALL 返回 403，且 Pet 数据保持不变

### Requirement: 宠物照片私有存储并版本化
系统 SHALL 将 Pet 照片存入家庭隔离的私有存储，照片读取 URL MUST 携带随替换递增的版本号；未上传、已删除或读取失败时，客户端 SHALL 回退展示 Pet emoji。

#### Scenario: 替换宠物照片
- **WHEN** Owner 或 Admin 为 Pet 上传一张新照片
- **THEN** 系统 SHALL 私有保存新照片、递增 photo version，并返回带新版本号的照片 URL

#### Scenario: 宠物没有照片
- **WHEN** Pet 未设置照片或照片加载失败
- **THEN** 客户端 SHALL 展示 Pet emoji，且页面仍可正常使用

### Requirement: 归档宠物保留历史引用
移除宠物的默认操作 SHALL 为归档而非物理删除。归档 Pet MUST 从默认家庭宠物列表、宠物日常列表和提醒扫描中隐藏，但关联记录 MUST 保留，且已有历史读取 MUST NOT 因 Pet 归档产生悬空引用。

#### Scenario: 归档已有健康记录的宠物
- **WHEN** Owner 或 Admin 归档一只有健康记录的 Pet
- **THEN** Pet SHALL 不再出现在 active 列表或产生提醒，且其既有记录仍保存在数据库中

### Requirement: 迁移旧宠物成员
系统 MUST 将既有 `role=pet` Membership 迁移为独立 Pet，至少保留 family、显示名称和 emoji，并移除其作为家庭登录成员的关系；对应 User 账号 MUST NOT 被删除。迁移后所有新邀请和角色修改 MUST 拒绝 `pet`。

#### Scenario: 迁移宠物占位成员
- **WHEN** migration 遇到一条 `role=pet` Membership
- **THEN** 系统 SHALL 创建对应 family 的 Pet、移除该 Membership，并在需要时修复原 User 的 `current_family_id`

#### Scenario: 迁移后提交 pet 角色
- **WHEN** 客户端向邀请或角色修改接口提交 `role=pet`
- **THEN** 系统 SHALL 返回校验错误，并列出仅包含人类角色的允许值

### Requirement: Pet 身份不依赖插件安装
核心 Pet SHALL 在“宠物日常”未安装或被卸载时继续属于 family，并可在家庭管理中查看；插件安装状态 MUST NOT 级联删除或归档 Pet。

#### Scenario: 卸载宠物日常
- **WHEN** family 卸载“宠物日常”插件
- **THEN** 家庭管理中的 active Pet SHALL 保持存在且身份资料不变
