# C 域（库存·补货·权限）v0.1 问题与保留清单（c-issues）

> 属主：成员 C（计划 §7.1）。结构：每项含 ID、业务规则、当前对象、复现证据、保留 / 改动建议与影响对象。跨域条目另以 `OI-*` 编号登记到 `docs/stage2/open-issues.md`，本文件只引用不另维护状态。
>
> 事实基础：`sql/run_all.sql` 于 2026-10-13 从空库部署的 v0.1 活库目录（`sys.tables` / `sys.columns` / `sys.key_constraints` / `sys.foreign_keys` / `sys.indexes`），以及第一阶段的回归证据（`t3`–`t10b`、`09c`/`09d` 断言、`08`)。对应教学要求 R5-02、R5-03、R5-11。

## 1. 整理现有设计（C 域 10 表）

| 表 | 一行的业务含义 | 主码 | 候选标识 / 唯一键 | 外码 → 引用 |
| --- | --- | --- | --- | --- |
| `AuditLog` | 一条操作审计记录（谁、何时、对哪个实体做了什么） | `audit_log_id` | 无声明式候选码（事件行） | `employee_id`（非空）→ `EmployeeAccount` |
| `Inventory` | 某原料的**当前库存快照**（一行恒等于一种原料；PK 即 FK） | `ingredient_id`（PKFK） | 主码即候选（1:1 共享标识） | `ingredient_id` → `Ingredient` |
| `InventoryMovement` | 一次库存变动**流水**（一行 = 一种原料的一次变动，不合并） | `inventory_movement_id` | 无（事件行） | `ingredient_id` → `Inventory`；`reference_id` 为多态引用、无外码（I-C02） |
| `ReplenishmentSuggestion` | 对一种原料的一次补货建议及其审批链（提交 / 审批 / 驳回人） | `replenishment_suggestion_id` | 「每原料至多一张开放建议」过滤唯一（I-C03） | `ingredient_id` → `Ingredient`；`created_by` / `submitted_by` / `approved_by` / `rejected_by` → `EmployeeAccount`（后三可空） |
| `PurchaseOrder` | 一次审批产生的一张采购单 | `purchase_order_id` | `purchase_order_no` 唯一 | `replenishment_suggestion_id` → `ReplenishmentSuggestion`；`approved_by_employee_id`（可空）→ `EmployeeAccount` |
| `PurchaseOrderItem` | 采购单的收货明细（一行 = 单 × 原料） | `(purchase_order_id, ingredient_id)` 复合 | 复合主码即候选 | `purchase_order_id` → `PurchaseOrder`；`ingredient_id` → `Ingredient` |
| `BusinessRole` | 一种业务角色 | `business_role_id` | `role_code` 唯一 | — |
| `RolePermission` | 角色 × 权限码的一条授权映射 | `(business_role_id, permission_code)` 复合 | 复合主码即候选；`permission_code` 单独不唯一 | `business_role_id` → `BusinessRole`；`permission_code` 受白名单 CHECK（I-C10） |
| `EmployeeAccount` | 一名员工的账号与岗位档案 | `employee_id` | `database_user_name` 唯一；`login_name` 唯一 | — |
| `EmployeeBusinessRole` | 一名员工持有一个业务角色（M:N 的关联实体） | `(employee_id, business_role_id)` 复合 | 复合主码即候选 | `employee_id` → `EmployeeAccount`；`business_role_id` → `BusinessRole`；`assigned_by_employee_id`（第二条员工外码，操作人） |

补充（对应 R5-04 的复合主码讨论）：C 域共 3 个复合主码——`PurchaseOrderItem`、`RolePermission`、`EmployeeBusinessRole`；1 个 PKFK 共享标识——`Inventory`。其余为代理键：`BusinessRole`（`role_code` 唯一）、`PurchaseOrder`（`purchase_order_no` 唯一）、`EmployeeAccount`（`database_user_name` / `login_name` 唯一）带唯一候选，`InventoryMovement`、`AuditLog` 为事件行、无候选标识。

更正（2026-10-14）：本节原将 `Ingredient` 列入 C 域 10 表并漏记 `AuditLog`。按建表位置，`Ingredient` 在 `sql/01_master_schema.sql:34`（A 域），`AuditLog` 在 `sql/03_inventory_security_schema.sql:167`（C 域）；本表已换成 `AuditLog`。表中其余对 `Ingredient` 的外码引用（`Inventory`、`ReplenishmentSuggestion`、`PurchaseOrderItem`）是跨域指向，保持不变，在 C 域子图中按灰矩形处理。

## 2. 保留项（设计合理，写明理由）

**I-C01 可售量不落列（保留）**
- 业务规则：可售量 = 现有量 − 锁定量，查询时计算。
- 当前对象：`Inventory`（4 列，无 available 列）。
- 复现证据：活库目录（2026-10-13）；`v_inventory_available` 计算列；账本勾稽断言（`t10` T1/T2）。
- 建议：保留——派生值不物化，避免"账面改了、可售量忘改"的不一致。影响：只读视图。

**I-C02 `InventoryMovement.reference_id` 多态引用不建外码（保留）**
- 业务规则：`reference_type ∈ {ORDER, PURCHASE_ORDER, ADJUSTMENT}`；前两者必填 `reference_id`，`ADJUSTMENT` 允许为空（当前过程固定写 NULL）。
- 当前对象：`InventoryMovement`（`reference_id` 可空、无 FK），两条 CHECK 保证形状。
- 复现证据：`CK_InventoryMovement_reference_type` / `CK_InventoryMovement_reference`（活库实测）；视图单据号解析断言（`t5`、`t10` T2）。
- 建议：保留——多态引用无法用单一外码表达（跨域指向 B 的 `SalesOrder` 与 C 的 `PurchaseOrder`）。影响：`v_inventory_movement_history`、`v_order_inventory_trace`。

**I-C03 开放建议的过滤唯一索引（保留）**
- 业务规则：每原料至多一张开放建议（`PENDING` / `SUBMITTED` / `APPROVED`）。
- 当前对象：`ReplenishmentSuggestion`，`UQ_ReplenishmentSuggestion_ingredient_id`（过滤条件 `WHERE suggestion_status IN (PENDING, SUBMITTED, APPROVED)`，活库实测）。
- 复现证据：过滤定义；建议状态机断言（`10c` T5/T10、`t6`）。
- 建议：保留——声明式保证 + 过程刷新，不需要额外人工检查。影响：建议创建与刷新过程。

**I-C04 采购单"恰好一条明细"由过程保证（保留，不加触发器）**
- 业务规则：审批同事务生成 1 张采购单 + 恰好 1 条明细；`PurchaseOrderItem` 主码为复合 `(purchase_order_id, ingredient_id)`，结构上允许 1..N。
- 当前对象：`PurchaseOrder` / `PurchaseOrderItem`。
- 复现证据：深度复核"采购单恰好 1 条明细"（`t6`）；`09d` 自查 `51025`；`t10b` 6)「明细多于一条被拒」。
- 建议：保留过程保证——禁止用"主表 INSERT 后立即要求已有明细"的 AFTER 触发器（会在主表行插入时即触发、早于明细插入，拒绝现有合法建单顺序）；回归保留该断言。**不改结构。** 影响：审批 / 收货过程、`regression.sql`。

**I-C05 员工实体独立保存与"双层岗位"设计（保留）**
- 业务规则：员工需独立实体（账号档案、审计主体、角色成员、骑手派单）。
- 当前对象：`EmployeeAccount`（PK `employee_id`；UK `database_user_name`、`login_name`）；`job_code` 为行政岗位，业务角色经 `EmployeeBusinessRole` 授予——两层分离。
- 复现证据：权限正反探针（`t8`、`10c` T10b/T12b/T12c）；`09c`/`t9` 成员关系断言。
- 建议：保留双层设计——数据库层按角色成员资格授权，过程内再按 `USER_NAME()` 解析并校验 `job_code`，纵深防御。影响：角色同步过程、部署模板。

**I-C06 跨域：`Delivery.rider_employee_id` 可空外码（保留）**
- 业务规则：骑手派单前为空，认领时写入真实骑手；送达终态必有骑手。
- 当前对象：`Delivery.rider_employee_id`（可空 FK → `EmployeeAccount`，由 C 的 `03` 建、B 的 `02`/`05` 使用）。
- 复现证据：`FK_Delivery_RiderEmployee`（活库实测）；B 的 `09b` 外送单闭环。
- 建议：保留。影响：B 域履约过程。

**I-C07 供应商不引入（范围决定，保留）**
- 业务规则（需求侧）：采购一律视为向门店唯一供应渠道补货，无供应商选择、比价与到货评价；`PurchaseOrder` 现 6 列、无 `supplier_id`。
- 教学原文依据：R5-03 要求对"供应商"等对象**说明业务含义并判断是否需要独立保存**——本项目判断为**不需要独立保存**。
- 复现证据：`docs/业务流程.md` 补货闭环无供应商环节；`09d` 真实收货链全程不涉及供应商。
- 建议：保留；日后按供应商统计进价与到货质量时再新增 `Supplier` 与外码，不把范围外功能伪装成已有约束问题。影响：采购域（第三阶段备查）。

**I-C08 建议快照字段的语义（保留）**
- 业务规则：`ReplenishmentSuggestion.current_qty` 是**生成时刻**的快照（供审批参考），不随库存变化刷新。
- 复现证据：`09d` 守卫 `51022`（待审建议内容 = 安全线 − 实扣量）；`10c` T5。
- 建议：保留——快照语义与订单成交价同理；如需"最新值"由视图 `v_replenishment_dashboard` 联现实时库存（视图已如此）。影响：看板视图。

## 3. 观察与 2.2 拟变更

> 本节的「拟变更」＝ 已论证、待 2.2 设计冻结后由 `11c` 执行的变更项（原注"非 v0.1 缺陷"仅适用于 I-C09…I-C11）。**I-C12、I-C13 是 2026-10-15 规范化分析的产物**，分析全文见 `docs/stage2/c-normalization.md`。

**I-C09 `job_code` 与 `BusinessRole.role_code` 的关系（2.2 函数依赖分析，2026-10-15 收口：非冗余）**
- 观察：两者取值同域（7 个岗位码）但分层存储（行政岗位 vs 数据库业务角色），一致性由过程校验而非约束。
- 结论：**语义不同层、非冗余，不做结构改动**——`job_code` 在 `EmployeeAccount` 内不决定任何非主属性；跨表不存在 `job_code → 角色集合` 的业务依赖（计划 §6.1 明确承认多业务角色员工；样例 `(i, i)` 一对一只是种子构造，不能证明依赖）。全文：`c-normalization.md` §5.1。影响：`06` 角色同步过程。

**I-C10 白名单 CHECK 的扩展是 2.2 计划变更（非缺陷）**
- `CK_RolePermission_permission_code` 白名单（46 项）将随 v1.0 新增对象在 `11c` 中扩展（分工已由 B 复核确认：白名单 / 种子归 `11c`，授权 / 签名核对归 `12_permissions.sql`）。
- 记录目的：避免把"为新增对象扩白名单"误读为 v0.1 设计缺陷。影响：`11c`、`12_permissions.sql`、必要时 `09c` 映射种子。
- **2026-10-30 更新**：随 I-C12 拆分，固定枚举 CHECK 迁至 `Permission.permission_code`（改名 `CK_Permission_permission_code`），`11c` 仍同时 ALTER 扩展 CHECK；`cust_app` 三过程不进 `RolePermission` 白名单，由 `12_permissions` 按契约 §1.5 单独核对。详见 `migration-guide.md` §5。

**I-C11 员工登录映射是部署约定（保留结构）**
- `login_name` / `database_user_name` 仅为档案字段，无声明式约束保证与服务器登录同名映射；由 2.3 的 `provision_employee.template.ps1` 与部署预检负责。影响：2.3 部署模板。

**I-C12 `RolePermission` 的部分函数依赖（2NF）——2.2 拟拆分（2026-10-15 规范化分析）**
- 业务规则：`permission_name` 是权限码的展示名，随码唯一（`permission_code → permission_name`）；而 `RolePermission` 的唯一候选码是 `(business_role_id, permission_code)`——`permission_name` 部分依赖于候选码真子集，违反 2NF；插入 / 修改 / 删除异常各附数据例。
- 当前对象：`RolePermission`（`sql/03` 建表，4 列）；白名单 `CK_RolePermission_permission_code` 在 `06`。
- 复现证据：`docs/stage2/c-normalization.md` §3.4（异常数据例）与 §4（拆分方案、无损连接与依赖保持论证、迁移影响）。
- 建议：2.2 拆分为 `Permission(permission_code, permission_name)` 与 `RolePermission(business_role_id, permission_code, status)`，白名单 `CHECK` 迁至 `Permission`；只动本域、无跨域调用者。
- 影响对象：`11c`、`13c`、`baseline_c.sql`（名称保真基线）、数据字典、ER 总图、`I-C10` 的白名单落点表述。
- **2026-10-30 冻结决议（OI-03 ①）**：保留固定枚举白名单，随拆分迁至 `Permission.permission_code`（改名 `CK_Permission_permission_code`）；`11c` 同时 ALTER 扩展 CHECK、插入新目录行、写角色映射种子；纯目录/FK 不替代白名单。详见 `migration-guide.md` §5。
- **2026-10-31 11c 已落地并实测**：Permission 53 码 / RolePermission 66 行、旧 52 行与名称保真；`sp_get_current_employee_context` 已建并验证；证据 `result/stage2/c-11c-migration-check-2026-10-31.txt`。

**I-C13 `PurchaseOrder` 候选码未在约束层声明——2.2 拟补唯一约束（2026-10-15 规范化分析）**
- 业务规则：一张建议单对应一张采购单（字典 §4），`replenishment_suggestion_id` 是业务候选码；v0.1 由"仅 `SUBMITTED` 可审批 + 无第二条生成路径"的过程状态机保证，约束层无兜底。
- 当前对象：`PurchaseOrder.replenishment_suggestion_id`（非空、无唯一约束 / 唯一索引）。
- 复现证据：`docs/库存权限数据字典.md` §4 设计要点（如实记录"约束层没有兜底"）；`c-normalization.md` §3.8 / §5.6。
- 建议：2.2 补 `UQ_PurchaseOrder_replenishment_suggestion_id`——只声明既有业务事实、不动行数据；`13c` 加负例（同建议单第二张采购单被 `2601/2627` 拒绝）。
- 影响对象：`11c`、`13c`、`baseline_c.sql`（迁移前 1:1 现场比对）。
- **2026-10-31 11c 已落地并实测**：`UQ_PurchaseOrder_replenishment_suggestion_id` 已添加；证据同 I-C12。

## 4. 跨域条目索引（状态见 `open-issues.md`）

- `OI-01` 教学原文核对（closed，2026-10-13）→ 本文件 R5/R6 条目已按原文定制。
- `OI-02` 供应商范围（closed）→ 本文件 I-C07。
- `OI-04` 包含数据库用户替代登录路径（deferred）→ 与 I-C05/I-C11 相关。
- `OI-06` `Ingredient` / `AuditLog` 域属主更正（closed，2026-10-14）→ 本文件 §1。
