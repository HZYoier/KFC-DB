# 成员 C 第一阶段报告：库存、补货、员工权限、审计与总集成

## 1. 阶段目标

成员 C 负责把“库存锁定 → 实扣 / 释放 → 低库存补货建议 → 审批生成采购单 → 分批收货 → 回补库存”与“员工、岗位、数据库角色与最小权限”落成一套可建库、可回滚、可审计、可复现验收的关系数据库实现，并与 A 的主数据/定价接口、B 的订单履约过程联调；同时维护唯一入口 `sql/run_all.sql`，保证三域能从空库按固定顺序一次部署。

## 2. 实验思路

本实验采用“关系约束 + 过程收口 + 最小权限 + 三层验证”的方法：

1. 静态合法性交给命名 CHECK、外键与过滤唯一索引；所有库存变动只经存储过程完成（`DENY UPDATE` + `dbo` 所有权链），不向业务角色开放任何表级写权限。
2. 账本不变量先行：`locked_qty ≡ Σ locked_delta`、`on_hand_qty ≡ 期初 + Σ on_hand_delta`、库存两者永不为负、每原料至多一张开放建议；所有断言都设计成可重复执行。
3. 权限分两层：数据库层用角色 `GRANT`/`DENY` 与证书签名（`SPVC`）控制“能不能调用”；过程内再按 `EmployeeAccount.database_user_name = USER_NAME()` 解析员工并校验业务角色，形成纵深防御。
4. 验证分三层：域内夹具链（A/B/C/D 四条，仓库外、一条链一个全新部署）→ 真实对象整链（18 个文件、单会话、忠实复现 `XACT_ABORT` 泄漏）→ 失败机制隔离实验（不可提交事务、`EXECUTE AS` 生命周期、`THROW`/`EXEC` 语法边界）。
5. 断言写法把“没有假绿”放在第一位：错误码 + 原始文案双核对、每条独立成批、事务包裹一律回滚、跨批次用临时表计数并在收尾用分母守卫（`THROW 51199`）抓“批次被静默作废”。
6. 跨成员的接口争议用可运行原型收敛（收货第三参数），跨域决策写进共同计划的变更记录由受影响方拍板；对象名与签名一律按契约冻结后落地。

## 3. C 域交付物

### 3.1 关系表（10 张）

`Ingredient`、`Inventory`、`InventoryMovement`、`ReplenishmentSuggestion`、`PurchaseOrder`、`PurchaseOrderItem`、`BusinessRole`、`RolePermission`、`EmployeeAccount`、`EmployeeBusinessRole`；另对 B 的 `Delivery.rider_employee_id` 建立可空外键。

### 3.2 业务过程（15 个）

- 库存与补货：`sp_adjust_inventory`、`sp_refresh_replenishment_suggestion`、`sp_create_repl_sugg`、`sp_update_repl_sugg`、`sp_submit_repl_sugg`、`sp_approve_repl_sugg`、`sp_reject_repl_sugg`；
- 订单库存接口（B 经所有权链调用）：`sp_lock_order_inventory`、`sp_release_order_inventory`、`sp_consume_order_inventory`；
- 角色同步（证书签名 + 动态 SQL 提权）：`sp_assign_employee_business_role`、`sp_revoke_employee_business_role`、`sp_update_employee_status`；
- 审计（三域共用）：`sp_write_audit_log`；
- 采购收货：`sp_receive_inventory`（第三参数 `@received_qty DECIMAL(12,3) = NULL`，省略即收齐未收数量、传正数实现分批收货）。

### 3.3 查询与视图

四个视图：`v_inventory_available`、`v_inventory_movement_history`、`v_replenishment_dashboard`、`v_order_inventory_trace`；三条具名查询：低库存原料、指定订单的库存流水、待审批补货建议。

### 3.4 权限与证书（`08_roles_permissions.sql`）

7 个业务角色 + 7 个不带登录的 `test_*` 用户 + 受控启动引导 + 52 条精确到过程/视图的 `GRANT` + 21 行 `DENY`（`Inventory` 表、`SalesOrderItem.unit_price`、`Customer.current_points`）+ 数据库主密钥、证书 `cert_role_sync` 与三个角色同步过程的签名；连跑两遍完全幂等。

### 3.5 种子、验收与总集成

`09c`（权限与期初库存，含两种“压线”原料）、`09d`（订单后补货与两次收货）、`10c`（集成与权限验收，17 条断言）、唯一入口 `sql/run_all.sql`（18 个文件固定顺序）、`docs/库存权限数据字典.md`。

## 4. 实验环境

| 项目 | 值 |
| --- | --- |
| 日期 | 2026-10-01 |
| SQL Server | 17.0.1000.7，Express Edition (64-bit)，兼容级别 170 |
| 实例 | `.\SQLEXPRESS` |
| 认证 | Windows 身份验证（部署登录为实例 sysadmin） |
| 工具 | `sqlcmd` 17 + ODBC Driver 18；执行一律带 `-C -f 65001` |

## 5. 实验过程

### 5.1 空库部署与整链验收

删除本机测试库后，在仓库根目录仅执行：

```bat
sqlcmd -S ".\SQLEXPRESS" -E -C -f 65001 -i sql/run_all.sql
```

18 个文件按 `00 → 01 → 02 → 03 → 04 → 06 → 05 → 07a → 07b → 07c → 08 → 09a → 09c → 09b → 09d → 10a → 10b → 10c` 一次部署：`exit=0`、零错误消息；三条验收 `RESULT` 为 `13/13`、`15/15`、`17/17`，加 B 种子自检共 46 条 `PASS:`。（`04` 在 `06` 之前打印的 11 条“取决于缺少的对象”为冻结顺序下的已知编译告警，非错误。）

### 5.2 库存与补货闭环

锁库（单品与套餐经 `ComboComponent → 子项 → ProductBom` 展开、同原料聚合一条流水）、释放、实扣与低库存建议在同一事务链上验证；建议经 `PENDING → SUBMITTED → APPROVED/REJECTED`，审批同事务生成恰好一条明细的采购单；收货允许 `APPROVED → PARTIALLY_RECEIVED → CLOSED` 分批迁移，收齐即关闭建议并回补库存。`09d` 用 B 的三笔真实种子订单建立终态（守卫 + 单事务提交/审批/两次收货 + 自查）；仓库外 `t10`（9 条）与 `t10b`（18 条边界：超量/零/负数、越权 229 与过程内纵深防御、伪造员工、已关闭单据、明细不唯一、缺库存行、已收齐、两参数兼容路径）全部通过。

### 5.3 事务与失败路径

所有“故意抛错”的断言统一按 `ROLLBACK` → `REVERT` → `THROW` 收尾：隔离实验证实不可提交事务（`XACT_STATE() = -1`）中 `REVERT` 会被拒（Msg 3930）并掩盖原始错误，而 `ROLLBACK` 允许且回滚后模拟身份仍在。会话级 `SET XACT_ABORT ON`（由 `02` 泄漏）会把“期望失败”的调用也变成 doomed 事务，因此负例一律各自成批；`THROW` 的 message 位与 `EXEC` 的实参位不接受表达式（Msg 102，整批不编译），一律先算进变量。

### 5.4 权限与跨域联调

权限白名单 46 项（36 过程 + 10 视图）与 `09c` 的 `RolePermission` 双向差集为空；以 `EXECUTE AS USER` 做正反探针：越权执行得 229、越权直改敏感字段得 229、骑手确认他人配送单得 52702、合法岗位调用全部成功。跨域接口争议以可运行原型收敛（`sp_receive_inventory` 保留原两参数并新增可选第三参数），由 B 采纳并同步契约与签名检查器；契约 §8 四项待确认在收尾时全部转为已确认结论。

### 5.5 回归与最终复验

四条夹具链全量回归 144 条断言 0 FAIL（`t3` 的 14 条按设计以不可提交事务收尾、无 `RESULT` 行）；`08` 连跑两遍幂等；`09c` 重跑被守卫 `THROW 51001` 拒绝。B 合并四个文件并收尾后，我复核了他对 `10c` 的扩充（+131/-4 行、825 行全 CRLF）并在本环境重跑全链——`10c` 由 15 条增至 **17 条**，数字与 B 环境完全一致。

## 6. 实验结果

| 项目 | 结果 |
| --- | --- |
| 空库整链部署 | `exit=0`，0 条错误消息 |
| 验收断言 | A `pass=13 fail=0`、B `pass=15 fail=0`、C `pass=17 fail=0`；共 46 条 `PASS` |
| 域内夹具链回归 | 144 条断言 0 FAIL；`08` 两遍幂等；`09c` 重跑被 `51001` 拒绝（预期） |
| 库存账本 | 锁定量/现有量两向勾稽成立，库存永不为负；锁定、释放、实扣、收货流水按单据可追溯 |
| 最小权限 | 越权直改敏感字段 229、越权审批 229、骑手跨单 52702；`DENY` 只对直接 DML 生效 |
| 对象清点 | 25 表（均含主键）/ 35 外键 / 51 CHECK / 42 过程 / 10 视图 / 7 业务角色 / 52 条精确 GRANT |
| 跨域接口 | 契约检查器 PASS（含收货可选参数的精度与默认值断言） |

## 7. 实验结论

成员 C 的第一阶段目标已经完成。库存与补货的每一步（锁定、释放、实扣、建议、审批、分批收货）都可追溯、可回滚、可审计；岗位最小权限在数据库角色与过程内校验两层上均有正反证据；三域从空库一次部署的能力已在本机与成员 B 的环境上分别复现，结论一致。

原始证据全部随仓库归档在 [`result/`](../result/README.md)：B 环境见 `stage1-full-test-2026-10-01.txt` 等文件；本环境见 `stage1-full-test-c-2026-10-01.txt`（整链）、`stage1-receiving-invariants-c-2026-10-01.txt` 与 `stage1-receiving-boundaries-c-2026-10-01.txt`（收货链断言）和 `stage1-regression-c-2026-10-01.txt`（回归汇总），均可按 `result/README.md` 的 SHA-256 逐字节核对。结论摘要另见[第一阶段测试报告](stage1-test-report.md) §9「独立复验（成员 C）」。

