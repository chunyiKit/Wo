## ADDED Requirements

### Requirement: 宠物日常注册为标准插件
“宠物日常” SHALL 以插件 id `pet` 注册 manifest、路由、首页 preview 和通知类型，支持每个 family 安装一次并在一次安装中管理多只核心 Pet。

#### Scenario: 安装宠物日常
- **WHEN** family 安装“宠物日常”
- **THEN** 系统 SHALL 在首页展示插件卡片，并允许成员进入宠物列表

### Requirement: 宠物列表展示最近待办
插件宠物列表 SHALL 展示每只 active Pet 的照片或 emoji、名称、品种/年龄摘要、最近体重和最早 active 待办。待办排序 MUST 先展示逾期，再展示今天，最后按未来到期日升序；列表增删改后 MUST 静默刷新而不把已显示列表替换为整页 spinner。

#### Scenario: 多宠物存在不同待办
- **WHEN** 一只 Pet 有逾期待办，另一只只有未来待办
- **THEN** 列表 SHALL 优先显示逾期 Pet，并在每张卡片显示各自最早待办

#### Scenario: 静默刷新宠物列表
- **WHEN** 用户编辑 Pet 或完成待办后返回宠物列表
- **THEN** 客户端 SHALL 保留当前列表并就地更新数据，刷新失败时继续显示旧数据

### Requirement: 宠物主页聚合照护与健康信息
宠物主页 SHALL 聚合今日照护、最近体重、即将到期事项和按发生日期倒序的健康时间线。今日照护 MUST 包含 `next_due_date <= today` 的 active 计划并标明逾期；完整时间线 SHALL 支持 keyset pagination。

#### Scenario: 查看宠物主页
- **WHEN** 用户打开一只有今日任务、历史体重和健康记录的 Pet
- **THEN** 页面 SHALL 同时展示今日照护、最近体重、未来待办和首屏健康时间线

#### Scenario: 加载更早记录
- **WHEN** 用户滚动到健康时间线首屏底部且还有更早数据
- **THEN** 客户端 SHALL 使用 cursor 加载下一页，并将其追加到现有时间线

### Requirement: 记录类型和显示名称可自定义
family SHALL 能创建、改名、排序和停用记录类型，并为类型设置 emoji。系统 SHALL 提供喂食、遛狗、铲砂、喂药、驱虫、疫苗、体检、体重、洗护、其他的默认建议类型，但 MUST NOT 限制用户只使用默认类型。

#### Scenario: 创建自定义记录类型
- **WHEN** 用户新建类型“耳朵护理”并选择 emoji
- **THEN** 该类型 SHALL 出现在当前 family 的新增记录与计划类型选择中

#### Scenario: 停用已使用类型
- **WHEN** 管理员停用一个已有历史记录引用的类型
- **THEN** 该类型 SHALL 不再供新记录选择，既有记录的名称、emoji 和内容保持不变

### Requirement: 体重能力不受类型改名影响
记录类型 MUST 具有稳定的 `data_kind`；首版至少支持 `general` 和 `weight`。已被记录引用的类型 MUST NOT 改变 `data_kind`，但 SHALL 允许修改显示名称和 emoji。`weight` 记录 MUST 保存可计算的标准化 kg 数值。

#### Scenario: 重命名体重类型
- **WHEN** 管理员把 weight 类型从“体重”改名为“晚饭前体重”
- **THEN** 新旧 weight 记录 SHALL 继续共同参与最近体重和趋势计算

#### Scenario: 修改已使用类型的数据能力
- **WHEN** 管理员尝试把已有记录引用的 general 类型改为 weight
- **THEN** 系统 SHALL 拒绝修改并保持原 data_kind

### Requirement: 新增灵活健康记录
成员 SHALL 能为某只 Pet 新增记录，选择记录类型并自定义记录名称，填写发生日期、可选备注、可选附件和可选下一次日期。记录 MUST 保存类型名称、emoji 和 data_kind 快照以及创建者；修改类型后历史记录 MUST 保持原貌。

#### Scenario: 新增驱虫记录
- **WHEN** 用户选择“驱虫”类型，填写名称“大宠爱体外驱虫”、日期、备注和下次日期并保存
- **THEN** 系统 SHALL 创建记录、写入当前用户为创建者，并在健康时间线显示完整内容

#### Scenario: 新增体重记录
- **WHEN** 用户选择 weight 类型并填写有效体重
- **THEN** 系统 SHALL 保存标准化 kg 数值，并更新宠物主页的最近体重

### Requirement: 记录支持私有附件
每条记录 SHALL 支持上传多张图片或 PDF 附件。附件 MUST 经大小和 MIME 校验后保存到 family/record 隔离的私有 blob storage，并携带原始文件名、类型、大小和顺序；非本 family 成员 MUST NOT 读取附件。

#### Scenario: 上传检查单照片和 PDF
- **WHEN** 家庭成员给一条就医记录上传合规图片和 PDF
- **THEN** 系统 SHALL 保存两份附件，并在该记录中按顺序返回可鉴权访问的附件信息

#### Scenario: 上传不支持的附件
- **WHEN** 用户上传超出限制或 MIME 不允许的文件
- **THEN** 系统 SHALL 返回校验错误，且 MUST NOT 创建附件行或残留 blob

### Requirement: 照护计划支持灵活周期
成员 SHALL 能为 Pet 创建和编辑照护计划，设置记录类型、自定义计划名称、备注、下次日期以及 `none/day/week/month/year` 周期和正整数间隔。系统 MUST NOT 根据项目名称自动推断医疗周期；无周期计划可作为具有明确下次日期的单次待办。

#### Scenario: 创建每月驱虫计划
- **WHEN** 用户创建“体外驱虫”计划，设置每 1 月和下次日期
- **THEN** 系统 SHALL 保存计划，并在到期时出现在今日照护和待办列表

#### Scenario: 创建单次复诊待办
- **WHEN** 用户创建 recurrence 为 none 且有 next_due_date 的“复诊”计划
- **THEN** 计划 SHALL 在该日期到期，完成后变为非 active 且不再计算下一次

### Requirement: 完成计划生成记录且并发幂等
成员完成照护计划时，系统 SHALL 在同一事务中创建一条关联健康记录、保存完成者和原计划到期日，并更新计划状态/下一日期。`(plan_id, scheduled_due_date)` MUST 唯一；对同一到期日的重复或并发完成 MUST 返回同一结果而不是创建重复记录。

#### Scenario: 完成周期计划
- **WHEN** 成员完成今天到期的每月驱虫计划
- **THEN** 系统 SHALL 创建驱虫记录、标记该成员为完成者，并从实际完成日期计算新的 next_due_date

#### Scenario: 两名成员同时完成
- **WHEN** 两名家庭成员同时提交同一计划同一到期日的完成请求
- **THEN** 系统 SHALL 只创建一条记录，并向两个请求返回该完成结果

### Requirement: 周期计算使用日历语义并允许覆盖
日/周周期 SHALL 使用日期间隔计算，月/年周期 SHALL 使用 calendar-aware 计算并在目标日期不存在时取当月最后一天。逾期计划默认 MUST 从实际完成日期滚动；调用方提供合法的下一日期覆盖值时 SHALL 使用覆盖值。

#### Scenario: 月底周期滚动
- **WHEN** 每月一次的计划在 1 月 31 日完成
- **THEN** 系统 SHALL 将下一次计算为 2 月的最后一天

#### Scenario: 覆盖下一次日期
- **WHEN** 用户完成计划时指定兽医确认的下一日期
- **THEN** 系统 SHALL 使用该日期，而不是周期自动计算结果

### Requirement: 手工记录可创建后续计划
新增手工记录时，成员 SHALL 能选择仅保存记录、创建单次下一待办或创建/更新周期计划。记录保存 MUST 独立于是否创建后续计划；后续计划创建失败时系统 MUST 明确返回失败且不得产生半完成状态。

#### Scenario: 从记录创建后续提醒
- **WHEN** 用户保存本次疫苗记录并选择每 1 年、指定下一日期
- **THEN** 系统 SHALL 原子地创建记录和对应照护计划

### Requirement: 体重摘要和趋势由结构化记录计算
系统 SHALL 从 `data_kind=weight` 的记录计算每只 Pet 的最近体重和按发生日期排序的体重趋势；普通文本中出现的数字 MUST NOT 被当作体重。相同日期多条记录 SHALL 按创建时间确定最新值。

#### Scenario: 查看最近体重
- **WHEN** Pet 有多条 weight 记录和若干普通记录
- **THEN** 宠物列表和主页 SHALL 显示发生日期最新的 weight 记录，普通记录不参与计算

### Requirement: 操作者使用真实成员头像
记录和计划完成结果 SHALL 返回创建者/完成者的名称、emoji 和真实成员头像 URL；前端 MUST 使用共享 MemberAvatar 渲染，真实头像不存在或加载失败时回退 emoji。

#### Scenario: 展示计划完成者
- **WHEN** 已上传头像的家庭成员完成照护计划
- **THEN** 今日照护和时间线 SHALL 展示该成员真实头像与名称

### Requirement: 到期通知不重复
后台任务 SHALL 扫描已到期且尚未针对当前 due date 通知的 active 计划，并向 family 的 active 人类成员创建通知。每个计划的同一 due date MUST 至多通知一次；归档 Pet、停用计划或卸载插件后 MUST NOT 继续发送通知。

#### Scenario: 到期发送通知
- **WHEN** active Pet 的计划到期且该日期未通知
- **THEN** 系统 SHALL 向家庭人类成员发送一次通知，并记录已通知 due date

#### Scenario: 轮询重复扫描
- **WHEN** 后台任务再次扫描已通知的同一 due date
- **THEN** 系统 SHALL NOT 创建重复通知

### Requirement: 首页预览显示最紧急事项
首页插件 preview SHALL 在全部 active Pet 的 active 计划中选择最紧急事项，逾期优先于今天、今天优先于未来；无待办时 SHALL 展示宠物数量和最近体重，无 Pet 时 SHALL 提示添加宠物。preview MUST NOT 修改计划或通知状态。

#### Scenario: 首页存在逾期待办
- **WHEN** family 的一只 Pet 有逾期计划且另一只只有未来计划
- **THEN** 首页卡片 SHALL 展示逾期 Pet 的名称、事项和逾期提示

### Requirement: 宠物日常数据按家庭授权并保留
所有宠物日常资源 MUST 同时校验请求者 Membership、family_id 和 pet_id 归属。Owner/Admin SHALL 能管理任意记录、类型和计划；普通 active 成员 SHALL 能创建、完成以及修改/删除自己创建的记录或计划，但 MUST NOT 删除他人记录。卸载插件 SHALL 保留类型、计划、记录和附件，重新安装后 SHALL 恢复展示。

#### Scenario: 普通成员删除他人记录
- **WHEN** 普通成员尝试删除另一成员创建的健康记录
- **THEN** 系统 SHALL 返回 403，记录与附件保持不变

#### Scenario: 卸载后重新安装
- **WHEN** family 卸载后重新安装“宠物日常”
- **THEN** 原有照护计划、健康时间线和附件 SHALL 恢复可见
