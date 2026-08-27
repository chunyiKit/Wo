## 1. 数据模型与迁移

- [x] 1.1 新增核心 `Pet` SQLModel、Create/Update/Read schema，覆盖身份字段、照片版本和归档状态
- [x] 1.2 新增宠物日常的 RecordType、CarePlan、Record、RecordAttachment 模型及 read/write schema
- [x] 1.3 创建 Alembic migration，建立 Pet 与宠物日常表、family 隔离索引、到期扫描索引和完成幂等唯一约束
- [x] 1.4 在 migration 中将 `role=pet` Membership 转为 Pet、处理未使用宠物邀请并修复受影响 User 的 `current_family_id`
- [x] 1.5 实现旧 User avatar 到 Pet photo key 的 best-effort 数据迁移/日志回退，并提供上线前审计输出
- [x] 1.6 为 schema、月底/闰年约束和旧宠物成员迁移补充确定性测试

## 2. 核心 Pet 后端

- [x] 2.1 实现 family-scoped Pet list/get/create/update/archive service，落实 Owner/Admin 写权限和跨家庭 404
- [x] 2.2 实现 `/families/{family_id}/pets` CRUD 路由并注册到 v1 router
- [x] 2.3 实现 Pet 照片校验、私有存储 key、上传/读取/删除端点及 `?v=` cache-buster
- [x] 2.4 为 FamilyRead/bootstrap 增加 `pet_count`，保持 `member_count` 只统计 active 人类 Membership
- [x] 2.5 从后端 Role、ALL_ROLES、INVITABLE_ROLES、邀请接口和角色修改接口移除 `pet`
- [x] 2.6 补充 Pet CRUD、权限、照片版本/emoji 回退、family 隔离和角色拒绝的后端测试

## 3. 宠物日常插件基础与记录类型

- [x] 3.1 创建 `backend/app/plugins/pet/` 模块结构、manifest、路由挂载和 registry 注册，产品名设为“宠物日常”
- [x] 3.2 实现默认记录类型的幂等初始化，包含喂食、遛狗、铲砂、喂药、驱虫、疫苗、体检、体重、洗护、其他
- [x] 3.3 实现记录类型 list/create/update/reorder/archive API 和 Owner/Admin 权限
- [x] 3.4 阻止已被记录引用的类型改变 `data_kind`，并保证停用/改名不改写历史快照
- [x] 3.5 补充默认初始化并发幂等、自定义类型、停用和 data_kind 不可变测试

## 4. 健康记录与附件后端

- [x] 4.1 实现健康记录创建、读取、更新、删除 service，并保存类型快照、创建者和可选 kg 体重
- [x] 4.2 实现按发生日期/创建时间倒序的 keyset pagination 时间线 API
- [x] 4.3 实现记录创建者/完成者的成员信息批量注入，返回名称、emoji 和真实头像 URL
- [x] 4.4 实现图片/PDF 附件 MIME/大小/数量校验、私有 blob 上传、排序读取和鉴权下载
- [x] 4.5 实现附件/记录删除的数据库事务、上传失败补偿删除和 blob 清理失败日志
- [x] 4.6 实现手工记录与单次/周期后续计划的原子创建或更新
- [x] 4.7 补充记录快照、体重校验、分页、操作者头像、附件隔离/补偿和删除权限测试

## 5. 照护计划、完成与提醒后端

- [x] 5.1 实现照护计划 CRUD、active/archived Pet 校验和创建者/Admin 修改删除权限
- [x] 5.2 实现 none/day/week/month/year 周期计算，覆盖月底、闰年、逾期从实际完成日滚动和下一日期覆盖
- [x] 5.3 实现 `POST .../plans/{plan_id}/completions`，原子创建记录并滚动/停用计划
- [x] 5.4 使用 `(plan_id, scheduled_due_date)` 唯一约束处理重复及并发完成，并返回已有完成结果
- [x] 5.5 实现 Pet 列表摘要和宠物主页聚合查询，批量计算最早待办、今日照护、未来事项、最近体重和首屏时间线
- [x] 5.6 实现 weight 趋势查询，按发生日期和创建时间稳定排序并只消费 `data_kind=weight` 记录
- [x] 5.7 实现到期扫描与通知幂等标记，跳过归档 Pet、停用计划及未安装插件的 family
- [x] 5.8 将宠物提醒循环接入 app lifespan，并注册可配置的 `pet` 通知来源和 deeplink
- [x] 5.9 实现首页 preview 的最紧急事项、无待办最近体重和无宠物空状态
- [x] 5.10 补充周期计算、并发完成、聚合排序、体重趋势、提醒去重、卸载跳过和 preview 测试

## 6. Flutter 数据层与家庭管理

- [x] 6.1 在 Flutter models 中增加 Pet、记录类型、照护计划、健康记录、附件、列表摘要和主页聚合模型
- [x] 6.2 在 API client 中增加核心 Pet CRUD/照片与宠物日常类型、记录、附件、计划、完成、分页和聚合接口
- [x] 6.3 从邀请页、成员角色编辑和客户端 Role 注释/映射中移除 `pet`
- [x] 6.4 将家庭管理改为“家人/宠物”分组，展示 `member_count` 与 `pet_count`，并提供“邀请家人/添加宠物”独立入口
- [x] 6.5 实现 Pet 档案新增/编辑/归档表单和照片选择上传，缺图/失败时回退 emoji
- [x] 6.6 为家庭管理分组、权限状态、照片回退和角色选项补充 widget/model 测试

## 7. Flutter 宠物日常四个页面

- [x] 7.1 注册 `pet` 插件页面、deeplink、首页卡片展示和宠物色彩 token 使用
- [x] 7.2 实现宠物列表页，展示照片、名称、品种/年龄、最近体重和最近待办，并采用缓存 + 静默刷新
- [x] 7.3 实现宠物主页，包含今日照护、最近体重、即将到期和可分页健康时间线
- [x] 7.4 实现新增/编辑记录页，支持自定义类型/名称、日期、备注、weight 数值、下次日期和附件
- [x] 7.5 实现记录类型管理 UI，支持新增、改名、emoji、排序、停用并正确限制 data_kind 修改
- [x] 7.6 实现档案与照护计划管理页，支持单次及每 N 天/周/月/年周期和下一日期覆盖
- [x] 7.7 实现今日照护一键完成、并发/重复结果处理、完成者 MemberAvatar 和局部错误反馈
- [x] 7.8 确保所有增删改、完成、附件上传和轮询刷新不触发整页 spinner，失败时保留旧列表
- [x] 7.9 补充四个页面的空状态、错误重试、分页、周期表单、完成闭环和静默刷新 widget 测试

## 8. 验证、文档与交付

- [x] 8.1 运行并修复后端 formatter/linter、migration 检查及完整 pytest，确认无 Membership/通知回归
- [x] 8.2 运行并修复 `dart format`、`flutter analyze` 和 Flutter tests，手工验证多宠与小屏布局
- [x] 8.3 验证插件卸载/重装保留 Pet、类型、计划、记录和附件，且卸载期间不发送宠物提醒
- [x] 8.4 更新 `docs/backend-contract.md`，明确独立 Pet、核心/插件 API、权限、迁移和 `role=pet` 移除
- [x] 8.5 按项目规则在 `CHANGELOG.md` 顶部记录“宠物日常”功能；若顶部版本已发布，同步递增 CHANGELOG 与 `pubspec.yaml` 版本
- [x] 8.6 执行上线前 migration dry-run/备份核对，验证旧宠物转换、member_count/pet_count、照片回退及 User 账号保留
