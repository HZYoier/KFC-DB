# 第二阶段 2.2 迁移说明（migration-guide）

> 属主：成员 C（计划 §7.1）。2026-10-30 建立，冻结 2.2 的批次协议、辅助表与快照形状；对应 OI-03 冻结前的两项 C 侧输入（`11c` 白名单落位、`capture_baseline.sql` 快照形状）。
> 依据：计划 §5.1/§5.2/§7.1/§7.2；B 的 [`b-baseline-reconciliation.md`](b-baseline-reconciliation.md) §7 最小协议；[`refactoring-design.md`](refactoring-design.md) §7/§7.2；[`c-normalization.md`](c-normalization.md) §4.5/§5.6。
> 口径：本文冻结的是**形状与协议**；各域 `baseline_a/b/c.sql` 的采集 SQL 由各属主实现，`11a/11b/11c`、`13a/13b/13c` 同理。本文不改任何第一阶段源码。

## 1. 术语与使用顺序

- **批次（batch）**：一次完整基线采集，`batch_id` 为 `BIGINT IDENTITY`，永不复用；迁移只接受明确指定的 `COMPLETED` 批次。
- **快照表**：`dbo.Baseline_<Table>`，逐业务表保存 v0.1 全量业务行（含 `batch_id`），用于迁移前采集与迁移后逐值对账；不是业务表，不进入 v1.0 结构。
- **使用顺序**：停止应用写入并完成备份 → `capture_baseline.sql`（采集）→ `run_migration.sql`（预检 → `11a` → `11b` → `11c` → `12_permissions` → 事务内检查 → v1.0 标记 → COMMIT）→ 各域 `13a/13b/13c` → `regression.sql`。

## 2. 辅助表（C 维护，`capture_baseline.sql` 幂等创建）

### 2.1 `dbo.SchemaVersion`

| 列 | 类型 | 约束/说明 |
| --- | --- | --- |
| `version_code` | `VARCHAR(20)` | PK；`'v0.1'` / `'v1.0'` |
| `object_digest` | `CHAR(64)` | 规范化对象摘要（§4.3），v0.1 在采集成功时登记、v1.0 在迁移事务内登记 |
| `batch_id` | `BIGINT` | 可空；v1.0 指向所用 `COMPLETED` 批次 |
| `applied_at` | `DATETIME2(0)` | 登记时间 |
| `note` | `NVARCHAR(200)` | 可空；操作者说明 |

首次采集只登记 v0.1；`v1.0` 只能由 `run_migration.sql` 在全部事务内检查通过后写入，失败不留下伪造标记。`v0.1` 已存在时，采集要求其 `object_digest` 与现场一致，否则拒绝（现场已漂移，需重新备份/评审，不改旧行）。

### 2.2 `dbo.MigrationBatch`

| 列 | 类型 | 约束/说明 |
| --- | --- | --- |
| `batch_id` | `BIGINT IDENTITY` | PK |
| `batch_status` | `VARCHAR(20)` | `CHECK IN ('CAPTURING','COMPLETED','FAILED','VOID')` |
| `previous_batch_id` | `BIGINT` | 可空，自引用 FK；重试/重采集指向紧邻前一批（含失败批） |
| `source_baseline` | `VARCHAR(50)` | 必填；v0.1 源码提交号/标识，由操作者用 SQLCMD 变量传入，不自动读 git |
| `capture_scope_version` | `VARCHAR(20)` | 固定 `'2.2-v1'`；本文冻结的比较口径版本 |
| `schema_digest` | `CHAR(64)` | 采集时现场对象摘要（§4.3） |
| `app_stop_confirmed` | `BIT` | 必填 1；操作者以 `ConfirmAppStopped=YES` 显式确认应用已停写，脚本不能自行证明 |
| `operator_note` | `NVARCHAR(200)` | 可空；操作者备注（不含口令/连接串） |
| `capture_started_at` | `DATETIME2(0)` | 必填 |
| `capture_completed_at` | `DATETIME2(0)` | 可空；`COMPLETED` 时必填 |
| `failed_at` | `DATETIME2(0)` | 可空；`FAILED` 时必填 |
| `error_detail` | `NVARCHAR(1000)` | 可空；脱敏错误（截断，不含口令/连接串/完整语句） |
| `voided_at` | `DATETIME2(0)` | 可空；`VOID` 时必填 |
| `void_reason` | `NVARCHAR(200)` | 可空 |

状态机：`CAPTURING → COMPLETED`（采集事务原子提交）、`CAPTURING → FAILED`（失败回滚后独立短事务标记；或进程断开后由操作者确认原会话结束、迁移锁可获取，再用 `sp_mark_baseline_failed` 标记）、`FAILED → VOID`（仅此一条作废边，保留失败审计）。`COMPLETED` 不可覆盖、不可作废；重复采集=新批次并记 `previous_batch_id`。状态列只由本框架对象/部署登录更新，业务角色无写权限。

### 2.3 `dbo.MigrationBaseline`（每表元数据）

| 列 | 类型 | 说明 |
| --- | --- | --- |
| `batch_id` | `BIGINT` | 与 `table_name` 组成 PK；FK → `MigrationBatch` |
| `domain_code` | `CHAR(1)` | `A`/`B`/`C` |
| `table_name` | `VARCHAR(128)` | v0.1 业务表名 |
| `snapshot_table` | `VARCHAR(128)` | 固定 `Baseline_<Table>` |
| `row_count` | `BIGINT` | 必填；采集事务内与业务表行数相等 |
| `content_checksum` | `INT` | 可空；`CHECKSUM_AGG(BINARY_CHECKSUM(*))`（零行= NULL），仅辅助定位，不替代逐值比较 |
| `captured_at` | `DATETIME2(0)` | 必填 |

### 2.4 `dbo.MigrationBaselineScope`（采集范围清单）

`domain_code CHAR(1)`、`table_name VARCHAR(128)`、`snapshot_table VARCHAR(128)`，PK `(table_name)`；由 `capture_baseline.sql` 幂等写入 25 行（A 10 / B 5 / C 10）。它是采集、元数据生成、13x 对账的共同范围来源，避免三处手写清单。

### 2.5 快照表 `dbo.Baseline_<Table>`（25 张）

- 列：`batch_id BIGINT NOT NULL` + **v0.1 业务表全部列**，列名、类型、可空性逐字一致；**不带** IDENTITY、默认值、CHECK、业务 FK；可加 `(batch_id, 业务主码)` 主键，不建跨快照 FK。
- 命名固定 `Baseline_<Table>`（与业务表同名，仅加前缀）；一张业务表一张快照表；不合并、不裁列（含 `AuditLog.detail_json NVARCHAR(MAX)`、`RolePermission.permission_name`）。
- 由各域 `baseline_a/b/c.sql` 幂等 `CREATE TABLE`（`IF OBJECT_ID(...) IS NULL`）并插入；C 的采集入口在采集事务内校验列契约（名称/类型/可空性）与行数，缺表/缺列/多列/类型不符即拒绝。
- 快照表只允许部署登录（`db_owner`/`sysadmin`）读写；不向任何 `role_*` 或 `cust_app` 授予权限，并对 `public` 显式 `DENY`。保留至 v1.0 验收完成；清理须操作者显式批准并留痕，不自动清理 `COMPLETED`。

### 2.6 A 的 13a 期初 offset 契约

`13a` 从同一 `COMPLETED` 批次读取：

- `dbo.Baseline_Customer`：`customer_id`、`current_points`（及 `member_level_id`、`status` 等原样列）；
- `dbo.Baseline_PointLedger`：`customer_id`、`ledger_status`、`point_delta`（及全部原样列）。

`opening_offset(customer) = Baseline_Customer.current_points − SUM(Baseline_PointLedger.point_delta WHERE ledger_status='EFFECTIVE' AND customer_id=...)`。若顾客无 EFFECTIVE 流水，`SUM` 记 0；`13a` 同时断言迁移后差额与该 offset 保持、且逐笔 EFFECTIVE 事实不变。`batch_id` 取 `SchemaVersion('v1.0').batch_id`，不得跨批拼数据。

## 3. 批次协议与执行约束

1. **停写与备份**：操作者停止应用写入并完成可验证备份；`capture_baseline.sql` 要求 SQLCMD 变量 `SourceBaseline=<ret>且 ConfirmAppStopped=YES`，并把确认写入 `MigrationBatch.app_stop_confirmed`。数据库无法可靠探测外部写入，停写是显式部署前提，不伪装成自动检测。
2. **应用锁**：采集与迁移入口都先 `sp_getapplock @Resource=N'KFC_DB.Stage2Migration', @LockMode='Exclusive', @LockOwner='Session', @LockTimeout=0`；拿不到即失败。锁只做互斥，不阻止普通 DML。
3. **单会话单事务**：采集在一个 sqlcmd 会话、一个事务内完成；`baseline_a/b/c.sql` **不得含 `GO`、不得开/提交事务、不得用临时表、不得切连接**，只做 `IF OBJECT_ID... CREATE TABLE` 与 `INSERT ... SELECT`；`@batch_id` 由采集入口声明并传入。
4. **批次启动**：独立短事务写入 `CAPTURING`（记 `source_baseline`、`schema_digest`、`previous_batch_id`、开始时间）；随后采集事务读取本批快照与元数据，原子更新 `COMPLETED`。
5. **失败路径**：采集事务内错误 → 回滚快照 → 独立短事务标 `FAILED`（脱敏错误）→ 非零退出。进程断开可能留下 `CAPTURING`：操作者确认原采集会话结束、锁可获取后执行 `sp_mark_baseline_failed`；只允许 `FAILED → VOID`（`sp_void_baseline_batch`），保留失败审计。
6. **重复运行**：新建批次；`previous_batch_id` 自动指向最近一批（含失败批），也可显式指定；`COMPLETED` 不改写、不复用；迁移只接受指定完整批次。
7. **漂移**：采集时记录 `schema_digest`；迁移前重算现场摘要，与批次不等即停止并重新备份/采集。迁移前再次核对各快照 `row_count` 与现场；任何不一致按漂移处理。`MigrationBaseline` 的 `row_count/content_checksum` 只做定位辅助，正式对账必须逐值比较。
8. **退出与输出**：所有 SQL 以 `:ON ERROR EXIT`/`-b` + `-f 65001` 执行并检查进程退出码；对账输出至少含 `batch_id/table/key/column/old/new/rule_id`；断言收尾 `RESULT: pass=… fail=…`，失败非零退出；日志同时识别 `Msg`、`消息`、`Sqlcmd: Error` 与 `FAIL`。

## 4. 摘要口径

### 4.1 批次级 `schema_digest`

对 `dbo` 下非迁移辅助对象（排除 `MigrationBatch`、`MigrationBaseline`、`MigrationBaselineScope`、`SchemaVersion`、`Baseline_*`、`fn_stage2_schema_digest`、`sp_mark_baseline_failed`、`sp_void_baseline_batch`）按固定顺序拼接：对象（名称/类型）→ 列（对象/列序/名称/类型/长度/精度/小数位/可空/IDENTITY）→ 键与约束（PK/UQ/FK/CHECK/DEFAULT，含名称与定义）→ 模块定义（`sys.sql_modules.definition` 原文）；`HASHBYTES('SHA2_256', ...)` 取十六进制 `CHAR(64)`。函数 `dbo.fn_stage2_schema_digest()` 由 `capture_baseline.sql` 创建，`run_migration.sql` 复用，禁止两处各写一套。

### 4.2 每表 `content_checksum`

`CHECKSUM_AGG(BINARY_CHECKSUM(<可比业务列>))`：取全部业务列中可比较类型的列（排除 `max_length = -1` 的 `nvarchar(max)` 等大对象列，如 `AuditLog.detail_json`）；零行返回 NULL。只作漂移/定位辅助；A/B/C 的 `13x` 必须按主码 FULL OUTER JOIN 逐列比较，不得用校验和代替。

### 4.3 快照值比较

按 B 的 [`b-baseline-reconciliation.md`](b-baseline-reconciliation.md) §3：主码双向差集、逐列比较、NULL 严格区分、字符串按二进制/字节长度、DECIMAL 精确、DATETIME2(0) 原值；每个差异输出业务键与规则号。

## 5. `11c` 白名单落位决议（OI-03 ①）

**决议（2026-10-30，C）**：保留**固定枚举白名单**，不改为"目录行即白名单"的纯 FK 方案。

- I-C12 拆分后：`Permission(permission_code PK, permission_name)`；`RolePermission(business_role_id, permission_code, status)`，原复合 PK 保留，新增 `FK_RolePermission_Permission(permission_code) → Permission(permission_code)`，删除 `RolePermission.permission_name`。
- 白名单 `CHECK` 随拆分**迁至 `Permission.permission_code`**（约束名改为 `CK_Permission_permission_code`），仍为固定枚举；`11c` **同时**执行：① `ALTER` 扩展该 CHECK（加入 v1.0 冻结清单中的新对象码）；② 向 `Permission` 插入新增目录行（名称取自冻结清单）；③ 重建 `RolePermission` 并授给相应角色（业务映射种子）；④ 加 FK、删旧列、补 `UQ_PurchaseOrder_replenishment_suggestion_id`。
- **为什么不用纯目录/FK 替代白名单**：计划 §5.1 要求 `11c` 更新白名单 CHECK、§6.5 把白名单列为不变量；固定枚举是显式最小权限门，避免将来任意 INSERT 目录行即扩权。目录表提供名称规范化，FK 提供引用完整性，`CHECK` 继续提供"哪些对象可被业务角色授权"的冻结清单；三者职责不同。
- **新增码的边界**：`Permission`/`RolePermission` 只覆盖**业务角色可授权对象**；`cust_app` 的三个顾客过程按契约 §1.5 仅做显式 `GRANT`，**不进入** `Permission`/`RolePermission` 白名单，由 `12_permissions` 按契约清单单独核对（否则会破坏"每个白名单码至少授予一个角色"的 t9 不变量）。`sp_get_current_employee_context` 若按冻结矩阵授予业务角色，则进白名单和 `RolePermission`。
- **当前预期数量（以冻结清单为准）**：v0.1 白名单 46 码 → v1.0 增加 6 个查询过程 + `sp_get_current_employee_context` = **53 码**；`RolePermission` 行数按冻结的角色×过程矩阵计算，不硬编码。`13c` 断言：白名单 = `Permission` 行集 = `sys.database_permissions` 中 `role_*` 的 EXECUTE/SELECT 目标集，`cust_app` 三过程单独核对且不得出现在业务角色 GRANT 中。
- **名称保真**：`baseline_c.sql` 捕获 `RolePermission(business_role_id, permission_code, permission_name, status)` 全量；`11c` 搬 `DISTINCT (code,name)` 前先检查同码多名（有则拒绝并输出码），`13c` 用 `Permission ⋈ RolePermission` 回旧关系逐行比对名称与状态。

## 6. B §7「C 需确认的最小协议」逐条答复

| B 的问题 | C 冻结口径 |
| --- | --- |
| 批次键类型与辅助表 schema | `batch_id BIGINT IDENTITY`；`MigrationBatch`/`MigrationBaseline`/`MigrationBaselineScope`/`SchemaVersion` 列定义见 §2；快照表 `Baseline_<Table>` 见 §2.5 |
| 快照保留/权限 | 永久保留至 v1.0 验收；仅部署登录读写，`public` DENY，业务角色/`cust_app` 无权限；不自动清理，清理须操作者批准留痕 |
| 同一采集连接传递方式 | 一个 sqlcmd 会话、一个采集事务；入口声明 `@batch_id`；`baseline_a/b/c.sql` 禁 `GO`/事务/临时表；不使用跨连接临时表 |
| 跨域顾客/库存键交接 | 同批快照含 `Customer`（A）与 `PointLedger`（B）顾客键、`Ingredient`（A）与 `Inventory`/`EmployeeAccount`（C）库存/员工键；13a/13b/13c 读同一 `batch_id`；跨域核对见 §2.6 与 B 的 BB-10/BB-11 |
| 拒绝漂移的标准化摘要 | 批次级 `schema_digest`（§4.1）+ 每表 `row_count`/`content_checksum`（§4.2）；迁移前重算，任一不等即停；摘要只辅助定位，逐值比较为准 |
| 重复运行行为 | 新建批次并记 `previous_batch_id`；`COMPLETED` 不可覆盖/作废；`FAILED → VOID` 唯一作废边；迁移只接受指定完整批次 |
| 对账输出与失败退出约定 | 差异行含批次/表/业务键/列/old/new/规则号；`RESULT` 收尾 + 非零退出；日志识别中英文错误前缀（§3.8） |

## 7. 迁移顺序、签名与回归（引用计划，不重复）

- 固定顺序：预检 → `11a` → `11b` → `11c` → `12_permissions` → 事务内只读检查 → v1.0 标记 → COMMIT；域脚本不得 COMMIT 外层事务；失败回滚外层并 `THROW`（计划 §5.1）。
- `12_permissions` 只重建授权/签名并核对"白名单、业务映射、实际 GRANT"；不替 `11c` 改约束。签名验收按计划 §5.1 三路径（ALTER 后失败回滚 / 重签后失败回滚 / 重签后成功提交），并以低权限店长实际调用 + 普通岗位拒绝验证；证据归档 `result/stage2/`。
- `13a/13b/13c` + `regression.sql`：独立回滚夹具、精确错误码、实际断言数与预期分母、`RESULT` 收尾；不重写冻结的 v0.1 测试文件。

## 8. 操作步骤与凭据

1. 停止应用写入 → 备份并验证可恢复 → 记录 `SourceBaseline`（v0.1 源码标识）。
2. 在 `sql/stage2/` 下按序运行 `capture_baseline.sql`（需 `baseline_a/b/c.sql` 已存在），SQLCMD 示例：
   `sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -i sql/stage2/capture_baseline.sql -v SourceBaseline="<commit>" -v ConfirmAppStopped=YES`
3. 记录返回的 `batch_id`、`schema_digest`、行数与输出；失败按 §3.5 标记/作废，不得改旧批。
4. 迁移与回归按计划 §5.1；恢复只还原已验证备份，不自动删库重建。
5. 登录名、密码、连接串不入仓、不入日志、不写 AI 记录；部署模板由 C 单独提供（`provision_employee.template.ps1`，计划 §7.1）。

## 9. 验证记录（本轮）

- 本文为**设计冻结件**；`capture_baseline.sql` 与 `baseline_c.sql` 的实跑证据见 `result/stage2/c-baseline-protocol-check-2026-10-30.txt`（首轮差异/修正/终轮输出按 H20 三段式）。A/B 的 `baseline_a/b.sql` 尚未交付时，端到端采集不宣称通过；框架以仓库外临时桩验证状态机与回滚，证据日志注明边界。
