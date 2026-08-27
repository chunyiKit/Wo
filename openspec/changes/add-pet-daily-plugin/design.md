## Context

项目目前已预留 `pet` 插件 id、颜色 token 和首页视觉方向，但没有宠物业务实现。核心 Membership 的 `Role` 仍包含 `pet`，邀请和成员角色编辑也允许选择宠物；实际 Membership 必须关联一个可登录 User，因此现状无法正确表达“宠物是家庭成员，但不是用户”。

“宠物日常”同时影响家庭核心域、插件平台、私有文件存储、通知、首页预览和 Flutter 家庭管理，且包含旧 `role=pet` 数据迁移。项目已有可复用模式：family-scope 权限校验、成员真实头像 helper、私有 blob storage、插件 manifest/preview、subscription/plant 的幂等提醒循环，以及列表静默刷新约定。

## Goals / Non-Goals

**Goals:**

- 以独立 Pet 表达宠物身份，使其能出现在家庭管理中，但不进入用户、Membership、邀请和权限体系。
- 形成“计划 → 到期 → 家人完成 → 健康记录 → 下一次”的照护闭环。
- 让记录类型、记录名称和周期都可由家庭自定义，同时保留体重等需要结构化计算的数据能力。
- 支持多宠物、附件、家庭协作、真实操作者头像、首页预览和到期通知。
- 迁移既有 `role=pet` 数据，并保证 family 数据隔离、通知幂等和并发完成安全。

**Non-Goals:**

- 不提供 AI 诊断、症状判断、药物推荐或自动生成医疗周期。
- 不做社区、商城、医院预约、GPS/硬件、保险、完整费用账本或完整宠物相册。
- 不与家务、记账、回忆插件在首版做双向同步；这些插件未来只通过 `pet_id` 关联。
- 首版照护计划按“日期”到期，不支持一天多次的时刻表、复杂 cron 或按星期组合规则。
- 不把宠物数据塞入 `InstalledPlugin.config`，也不因卸载插件删除 Pet 或健康历史。

## Decisions

### D1. Pet 属于家庭核心域，照护数据属于插件域

新增核心表 `pets`，保存 `id`、`family_id`、名称、emoji、照片元数据、物种、品种、性别、生日/是否估算、到家日、绝育状态、备注、创建人和归档时间。核心 API 使用 `/families/{family_id}/pets`；家庭管理直接消费该资源。

插件表只保存 `pet_id` 的照护类型、计划、记录和附件。这样插件卸载后宠物身份仍存在，未来其他插件也可引用同一个 `pet_id`，同时健康业务不会污染 Family/Membership。

备选方案是继续用 Membership 或把 Pet 完全放在插件表中。前者会制造虚假 User、权限和通知语义；后者会让家庭管理依赖插件安装状态，并阻碍跨插件引用，均不采用。

### D2. 家庭管理只在展示层把宠物视为成员类别

家庭管理展示“家人”和“宠物”两个分组，家庭摘要分别返回 `member_count`（仅人类）和 `pet_count`。Owner/Admin 可添加、编辑、归档 Pet；任意 active 人类成员可查看。Pet 不可登录、不可受邀、不可成为 owner/admin/member/child、不可接收通知，也不进入成员指派选择器，除非某个插件未来显式支持 `pet_id`。

`Role`、`ALL_ROLES`、`INVITABLE_ROLES` 和所有前端角色列表移除 `pet`。接口不再接受 `role=pet`，避免新的混合数据继续产生。

### D3. 宠物照片独立存储并版本化

Pet 照片使用核心资源端点上传、读取和删除，存储 key 使用 `pets/{family_id}/{pet_id}/avatar.<ext>`；Pet 保存 `photo_storage_key`、`photo_content_type` 和递增的 `photo_version`。读取 URL 带 `?v=N`，前端可长期缓存，未上传或读取失败时回退 Pet 的 emoji。

Pet 照片不是“成员真实头像”，不复用 User avatar 端点；记录中的人类操作者仍使用共享 `MemberAvatar` 和成员头像 URL。

### D4. 自定义记录类型使用家庭级实体和稳定数据能力

新增 `pet_record_types`：`id`、`family_id`、自定义 `name`、emoji、`data_kind`、排序和归档状态。`data_kind` 首版仅有 `general` 与 `weight`：名称/emoji 可修改，但已被记录引用后 `data_kind` 不可改变。这样用户可把“体重”改为“晚饭前体重”，最近体重和曲线仍能可靠计算。

首次进入插件时幂等创建默认建议类型：喂食、遛狗、铲砂、喂药、驱虫、疫苗、体检、体重、洗护、其他。默认项与自定义项没有权限或行为差异，均可改名、排序和停用；停用只影响新建选择，不修改历史。

备选方案是直接在记录里存自由文本。它实现简单，但无法稳定筛选、停用、排序或识别体重数据，因此采用“类型实体 + 历史快照”。

### D5. 计划与已发生记录分表，完成计划原子地产生记录

使用三个插件核心资源：

```text
PetRecordType
   ├── PetCarePlan   将要做什么、什么时候做
   └── PetRecord     已经发生什么
          └── PetRecordAttachment
```

`pet_care_plans` 保存 `family_id`、`pet_id`、`record_type_id`、自定义名称、备注、`recurrence_unit`、`recurrence_interval`、`next_due_date`、启用状态、最近通知日期和创建人。周期值为 `none/day/week/month/year`；`none` 可保留一个明确的 `next_due_date` 作为单次待办。

`pet_records` 保存发生日期、类型引用、类型名称/emoji/data_kind 快照、自定义记录名称、备注、可选下一次日期、创建者、关联计划、对应的计划到期日，以及体重类的标准化 kg 数值。历史读取使用快照，所以类型改名或停用不会重写既有记录。

完成计划通过 `POST .../plans/{plan_id}/completions`：同一事务内创建 PetRecord、写完成者、更新计划下一次日期。`(plan_id, scheduled_due_date)` 建唯一约束，两个成员同时点击时只有一次成功；重复请求返回已存在的完成结果，而不生成重复时间线。

### D6. 周期从实际完成日期滚动，允许显式覆盖

日/周使用日期加法，月/年使用 calendar-aware 加法并将不存在的日裁到目标月最后一天，例如 1 月 31 日每月一次得到 2 月最后一天。完成逾期任务时默认从实际完成日期计算下一次，避免补发多个已经错过的周期；用户传入 `next_due_date_override` 时以覆盖值为准。

手工新增记录可选填“下次日期”，并可选择创建或更新照护计划。系统不根据疫苗、驱虫或药物名称自动推断周期，默认模板也不会自动创建计划。

### D7. 聚合读取围绕四个页面设计

- 核心 `/families/{fid}/pets` 提供家庭管理所需的 Pet 身份列表。
- 插件 `GET /families/{fid}/plugins/pet/pets` 返回宠物列表摘要：Pet 身份、最近体重、最早 active 待办；逾期优先，其次按日期升序。
- 插件 `GET .../pet/pets/{pet_id}` 返回宠物主页聚合：今日照护（到期日小于等于今天）、最近体重、未来待办和首屏健康时间线。
- `GET .../pet/pets/{pet_id}/records` 使用 keyset pagination 返回完整健康时间线。
- record-types、plans、records 和 attachments 使用独立资源路由；所有插件路由先校验人类 Membership，再校验 Pet 与 URL family 一致。

组合 read model 在服务端注入记录创建者/计划完成者的名称、emoji 和真实头像 URL，避免前端额外逐条请求。

### D8. 附件使用独立行和私有 blob storage

每条记录可上传多份附件，首版接受项目支持范围内的图片和 PDF。`pet_record_attachments` 保存 family/record 隔离键、原始文件名、content type、size、storage key、排序和上传者。上传先校验大小/MIME，再写 storage 和数据库；数据库失败时补偿删除 blob。删除记录或附件时数据库提交后 best-effort 清理 blob，并记录失败供后续清扫。

读取复用现有 presigned/raw-response 策略，不把附件 URL 当作永久公开地址。

### D9. 通知和首页预览都以“最紧急待办”为唯一来源

后台提醒循环扫描 `next_due_date <= today` 且尚未为该日期通知的 active 计划，向家庭中的人类成员发送通知。计划保存 `last_notified_due_date`，通知与该标记在同一事务提交；轮询重启不会重复发送同一到期日。

首页 preview 在全家宠物中选择同一套排序下最紧急的计划，展示宠物名、事项名和“今天/已逾期 N 天/N 天后”；无待办时展示宠物数量和最近一条体重，无宠物时提示添加宠物。首页只显示摘要，不在 preview 内修改计划状态。

### D10. 权限分为核心身份管理与日常协作

- Owner/Admin：创建、修改、归档 Pet；管理记录类型；可修改/删除任意插件记录和计划。
- 所有 active 人类成员（含 child）：查看宠物，创建记录与计划，完成计划，修改/删除自己创建的记录或计划。
- 非创建者的普通成员不可删除他人的健康记录，但可以完成家庭共享计划。
- 所有 family-scope 查询必须同时限定 `family_id`；跨家庭 Pet id 返回 404，避免泄漏资源存在性。

### D11. 列表前端采用缓存 + 静默刷新

宠物列表、今日照护、计划列表和健康时间线首屏可显示 spinner；首次成功后缓存现有项目。增删改、完成计划、附件上传及轮询刷新只静默替换对应缓存，不把整页重新切回 spinner。失败时保留旧数据并给出局部错误提示。

### D12. 卸载只移除安装关系，不删除身份与历史

卸载“宠物日常”只删除/禁用 InstalledPlugin，保留核心 Pet、record types、plans、records 和 attachments；重新安装后恢复原数据。显式归档 Pet 后，它从默认列表和提醒扫描中消失，但历史记录保留。首版不提供永久物理删除宠物及其全部健康档案的 UI。

## Risks / Trade-offs

- **[旧 `role=pet` 实际关联了可登录 User]** → 上线前统计并备份所有目标 Membership；迁移明确移除其家庭访问权、修复 `current_family_id`，保留 User 账号本身，并生成迁移映射日志供核查。
- **[迁移旧 User 头像到 Pet 照片失败]** → 先创建 Pet 并保留 emoji；对象复制 best-effort，失败记日志且不阻塞迁移，用户可重新上传。
- **[自定义类型导致历史语义漂移]** → 记录保存类型快照；已使用类型不可改变 `data_kind`，只能改显示名称/emoji或停用。
- **[多人同时完成造成重复喂药/重复记录]** → 数据库唯一约束 + 原子事务；重复提交返回同一完成结果。
- **[月/年周期日期漂移]** → 使用 calendar-aware 运算并覆盖月底、闰年测试；每次完成都允许用户覆盖下一日期。
- **[提醒轮询量随家庭增长]** → 为 active、next_due_date 建组合索引，只扫描已到期计划；沿用单进程提醒模式，后续多 worker 再增加数据库锁。
- **[附件残留或数据库/存储不一致]** → 上传失败补偿删除、删除失败记录日志并提供后续清扫入口；附件始终私有。
- **[核心 Pet 与插件聚合读取产生 N+1]** → 宠物列表和主页使用批量查询分别加载最近体重和最早计划，不逐宠物调用子查询接口。

## Migration Plan

1. 新增 `pets` 和宠物日常插件相关表、索引及唯一约束；上线前备份数据库并输出所有 `role=pet` Membership 与未使用宠物邀请清单。
2. 数据迁移为每条 `role=pet` Membership 创建独立 Pet，复制 family、display_name、emoji 和可用资料；best-effort 复制 User 头像到 Pet 存储 key。
3. 删除/失效尚未接受的 `role=pet` 邀请；移除已迁移的宠物 Membership。若对应 User 的 `current_family_id` 指向该家庭，切换到其最早的其他 active 家庭或置空；User 账号不删除。
4. 部署只接受人类角色的新后端代码和核心 Pet API，验证 member_count 不含宠物、pet_count 正确、跨家庭访问被拒绝。
5. 部署“宠物日常”插件后端、提醒循环和前端四个页面；插件默认发布并注册通知类型、首页 preview 与 deeplink。
6. 验证迁移宠物、照片回退、记录/计划完成幂等、提醒不重复、卸载重装数据仍在，再开放安装。
7. 回滚时先下架插件并停止提醒循环；应用代码可回滚，但 `role=pet` Membership 的恢复必须使用上线前备份/迁移映射，不能从 Pet 记录猜测登录关系。新表保留不删除，避免健康数据丢失。

## Open Questions

- 图片/PDF 单文件大小和单条记录附件数量在实现时对齐现有 storage/nginx 上限，并在前后端使用同一常量；该参数不影响资源模型。
- 一天多次、指定时间或指定星期的照护计划留到后续 capability；首版只有日期级周期，没有当前实现阻塞项。
