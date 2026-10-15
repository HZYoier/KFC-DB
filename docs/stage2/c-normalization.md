# C 域函数依赖与规范化分析（c-normalization）

> 属主：成员 C（计划 §7.1）。对应教学要求 **R6-08**（逐表：候选码、关键函数依赖、三类异常、范式判断及依据；满足要求者说明保留理由），并承接 R6-03（异常各附数据例子，无异常写明依据）、R6-04（逐表 1NF/2NF/3NF 与拆分 / 合并 / 保留方案及新关系属性与码）、R6-05（无损连接与依赖保持论证）、R6-15（保留须有分析证据；不为演示异常破坏原结构）——编号以 `docs/stage2/source-requirements.md` 为唯一依据（教学原文已删）。
>
> 判定口径（计划 §5）：2NF 检查**所有候选码**（不只看主键）；3NF 分析**非平凡 FD 的决定因素**（不只看主码）；样例没有重复值不代表依赖不成立；代理主键（`IDENTITY`）不消除任何依赖；表不是越多越好，结构合理就保留并给出证据。
>
> 事实基础：v0.1 冻结基线（提交 `b557d49` 的 `sql/`，树哈希 `a12f65cd…`，计划 §0）中的 `sql/03_inventory_security_schema.sql`（表、主键、外键、唯一键、过滤唯一索引、默认值）与 `sql/06_inventory_constraints_crud.sql`（全部命名 `CHECK` 与过程）。§2 的属性与键清单已与两份源码逐项对账、并与 `docs/er/c-inventory-security.svg` 交叉核对（2026-10-15，验证记录见 §7）。
>
> 术语：**候选码**＝候选标识（主码以外的一切极小唯一标识）；FD 记号 `X → Y`；**非主属性**＝不属于任何候选码的属性。
>
> 关联文件：`docs/stage2/c-issues.md`（保留项 I-C01…I-C11；本文结论已回填为 I-C09 的 FD 结论、I-C12 与 I-C13 两个 2.2 拟变更项）；`docs/库存权限数据字典.md`（逐字段中文口径）。本文是 2.2 的域内分析素材（R6-08 交付物），拆分与补声明在 2.2 设计冻结时随 B 的重构方案一并确认后由 `11c` 执行。

## 1. 分析对象与结论摘要

C 域共 **10 表、56 列、10 个主键**（含 3 个复合主键：`PurchaseOrderItem`、`RolePermission`、`EmployeeBusinessRole`；1 个 1:1 共享标识：`Inventory.ingredient_id`，主键整体即外键）、**4 个 `UNIQUE` 约束**、**1 个过滤唯一索引**、**16 条表内外键**（另有 `03` 末尾为 B 的 `Delivery` 建立的骑手外键，全库合计 17 条）、**8 个可空列**、15 条命名 `CHECK` 全部在 `06` 批次 1。

| 表 | 一行代表什么 | 候选码 | 范式判定 | 结论 |
| --- | --- | --- | --- | --- |
| `EmployeeAccount` | 一名员工的账号与岗位档案 | `employee_id`；`database_user_name`；`login_name` | 1NF/2NF/3NF 通过（决定因素均为候选码，实际达 BCNF） | 保留 |
| `BusinessRole` | 一种业务角色 | `business_role_id`；`role_code` | 通过（BCNF） | 保留 |
| `EmployeeBusinessRole` | 一条"员工 × 角色"的授予关系 | `(employee_id, business_role_id)` | 通过（BCNF） | 保留 |
| `RolePermission` | 一条"角色 × 权限码"的授权映射 | `(business_role_id, permission_code)` | **2NF 不通过**——`permission_code → permission_name` 是对候选码真子集的部分依赖 | **拟拆分**（I-C12，§4） |
| `Inventory` | 一种原料的当前库存快照（PK 即 FK） | `ingredient_id` | 通过（BCNF） | 保留 |
| `InventoryMovement` | 一条库存变动流水 | `inventory_movement_id` | 通过（BCNF） | 保留 |
| `ReplenishmentSuggestion` | 一张补货建议单及其审批链 | `replenishment_suggestion_id` | 通过（BCNF） | 保留 |
| `PurchaseOrder` | 一张由审批生成的采购单 | `purchase_order_id`；`purchase_order_no`；`replenishment_suggestion_id`（业务候选码，**未声明**） | 通过（BCNF，按业务候选码判定） | 保留结构 + **补声明**（I-C13，§5.6） |
| `PurchaseOrderItem` | 一条采购收货明细 | `(purchase_order_id, ingredient_id)` | 通过（BCNF） | 保留 |
| `AuditLog` | 一条操作审计事件 | `audit_log_id` | 通过；`detail_json` 为**有意的反规范化**（§3.10 写明边界） | 保留 |

**合并结论：本域没有应当合并的表对。** 十张表各承载互异的事实：五张业务表（库存快照 / 流水 / 建议 / 采购头 / 采购明细）主码与外码互不共享全行；四张安全表（员工 / 角色 / 授予 / 授权映射）分别是实体、字典、M:N 关联与矩阵行；审计表是独立事件流。唯一形如 1:1 的 `Inventory` 与 `Ingredient` 是**跨域**关系（C 建数量、A 建主档），且业务上原料可以暂无库存行（视图按 0/0/0 显示），合并会破坏域边界与这个可选性——保留两表（A 域 `Ingredient` 的实体分析见 `a-normalization.md`）。

## 2. 属性与键清单（对应 R6-02 的分析对象盘点）

表格式：`表 | 属性 | 类型 | 可空 | 键与约束（结构，源自 sql/03）`。`·` 分隔多项；`—` 表示无结构键；`IDENTITY(1,1)` 为自增。`CHECK` 约束全部在 `06` 批次 1，不列在本表（逐表分析见 §3）。

| 表 | 属性 | 类型 | 可空 | 键与约束 |
| --- | --- | --- | --- | --- |
| `EmployeeAccount` | `employee_id` | `BIGINT` | 否 | `PK_EmployeeAccount`·`IDENTITY(1,1)` |
| `EmployeeAccount` | `database_user_name` | `VARCHAR(128)` | 否 | `UQ_EmployeeAccount_database_user_name` |
| `EmployeeAccount` | `login_name` | `VARCHAR(128)` | 否 | `UQ_EmployeeAccount_login_name` |
| `EmployeeAccount` | `employee_name` | `NVARCHAR(50)` | 否 | — |
| `EmployeeAccount` | `job_code` | `VARCHAR(20)` | 否 | — |
| `EmployeeAccount` | `status` | `VARCHAR(20)` | 否 | — |
| `BusinessRole` | `business_role_id` | `BIGINT` | 否 | `PK_BusinessRole`·`IDENTITY(1,1)` |
| `BusinessRole` | `role_code` | `VARCHAR(20)` | 否 | `UQ_BusinessRole_role_code` |
| `BusinessRole` | `role_name` | `NVARCHAR(50)` | 否 | — |
| `BusinessRole` | `status` | `VARCHAR(20)` | 否 | — |
| `EmployeeBusinessRole` | `employee_id` | `BIGINT` | 否 | `PK_EmployeeBusinessRole`（复合）·`FK_EmployeeBusinessRole_Employee` → `EmployeeAccount(employee_id)` |
| `EmployeeBusinessRole` | `business_role_id` | `BIGINT` | 否 | `PK_EmployeeBusinessRole`（复合）·`FK_EmployeeBusinessRole_BusinessRole` → `BusinessRole(business_role_id)` |
| `EmployeeBusinessRole` | `assigned_by_employee_id` | `BIGINT` | 否 | `FK_EmployeeBusinessRole_AssignedByEmployee` → `EmployeeAccount(employee_id)` |
| `EmployeeBusinessRole` | `assigned_at` | `DATETIME2(0)` | 否 | — |
| `RolePermission` | `business_role_id` | `BIGINT` | 否 | `PK_RolePermission`（复合）·`FK_RolePermission_BusinessRole` → `BusinessRole(business_role_id)` |
| `RolePermission` | `permission_code` | `VARCHAR(50)` | 否 | `PK_RolePermission`（复合） |
| `RolePermission` | `permission_name` | `NVARCHAR(100)` | 否 | — |
| `RolePermission` | `status` | `VARCHAR(20)` | 否 | — |
| `Inventory` | `ingredient_id` | `BIGINT` | 否 | `PK_Inventory`（PKFK）·`FK_Inventory_Ingredient` → `Ingredient(ingredient_id)` |
| `Inventory` | `on_hand_qty` | `DECIMAL(12,3)` | 否 | — |
| `Inventory` | `locked_qty` | `DECIMAL(12,3)` | 否 | — |
| `Inventory` | `updated_at` | `DATETIME2(0)` | 否 | — |
| `InventoryMovement` | `inventory_movement_id` | `BIGINT` | 否 | `PK_InventoryMovement`·`IDENTITY(1,1)` |
| `InventoryMovement` | `ingredient_id` | `BIGINT` | 否 | `FK_InventoryMovement_Inventory` → `Inventory(ingredient_id)` |
| `InventoryMovement` | `movement_type` | `VARCHAR(20)` | 否 | — |
| `InventoryMovement` | `on_hand_delta` | `DECIMAL(12,3)` | 否 | — |
| `InventoryMovement` | `locked_delta` | `DECIMAL(12,3)` | 否 | — |
| `InventoryMovement` | `reference_type` | `VARCHAR(20)` | 否 | — |
| `InventoryMovement` | `reference_id` | `BIGINT` | 是 | 多态引用，无外键（I-C02） |
| `InventoryMovement` | `moved_at` | `DATETIME2(0)` | 否 | — |
| `ReplenishmentSuggestion` | `replenishment_suggestion_id` | `BIGINT` | 否 | `PK_ReplenishmentSuggestion`·`IDENTITY(1,1)` |
| `ReplenishmentSuggestion` | `ingredient_id` | `BIGINT` | 否 | `FK_ReplenishmentSuggestion_Ingredient` → `Ingredient(ingredient_id)`·过滤唯一索引 `UQ_ReplenishmentSuggestion_ingredient_id`（开放态） |
| `ReplenishmentSuggestion` | `current_qty` | `DECIMAL(12,3)` | 否 | — |
| `ReplenishmentSuggestion` | `suggested_qty` | `DECIMAL(12,3)` | 否 | — |
| `ReplenishmentSuggestion` | `suggestion_status` | `VARCHAR(20)` | 否 | — |
| `ReplenishmentSuggestion` | `created_by_employee_id` | `BIGINT` | 否 | `FK_ReplenishmentSuggestion_CreatedByEmployee` → `EmployeeAccount(employee_id)` |
| `ReplenishmentSuggestion` | `submitted_by_employee_id` | `BIGINT` | 是 | `FK_ReplenishmentSuggestion_SubmittedByEmployee` → `EmployeeAccount(employee_id)` |
| `ReplenishmentSuggestion` | `approved_by_employee_id` | `BIGINT` | 是 | `FK_ReplenishmentSuggestion_ApprovedByEmployee` → `EmployeeAccount(employee_id)` |
| `ReplenishmentSuggestion` | `rejected_by_employee_id` | `BIGINT` | 是 | `FK_ReplenishmentSuggestion_RejectedByEmployee` → `EmployeeAccount(employee_id)` |
| `PurchaseOrder` | `purchase_order_id` | `BIGINT` | 否 | `PK_PurchaseOrder`·`IDENTITY(1,1)` |
| `PurchaseOrder` | `purchase_order_no` | `VARCHAR(20)` | 否 | `UQ_PurchaseOrder_purchase_order_no` |
| `PurchaseOrder` | `replenishment_suggestion_id` | `BIGINT` | 否 | `FK_PurchaseOrder_ReplenishmentSuggestion` → `ReplenishmentSuggestion(replenishment_suggestion_id)` |
| `PurchaseOrder` | `purchase_status` | `VARCHAR(20)` | 否 | — |
| `PurchaseOrder` | `approved_by_employee_id` | `BIGINT` | 是 | `FK_PurchaseOrder_ApprovedByEmployee` → `EmployeeAccount(employee_id)` |
| `PurchaseOrder` | `approved_at` | `DATETIME2(0)` | 是 | — |
| `PurchaseOrderItem` | `purchase_order_id` | `BIGINT` | 否 | `PK_PurchaseOrderItem`（复合）·`FK_PurchaseOrderItem_PurchaseOrder` → `PurchaseOrder(purchase_order_id)` |
| `PurchaseOrderItem` | `ingredient_id` | `BIGINT` | 否 | `PK_PurchaseOrderItem`（复合）·`FK_PurchaseOrderItem_Ingredient` → `Ingredient(ingredient_id)` |
| `PurchaseOrderItem` | `ordered_qty` | `DECIMAL(12,3)` | 否 | — |
| `PurchaseOrderItem` | `received_qty` | `DECIMAL(12,3)` | 否 | `DF_PurchaseOrderItem_received_qty`（默认 0） |
| `AuditLog` | `audit_log_id` | `BIGINT` | 否 | `PK_AuditLog`·`IDENTITY(1,1)` |
| `AuditLog` | `employee_id` | `BIGINT` | 否 | `FK_AuditLog_Employee` → `EmployeeAccount(employee_id)` |
| `AuditLog` | `action_name` | `VARCHAR(50)` | 否 | — |
| `AuditLog` | `entity_name` | `VARCHAR(50)` | 否 | — |
| `AuditLog` | `entity_id` | `BIGINT` | 是 | — |
| `AuditLog` | `detail_json` | `NVARCHAR(MAX)` | 是 | — |
| `AuditLog` | `logged_at` | `DATETIME2(0)` | 否 | — |

**可空列共 8 个**（`InventoryMovement.reference_id`；`ReplenishmentSuggestion` 的三个审批链人员列；`PurchaseOrder.approved_by_employee_id`/`approved_at`；`AuditLog.entity_id`/`detail_json`），与数据字典 §0 口径一致；其余全部 `NOT NULL`（`CHECK` 在 `NULL` 上求值为 `UNKNOWN` 会放行，受约束列必须先非空）。

## 3. 逐表函数依赖与范式分析

每表按 R6-08 的五项给结论：候选码 → 关键 FD → 1NF/2NF/3NF → 三类异常（各附数据例子；无异常写"如何避免"）→ 保留或改动。数据例子取自 `09c` 种子形状或按库结构可构造的合法值。

### 3.1 `EmployeeAccount`（员工账号）

- **业务含义**：一行 = 一名员工；`database_user_name` 是与 `USER_NAME()` 比对的解析入口，`login_name` 是部署档案（I-C11）。
- **候选码**：`employee_id`（PK）、`database_user_name`（`UQ_EmployeeAccount_database_user_name`）、`login_name`（`UQ_EmployeeAccount_login_name`），三者均为单属性候选码。
- **关键 FD**：三个候选码各自决定全部其余属性。唯一的"跨键"讨论：默认部署路径要求登录名与数据库用户名同名（计划 §6.1），但这是**部署约定而非函数依赖**——Windows 认证路径下两者不同源，且两列各自已是候选码，无论 `login_name → database_user_name` 是否按约定成立，决定因素都落在候选码上，不产生任何异常。
- **范式**：单值列（1NF）；候选码均为单属性，不存在部分依赖（2NF）；决定因素全部是候选码（3NF），实际达 BCNF。
- **三类异常**：无。避免机制：`database_user_name`（解析）与 `login_name`（档案）各自一处存储、无相互派生列；`employee_name`/`job_code`/`status` 描述员工本体，随主码一处维护。
- **结论**：保留（I-C11 的部署映射由 2.3 预检负责，属结构外约定）。

### 3.2 `BusinessRole`（业务角色）

- **业务含义**：一行 = 一种业务角色（v0.1 固定 7 个岗位白名单）。
- **候选码**：`business_role_id`（PK）、`role_code`（`UQ_BusinessRole_role_code`）。
- **关键 FD**：两个候选码 → `role_name`、`status`。`role_name → role_code` **不成立**（业务未要求角色中文名互异，也未声明唯一），故 `role_name` 不作候选码。
- **范式**：1NF/2NF/3NF 通过，达 BCNF（决定因素都是候选码）。
- **三类异常**：无。字典行天然单处存储；`role_code` 与数据库角色 `role_<code>` 的映射由过程白名单保证（`06` 批次 5）。
- **结论**：保留。

### 3.3 `EmployeeBusinessRole`（员工业务角色关联）

- **业务含义**：一行 = 一条"员工 × 角色"的授予关系（M:N 关联实体），并记录操作人与时间。
- **候选码**：`(employee_id, business_role_id)`（复合 PK，无其他候选码）。
- **关键 FD**：`(employee_id, business_role_id) → assigned_by_employee_id, assigned_at`——`assigned_by`/`assigned_at` 描述**这次授予**（谁、何时），完整依赖整个键；不存在对真子集的部分依赖（`employee_id → assigned_by` 不成立：同一员工可以有不同角色、不同授予人）。
- **范式**：1NF/2NF/3NF 通过，达 BCNF。
- **三类异常**：无。关联事实只存一处；数据库角色成员关系是同事务的另一载体（`ALTER ROLE ... ADD MEMBER`），两者由 `sp_assign_employee_business_role` / `sp_revoke_...` 成对维护、不是冗余列。
- **结论**：保留。

### 3.4 `RolePermission`（业务角色权限映射）

- **业务含义**：一行 = 一条"角色 × 权限码"的授权映射，是 08 授权矩阵的数据库表示；`permission_name` 是该权限码的中文名（09c 注释：仅作展示）。
- **候选码**：`(business_role_id, permission_code)`（复合 PK，无其他候选码；`permission_code` 单独不唯一——同一权限授予多个角色即多行）。
- **关键 FD**：
  - `(business_role_id, permission_code) → permission_name, status`（行内依赖，完整）；
  - **`permission_code → permission_name`**——业务规则：权限码标识一个权限对象（过程或视图名，受白名单 `CHECK` 唯一约束），其展示名随码唯一，与授予哪个角色无关。**`permission_code` 是候选码的真子集，`permission_name` 是非主属性——部分依赖，违反 2NF。**
  - `status` 的语义是**该映射行自身的启用状态**（对某角色停用某授权时置 `INACTIVE` 而非删行），因此 `status` 完整依赖整个键，不是部分依赖；该语义将在 2.2 冻结时在数据字典写死（§6 冻结事项），若误解为"权限对象状态"，会额外引入 `permission_code → status` 的部分依赖。
- **范式**：1NF 通过（列值原子）；**2NF 不通过**（上述部分依赖）；3NF 因 2NF 未满足而不成立。拆分后两关系均达 BCNF（§4）。
- **三类异常**（按现状 `RolePermission(business_role_id, permission_code, permission_name, status)` 给出，数据例子取自 `09c` 种子形状）：
  - **插入异常**：权限目录无法独立于授权存在——要把一个新权限码的名称登记入库，必须先决定把它授予某个角色，插一行完整映射。例：`11c` 把新对象 `sp_export_report` 纳入白名单后、尚未授予任何角色时，它的中文名在全库无处存放。
  - **修改异常**：改一个权限码的展示名必须更新该码的**全部**授权行，漏改则同码多名，且数据库不报错（FD 无声明式保护）。例：`v_inventory_available` 在种子中有两行——`(store_manager, 'v_inventory_available', N'原料可售量视图', 'ACTIVE')` 与 `(shift_manager, 'v_inventory_available', N'原料可售量视图', 'ACTIVE')`——只把第一行改成 `N'库存可售量视图'` 后，两个角色看到不同名称。
  - **删除异常**：删除某权限码的最后一条授权行，其名称随之丢失（权限对象与白名单项仍然存在）。例：`sp_receive_inventory` 在 v0.1 种子中恰只有 `shift_manager` 一行授权，删除该行后 `'采购收货入库'` 这一名称在全库不可查。
- **结论**：**拟拆分**，变更项 I-C12（§4 给出新关系属性与码、无损连接与依赖保持论证、迁移与回归影响）。备选"整体保留"需在重构方案记录上述残留异常及接受理由——不推荐：依赖客观成立、行数随 `11c` 白名单扩展只会增多、修复成本小（§4.5）。

### 3.5 `Inventory`（原料库存）

- **业务含义**：一行 = 一种原料的当前库存快照，`ingredient_id` 同时是主键与外键（1:1 共享标识）；`available_qty` 等派生值不落库（I-C01）。
- **候选码**：`ingredient_id`（PK 兼 FK，唯一）。
- **关键 FD**：`ingredient_id → on_hand_qty, locked_qty, updated_at`。派生属性 `可售量 = on_hand_qty − locked_qty` 有意不物化——若落列会引入"两处数量必须同步"的维护依赖与不一致异常，查询时由 `v_inventory_available` 计算（I-C01）；安全性列（`on_hand_qty` / `locked_qty` ≥ 0）由 `CHECK` 保证。
- **范式**：1NF/2NF/3NF 通过，达 BCNF（单属性候选码）。
- **三类异常**：无。每原料恒一行、每事实一处；"没有库存行的原料"由视图按 0/0/0 处理，是参与约束（可选）而非异常。
- **结论**：保留。

### 3.6 `InventoryMovement`（库存变动流水）

- **业务含义**：一行 = 一种原料的一次数量变动（LOCK/RELEASE/CONSUME/RECEIPT/ADJUSTMENT），是账实勾稽的唯一数据源；只追加、不合并。
- **候选码**：`inventory_movement_id`（唯一）。组合 `(ingredient_id, moved_at)` **不是**候选码：`moved_at` 为秒精度（`DATETIME2(0)`），同一原料同一秒可产生多条流水（同一事务内的锁库与实扣等），样例不重复不能证明依赖（R6-13 口径）。
- **关键 FD**：`inventory_movement_id → 全部属性`；无部分依赖（单属性码）、无传递依赖。多态引用 `reference_id`（I-C02）的含义随 `reference_type` 变化（ORDER → B 的订单、PURCHASE_ORDER → 本域采购单、ADJUSTMENT 固定 NULL），这是**条件值域约束**（`CK_InventoryMovement_reference_type` / `CK_InventoryMovement_reference`），不是函数依赖异常：`reference_id` 不决定任何非主属性，反方向 `reference_type` 对同一单据 ID 也不唯一。
- **范式**：1NF/2NF/3NF 通过，达 BCNF。
- **三类异常**：无。事件行天然无冗余——每个事实（某原料某刻的变动）恰好一行，没有"同一事实存两处"的可更新结构；五类流水的数值形状由过程保证（§6 不变量，属数值语义非依赖）。
- **结论**：保留。

### 3.7 `ReplenishmentSuggestion`（补货建议单）

- **业务含义**：一行 = 一张建议单（低库存自动开单或值班经理手工创建）及其审批链。
- **候选码**：`replenishment_suggestion_id`（唯一）。注意 `ingredient_id` **不是**候选码：全时段一原料可有多张历史建议（`REJECTED`/`CLOSED` 留档），只在开放态（`PENDING`/`SUBMITTED`/`APPROVED`）集合上唯一——这是**部分（时序）唯一约束**，由过滤唯一索引 `UQ_ReplenishmentSuggestion_ingredient_id` 声明，不是函数依赖（§5.5）。
- **关键 FD**：`replenishment_suggestion_id → 全部属性`。`current_qty` 是**生成/更新时刻的快照**（I-C08）：它记录"开单那一刻的现有量"，此后不随 `Inventory` 变化，任何其他关系都无法反推它——快照是历史时刻的事实，不是派生冗余（与计划 §2.1 关于成交价快照的口径同型）。`suggested_qty > 0`、两个状态枚举由 `CHECK` 保证；"状态与三个审批链人员列的搭配"（如 `SUBMITTED` 必有提交人）是元组级业务规则，由过程保证（无声明式 `CHECK`，见 §6 冻结事项）。
- **范式**：1NF/2NF/3NF 通过（单属性候选码），达 BCNF。
- **三类异常**：无。每张建议单的事实（原料、两量、状态、人员链）都只存一处；状态迁移全部经过程且写审计，不存在可得不一致的冗余列。
- **结论**：保留（快照语义 I-C08 维持；看板视图联现实时量）。

### 3.8 `PurchaseOrder`（采购单头）

- **业务含义**：一行 = 一张由审批生成的采购单；"一张建议单对应一张采购单"（字典 §4）。
- **候选码**：`purchase_order_id`（PK）；`purchase_order_no`（`UQ_PurchaseOrder_purchase_order_no`，声明式）；**`replenishment_suggestion_id`——业务上是候选码**：审批过程只允许 `SUBMITTED` 的建议通过、且通过后即 `APPROVED`（终态之一），全库不存在第二条生成路径，因此一个建议至多产生一张采购单；但 v0.1 **未在约束层声明**该唯一性（无唯一约束/索引），字典 §4 已如实记录"过程与状态机保证、约束层没有兜底"。
- **关键 FD**：三个决定因素各自 → 其余全部属性。`approved_by_employee_id`/`approved_at` 可空是为 `CHECK` 中预留的 `DRAFT` 状态兜底；经 v0.1 唯一路径（审批生成）产生的行两列必有值——这属元组级过程规则，不改变 FD。
- **范式**：1NF/2NF/3NF 通过——按**业务候选码**判定，`replenishment_suggestion_id` 是候选码，其决定因素成立属正常；若只看声明的键，表结构本身也不含任何部分/传递依赖，实质达 BCNF。问题不在范式，在执行层：**候选码缺声明**（§5.6、I-C13）。
- **三类异常**：无冗余、无更新异常。缺声明带来的是**约束缺口**：绕过过程直接插入第二条同建议单采购单不会被数据库拒绝（过程路径已被状态机挡住）。修法是补一条唯一性声明（I-C13），不改结构。
- **结论**：保留结构 + 2.2 补 `UQ_PurchaseOrder_replenishment_suggestion_id`（§5.6）。

### 3.9 `PurchaseOrderItem`（采购单明细）

- **业务含义**：一行 = 一张采购单 × 一种原料的收货进度（`ordered_qty` 审批时写入、`received_qty` 收货累计）。
- **候选码**：`(purchase_order_id, ingredient_id)`（复合 PK，无其他候选码——同一采购单与原料只能一行，正是收货累计不重复的物理保证）。
- **关键 FD**：`(purchase_order_id, ingredient_id) → ordered_qty, received_qty`，完整依赖；无部分依赖。
- **快照说明**：`ordered_qty` 在审批事务内按建议量复制（等于当刻 `ReplenishmentSuggestion.suggested_qty`），此后两表均无修改路径（建议在 `APPROVED` 后冻结），一致性不依赖人工维护；若将来引入"审批改量"，两值可独立演化，快照语义仍正确——与成交价/建议量快照同型。
- **范式**：1NF/2NF/3NF 通过，达 BCNF。
- **三类异常**：无。复合主键使"同单同原料重复行"物理不可能；`received_qty <= ordered_qty` 由 `CHECK` 兜底（过程还要先校验本次收货量）。
- **结论**：保留。

### 3.10 `AuditLog`（审计日志）

- **业务含义**：一行 = 一条敏感操作审计事件（谁、何时、对哪个实体做了什么），只由 `sp_write_audit_log` 写入、只追加。
- **候选码**：`audit_log_id`（唯一）。`employee_id`、`(action_name, logged_at)` 等均不唯一，`entity_id` 为多态引用（随 `entity_name` 解释，与 I-C02 同类）。
- **关键 FD**：`audit_log_id → 全部属性`；`detail_json` 完全依赖事件行，不存在由此产生的跨行依赖。
- **1NF 讨论（有意的反规范化）**：`detail_json` 保存事件的 JSON 负载（如 `{"purchase_order_no":"PO202609270001","ingredient_id":1,"ordered_qty":2.000}`），值本身可再分，**按严格 1NF 属非原子值**。判定为保留，依据三点：① 事件负载是"一个事件的完整快照"，不是可独立更新的多值事实（负载只随事件行产生、无更新路径）；② 无任何生产过程/视图对其做关系运算（无连接键、无谓词依赖；仅验收做过文本匹配），拆分（EAV 明细表）不会消除任何更新异常，只会把"读一条事件"变成 N 行连接；③ 边界明确写出：**若将来需要按明细字段做审计检索，应另立明细表或在 2.2＋引入解析列，不得把当前列当作可查询结构**。同时 `action_name`/`entity_name` 无 `CHECK`（字典 §10 注明），值域靠过程——属声明边界，不是 FD 问题。
- **范式**：就所存事实而言，单属性候选码、无部分/传递依赖（1NF 按上述口径、2NF/3NF 通过）。
- **三类异常**：无。只追加、无冗余、无共享的可更新事实。
- **结论**：保留（`detail_json` 反规范化口径与边界如上）。

## 4. `RolePermission` 拆分方案与论证（I-C12）

### 4.1 现状与违规点

`RolePermission(business_role_id, permission_code, permission_name, status)`，唯一候选码 `K = (business_role_id, permission_code)`；非平凡 FD 集 `F = {K → permission_name, K → status, permission_code → permission_name}`。`permission_code ⊂ K` 且 `permission_name` 非主属性 ⇒ 部分依赖 ⇒ 违反 2NF（§3.4 已给三类异常的数据例子）。

### 4.2 拆分方案（新关系属性与码）

- **`Permission(permission_code, permission_name)`**：权限目录。`permission_code` 为 PK（单属性候选码）；FD：`permission_code → permission_name`。
- **`RolePermission(business_role_id, permission_code, status)`**：授权映射。PK `(business_role_id, permission_code)` 不变；`FK_RolePermission_BusinessRole` 保留，新增 `FK_RolePermission_Permission(permission_code) → Permission(permission_code)`；FD：`K → status`。
- **白名单 `CHECK` 的落位**：`CK_RolePermission_permission_code`（46 项白名单，I-C10）的语义是"哪些对象可被授权"，随拆分**迁至 `Permission.permission_code`**——目录即白名单定义，`RolePermission` 经外键间接受控；`11c` 扩展白名单即向 `Permission` 增行。`CK_RolePermission_status` 保留在 `RolePermission`。该落位随 2.2 冻结写入数据字典（§6）。
- **数据迁移（`11c` 执行，方案级）**：`INSERT INTO Permission SELECT DISTINCT permission_code, permission_name FROM RolePermission`，先做完整性检查——同一个 `permission_code` 出现两种 `permission_name` 时**拒绝迁移并输出具体权限码**（不静默合并）；`RolePermission` 删除 `permission_name` 列。v0.1 种子（52 行授权、46 个权限码，每码名称唯一且每码至少被授予一次）满足检查，迁移后 `Permission` 46 行、`RolePermission` 52 行，授权行数不变。

### 4.3 无损连接论证

分解为 `R1 = Permission(permission_code, permission_name)`、`R2 = RolePermission(business_role_id, permission_code, status)`。公共属性 `R1 ∩ R2 = {permission_code}`，且 `permission_code` 是 `R1` 的候选码（超键）——满足"两关系分解的公共属性是其中之一的超键⇒无损"定理（也满足 chase 检验：`R2` 中每行在 `R1` 上至多匹配一行，自然连接不产生伪元组）。连接 `R1 ⋈ R2` 在 `{permission_code}` 上恢复出的每行 `(business_role_id, permission_code, name, status)` 与原表行一一对应，**不丢失也不新增元组**。

### 4.4 依赖保持论证

原 FD 集 `F = {K → permission_name, K → status, permission_code → permission_name}`。投影：`F2 = F+ ∩ (R2 属性对) = {K → status}`；`F1 = F+ ∩ (R1 属性对) = {permission_code → permission_name}`。并集可推出 `F` 的全部依赖：`permission_code → permission_name` 是 `F1` 原文；`K → status` 是 `F2` 原文；`K → permission_name` 由 `K → permission_code`（平凡）与 `permission_code → permission_name` **传递推出**；反向（投影闭包的每一条都是 `F` 的蕴含）显然成立，故两者闭包相等。依赖保持不要求原 FD 逐字出现在某张分表——`K → permission_name` 经传递推导即为保持（计划 §5 的口径）。

### 4.5 迁移与回归影响（写进 2.2 冻结清单）

- **`11c`**：建 `Permission`、搬数据（含"同码多名即拒绝"检查）、删列、加外键、白名单 `CHECK` 迁位；对 `11c` 应同步扩展白名单的新对象，向 `Permission` 增行并在 `RolePermission` 授给相应角色。
- **`13c`/`regression.sql`**：等价断言——52 条授权行按 `(role, code)` 逐行不变；46 个目录行且每码名称与迁移前一致（名称保真）；`RolePermission` 与 `sys.database_permissions` 的 `GRANT` 双向差集仍为空（t9 T7 的等价覆盖）；负例：重复目录行、断链外键、同码多名输入被拒。
- **`baseline_c.sql`**：迁移前快照必须捕获 `RolePermission` 的 `(role, code, name, status)` 全量（名称保真比对的基准），见计划 §5.2"权限映射"。
- **文档**：数据字典（§9/§11 与本域表数：v1.0 为 11 表）随 2.2 更新；ER 总图 v1.0 拆出 `Permission` 实体；`I-C10` 的落点表述（白名单 CHECK 位置）同步更新。
- **跨域影响：无**。全仓检索确认：`permission_name` 仅出现于 `03` 建列与 `09c` 种子（`06` 的白名单 `CHECK` 只约束 `permission_code`），没有任何过程、视图、A/B 域文件或第一阶段测试读取该列；`08` 的 `GRANT`/`DENY` 与 `RolePermission` 无关——拆分是 C 域内部结构变更，不涉及跨域调用者（验证记录见 §7）。

## 5. 跨表观察（FD 视角）

### 5.1 `job_code` 与 `BusinessRole.role_code`（I-C09 结论）

两者取值同域（7 个岗位代码）但**分层存储、不是冗余**：`EmployeeAccount.job_code` 是单值行政岗位（大写，如 `'STORE_MANAGER'`、`'RIDER'`），由 B 的 `05` 过程直接校验（收银/厨师/配餐/骑手等入口）与骑手口径使用；`BusinessRole.role_code` 是小写数据库业务角色（`'store_manager'`…），经 `EmployeeBusinessRole` M:N 授予，驱动 `06` 批次 5 的身份校验与 `08` 的 `GRANT`。判定：① `job_code` 在 `EmployeeAccount` 内不决定任何非主属性，本身无 FD 问题；② 跨表不存在业务函数依赖——`job_code` 不决定角色集合（计划 §6.1 明确承认多业务角色员工，且样例中 `(i, i)` 一对一只是种子构造，不能证明依赖，R6-13）；③ 两层各自校验构成纵深防御（I-C05）。**结论：语义不同层、非冗余，不做结构改动**（FD 分析到此收口 I-C09）。

### 5.2 快照字段与跨表复制（`current_qty`、`ordered_qty`）

`ReplenishmentSuggestion.current_qty`（生成/更新时现有量）与 `PurchaseOrderItem.ordered_qty`（审批时建议量）都是**历史时刻快照**：它们的值由当时事实决定、此后无修改路径，任何其他关系无法反推——快照不因"与来源同值"而成为可消除的冗余，`FD` 上完全依赖各自的主码（与计划 §2.1 成交价快照同判）。保留。

### 5.3 派生值不落列（I-C01）

可售量（`on_hand_qty − locked_qty`）、未收数量（`ordered_qty − received_qty`）、低库存布尔值均不落列，由 `07c` 视图计算——避免"两处存储必须同步"的更新异常。保留。

### 5.4 多态引用（I-C02、`AuditLog.entity_id`）

`InventoryMovement.reference_id` 与 `AuditLog.entity_id` 的引用目标随类型列解释（`reference_type` / `entity_name`），不用可空外码列的三列方案（阶段一已定，I-C02）。这是**条件值域约束**而非函数依赖：被引用目标不决定本表任何非主属性；`CHECK` 保证单据类流水必须有单号。保留。

### 5.5 过滤唯一索引不是函数依赖（I-C03）

`UQ_ReplenishmentSuggestion_ingredient_id` 表达"每原料至多一张**开放**建议"——随时间变化的部分唯一性（`WHERE suggestion_status IN (...)`），不是"属性决定属性"的函数依赖：全时段 `ingredient_id` 一对多（历史留档）。分析候选码与 FD 时必须按全时段口径，不得把样例/过滤条件下的唯一误读成候选码。

### 5.6 `PurchaseOrder` 候选码补声明（I-C13）

业务事实"一张建议单对应一张采购单"（字典 §4）即 `replenishment_suggestion_id → purchase_order_id`：`PurchaseOrder.replenishment_suggestion_id` 是非空且业务唯一的候选码。v0.1 由"仅 `SUBMITTED` 可审批 + `APPROVED` 终态 + 无第二条生成路径"的过程保证，约束层未兜底。**2.2 拟补 `UQ_PurchaseOrder_replenishment_suggestion_id`**（唯一约束/唯一索引，`11c` 执行）：只声明既有业务事实，不改变任何行数据；`13c` 加负例（同一建议单插入第二张采购单被 `2601/2627` 拒绝）；`baseline_c.sql` 捕获迁移前该列的 1:1 现场供比对。若 2.2 之后引入"建议单可重开新单"的业务，须同步解除该声明并在重构方案记录。

## 6. 2.2 动作清单与冻结事项

| # | 事项 | 性质 | 落点 | 回归（`13c`） |
| --- | --- | --- | --- | --- |
| 1 | `RolePermission` 拆分出 `Permission`（I-C12） | 结构变更（域内） | `11c`、字典、ER 总图、`baseline_c.sql` | §4.5 等价断言与负例 |
| 2 | 补 `UQ_PurchaseOrder_replenishment_suggestion_id`（I-C13） | 候选码声明（域内） | `11c` | §5.6 负例 |
| 3 | 其余 8 表 | **无需结构变更**（R6-15 口径记录） | — | 兼容断言沿用第一阶段口径 |
| 4 | 冻结事项 A | `RolePermission.status` 语义在字典写死为"映射行状态" | 字典 §0/§9 | — |
| 5 | 冻结事项 B | 白名单 `CHECK` 随拆分迁至 `Permission`；`I-C10` 表述同步 | 字典、`c-issues.md` | 白名单覆盖断言随 §4.5 |

**不做的事项**（论证已给出，不留悬念）：引入供应商（I-C07，范围外）；物化可售量（I-C01，§5.3）；为多态引用建三列外码（I-C02，§5.4）；为 `AuditLog.detail_json` 建 EAV 明细（§3.10，仅在出现"按明细检索"需求时另行评估）；把 `job_code` 与角色合并（§5.1）。

## 7. 验证记录（人工核对）

本文由 AI 辅助起草、由成员 C 逐项人工核对并修正；核对口径与最终结果：

1. **结构事实对账（脚本）**：§2 的 56 行属性与键清单与 `sql/03_inventory_security_schema.sql` 逐项比对（表名、列名、类型、可空性、主键 / 唯一键 / 外键 / 默认值约束名、`IDENTITY`、过滤唯一索引），并与 `sql/06` 的 15 条命名 `CHECK`（均为批次 1）交叉核对——**最终 0 差异**；脚本与关键轮次输出（首轮差异、判据缺陷轮、末轮 0 差异）归档于 `result/stage2/c-normalization-check-2026-10-15.txt`。
2. **与 ER 子图核对**：`docs/er/c-inventory-security.drawio`（`.svg` 由同一生成器同源产出）的 10 张 C 域实体与主键标注逐表比对一致。
3. **交叉引用与种子统计（脚本）**：引用的 `R6-xx` 在 `source-requirements.md` 存在、`I-Cxx` 在 `c-issues.md` 存在（含本次新增的 I-C12 / I-C13）、`CK_*` 在 `06` 存在；`09c` 种子按源码重算（52 行授权、46 个权限码、每码名称唯一、每码均在白名单且至少被授予一次）与本文结论一致；`permission_name` 的引用面检索（仅 `03` / `09c`）与 §4.5 一致。
4. **核对中实际发现并修正的问题**：① §2「可空列」计数笔误（9 → 8，按源码重算纠正）；② §1「主键兼外键」改为更准确的「1:1 共享标识（`Inventory.ingredient_id`）」；③ §4.5 的检索范围表述收紧。另有**对账脚本自身**的两处判据缺陷（跨行 `FOREIGN KEY … REFERENCES` 定义漏识别，一度把 16 条外键误报为 15；批次 1 边界误取文件首个 `GO`）在过程中修正后复跑——以上全部记录于归档日志。依赖与范式判定（§3、§4.3、§4.4）由人工逐表复推复核。
