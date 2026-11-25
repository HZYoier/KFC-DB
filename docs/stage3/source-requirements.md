# 第三阶段教学要求对照表（source-requirements）

> 属主：C。用途：把第三阶段第 10—13 周的教学要求编号化，作为 `run_stage3.sql`、三个域脚本、测试和报告的溯源入口。
>
> **依据与状态**：第三阶段的计划与第 10、11 周要求摘录见 `docs/stage3/three-person-implementation-plan.md` §2.1/§2.2（计划 2026-11-12 定稿）；成员 C 于 2026-11-15 按该摘录逐条复核编号与落点，**讲解原文未随仓库交付、未入仓**，因此本表记录的是“计划摘录核对”而不是“原文逐字核对”。第 12 周讲解于 2026-11-18 收到，C 按 `week12-handoff.md` 与计划 §2.3 补核 R3-01—R3-03；第 13 周讲解于 2026-11-25 收到，按原文补核 R3-04—R3-07。原文补到时只补编号/落点/状态，不改已冻结的 3.1/3.2 口径。
>
> **状态口径**：**已落点** = 已有明确文件/对象承接；**部分落点** = 对象已规划但依赖其他成员文件；**待核** = 待讲解原文确认；**注意项** = 提示性要求，随实现和测试核对。
>
> **术语映射**：教学 `procedure.sql` ↔ 我们的 `21a/21b/21c` 过程与函数脚本；`function.sql` ↔ 同上中的函数；`trigger.sql` ↔ `22b/22c`；`window_query.sql` ↔ `23a/23b`；`recursive_query.sql` ↔ `24b`；`transaction.sql` ↔ `25b/25c`；`concurrency.sql` ↔ `26a/26b/26c`。

## 1. 第 10 周（3.1，过程与函数）

| 编号 | 要求（计划摘录要点） | 本仓落点 | 主笔 | 状态 |
| --- | --- | --- | --- | --- |
| R10-01 | 销售统计过程：输入起止日期，统计订单数、销售数量、销售金额与商品销售情况；检查日期范围，正确处理无销售记录 | `sql/stage3/21b_order_programmability.sql` 的 `sp_sales_report` | B | 已落点（B 文件待交） |
| R10-02 | 库存调整过程：商品编号、调整数量、原因、操作员工编号；商品不存在、数量为零、库存不足拒绝；成功后保存新数量与调整记录 | `sql/stage3/21c_inventory_programmability.sql` 的 `sp_adjust_inventory` | C | 已落点 |
| R10-03 | 补货量函数：按当前库存、最低或目标库存算补货量；达到目标返回 0；商品不存在明确处理；不得为负 | `sql/stage3/21c_inventory_programmability.sql` 的 `fn_replenishment_qty` | C | 已落点 |
| R10-04 | 销售汇总表值函数：输入日期范围，返回商品编号、名称、销售数量、金额、订单数，可在 `SELECT` 中调用 | `sql/stage3/21a_master_programmability.sql` 的 `fn_product_sales_summary` | A | 已落点（依赖 21b 视图） |
| R10-05 | 折扣业务：按会员身份、订单金额或商品分类算折扣率与折扣金额；用函数；历史订单保存实际折扣与成交价 | `21a` 的 `fn_calculate_discount` + `SalesOrderItem.discount_rate/discount_amount`（20 合入）+ B 两条下单路径落库 | A / B / C | 部分落点（B 下单过程待交） |
| R10-06 | 整合进 v1.0；应用里已实现的替换掉；SQL Server 内完成，页面只调用 | `run_stage3.sql` 入口；A 的应用层计算清单见 `sales-semantics.md` 附录 A；A 的 `app/reports/` 报表页骨架已建；C 的补货页已接 `fn_replenishment_qty`，身份页按权限码加销售报表入口 | A / B / C | 部分落点（A/C 已接，B 统计过程待交） |
| R10-07 | 交 `procedure.sql`、`function.sql`、调用与测试脚本，覆盖正常、空值、错误编号、错误日期、非法数量、非法折扣、重复调用 | `21a/21b/21c` + `tests/stage3/{a,b,c}_programmability/` | A / B / C | 部分落点（C、A 已有，B 待交） |
| R10-08 | 区分存储过程与函数：过程做会改数据的业务，函数做计算或查询 | `docs/stage3/procedure-vs-function.md` | B | 待 B 交 |
| R10-09 | 结果记录：输入、预期、实际、错误提示、未写入不完整数据的验证 | `result/stage3/{a,b,c}-programmability-*.txt` | A / B / C | C 已补，A/B 待 |
| R10-10 | 起止日期是否含当天要说明；商品编号和日期不得写死；参数/表名/字段名与设计一致；正确与错误数据都要测 | `docs/stage3/sales-semantics.md` §1.2；所有对象参数化；测试清单固定 | A / B / C | 已落点 |

## 2. 第 11 周（3.2，触发器与窗口函数）

| 编号 | 要求（计划摘录要点） | 本仓落点 | 主笔 | 状态 |
| --- | --- | --- | --- | --- |
| R11-01 | 库存审计触发器：库存增、减、改时自动记录商品编号、调整前后数量、变化量、时间、操作类型、操作人员 | `sql/stage3/20_schema_v1_1.sql` 的 `InventoryAudit` + `22c_inventory_triggers.sql` 的 `tr_Inventory_Audit` | C | 已落点（10/0，DELETE 边界见 S3-02） |
| R11-02 | 订单完成规则触发器：状态改为完成时检查明细、商品、数量、库存、金额；不满足拒绝；已完成不得重复完成 | `sql/stage3/22b_order_triggers.sql` 的 `tr_SalesOrder_Complete_Check` | B | 待 B 交 |
| R11-03 | 排名查询：用 `RANK` / `DENSE_RANK` / `ROW_NUMBER` 按销量、金额或订单数排名，说明业务含义 | `sql/stage3/23a_window_queries.sql` 查询 1 | A | 已落点 |
| R11-04 | 累计值查询：按订单日期或商品顺序统计累计金额或数量，明确排序字段 | `sql/stage3/23b_window_queries.sql` | B | 待 B 交 |
| R11-05 | 移动平均查询：最近 3 天、3 笔或 3 个月的平均销量/金额，说明窗口范围与业务用途 | `sql/stage3/23a_window_queries.sql` 查询 2 | A | 已落点 |
| R11-06 | 交 `trigger.sql`、`window_query.sql`；测试单条插入、单条修改、多条修改、正常、非法、触发器拒绝 | `22b/22c`、`23a/23b`、`tests/stage3/{b,c}_triggers/` | A / B / C | 部分落点（A/C 部分） |
| R11-07 | 结果记录：审计记录、订单状态、排名、累计、移动平均结果与业务预期 | `result/stage3/` 各域证据 | A / B / C | 部分落点 |
| R11-08 | 触发器一次可能处理多行，不能只用一个变量存一行；结合 `inserted` / `deleted`；考虑插入、修改、删除；业务不要过重 | 计划 §5.4 评审清单；C 的 `22c` 集合处理、无游标；DELETE 边界见 S3-02 | B / C | C 已落，B 待 |
| R11-09 | 窗口函数不减少行数；累计值明确排序；移动平均说明窗口大小 | `23a/23b` 各查询的“行数前后一致”与“窗口帧”说明 | A / B | 部分落点 |

## 3. 第 12—13 周（3.3、3.4，均已核对）

| 编号 | 周次表要求（摘要） | 本仓落点 | 主笔 | 状态 |
| --- | --- | --- | --- | --- |
| R3-01 | 完成一项层级递归查询，结果层级正确 | `sql/stage3/24b_recursive_query.sql`：订单明细的套餐组件树（`SalesOrderItem.parent_order_item_id`；已有结构说明，不新增分类父级列） | B | 已落点（B 交付 2026-11-24） |
| R3-02 | 实现订单完成事务，验证提交与回滚 | `sql/stage3/25b_tx_order_completion.sql`：以 `sp_finish_production` 为事务主体，库存只经 `sp_consume_order_inventory` 实扣；补拒绝、重复调用与回滚路径 | B | 已落点（B 交付 2026-11-24） |
| R3-03 | 实现模拟补货入库事务，验证提交与回滚 | `sql/stage3/25c_tx_replenishment_receipt.sql`：提交、拒绝、重复收货不重复加库存、第二次收货失败回滚 | C | 已落点（提交 18/0、回滚 14/0，2026-11-18） |
| R3-04 | 围绕库存与补货记录完成锁等待、隔离级别、死锁实验，并验证改进方案 | `26a_isolation_experiment.sql`（A：独立实验表模拟 P，脏读/RC/RR）、`26b_order_concurrency.sql`（B：订单侧与 P×6 并发购买）、`26c_lock_deadlock_experiment.sql`（C：补货侧锁/死锁） | A / B / C | 已核对，待按 §7 新脚本与双会话证据重跑 |
| R3-05 | 两个会话的实验脚本、锁信息、运行结果与分析；能指出被锁数据、等待关系、死锁原因和解决方法 | `docs/stage3/concurrency.md` + `result/stage3/{a,b,c}-concurrency-*.txt` | C（A/B 提供段落） | 已核对，待 A/B/C 补证据 |
| R3-06 | 两笔订单同时购买同一商品 P×6，只能一单成功，另一单库存不足，最终库存 4，失败单不得完成 | `26b_order_concurrency.sql` 的并发购买场景 + `25b` 订单事务 | B | 已核对，待实现 |
| R3-07 | 阶段整理：README、代码/结果目录、阶段报告、组内分工、ai_log；教学版本 v2.0 | `README.md`、`result/stage3/`、`docs/stage3/reports/`、`docs/stage3/team-division.md`、`docs/AI使用记录.md` | A / C（各域提供） | 已核对，待收口 |

## 4. 对象与测试的溯源约定

| 对象/脚本 | 覆盖要求 | 不可省略的测试 |
| --- | --- | --- |
| `sp_adjust_inventory`（21c） | R10-02、R10-07、R10-09 | 空参数、零增量、缺原因、员工不存在、员工不匹配、非店长、原料不存在、调整后为负、成功写入、连续两次调用 |
| `fn_replenishment_qty`（21c） | R10-03、R10-07、R10-10 | 目标量为 NULL/负数、原料不存在、达到目标、低于目标、可售量为负的边界、结果非负 |
| `InventoryAudit`/`tr_Inventory_Audit`（20/22c） | R11-01、R11-06、R11-08 | 单条插入、单条修改、多条修改、只改 `updated_at`、删除、无游标/集合处理 |
| `v_settled_sales_line`/`sp_sales_report`（21b） | R10-01、R10-04、R10-07、R10-10 | 起止日期含当天、无销售、NULL/倒置日期、两类终态、套餐父行 |
| `fn_calculate_discount`（21a） | R10-05、R10-07 | 会员等级、满减边界、未知顾客、金额 NULL/0/负、品类参数无效 |
| `23a/23b` 窗口查询 | R11-03—R11-05、R11-09 | 行数不变、并列名次、窗口帧、累计排序 |
| `25c` 补货入库事务 | R3-03 | 提交、部分收货、重复收货拒绝且库存不增加、第二次收货失败回滚、无半条采购/库存/流水 |

**维护规则：**

1. 本表只记录计划摘录与落点，不复制讲解原文；原文核对后删除，不入仓。
2. 要求编号与计划 §2 保持一致；新增要求追加编号，不改旧条目。
3. 第 12、13 周条目在讲解原文到达前一律标“待核”；不得用“计划里写了”替代原文核对。
4. 对象或测试改名时同时改本表、计划 §8.1 与 `run_stage3.sql` 的检查清单。

## 5. 变更记录

| 日期 | 变更 | 提出人 |
| --- | --- | --- |
| 2026-11-15 | 首次建立：R10-01—R10-10、R11-01—R11-09 按计划摘录登记；R3-01—R3-05 标待核；补对象/测试溯源表 | C |
| 2026-11-18 | 第 12 周讲解核对：R3-01 套餐组件树（已有结构说明）、R3-02 以 `sp_finish_production` 实扣、R3-03 补重复收货拒绝；R3-04/R3-05 仍待第 13 周 | C |
| 2026-11-25 | 第 13 周讲解核对：R3-04 拆为 A 的脏读/RC/RR 与 B/C 的订单—补货锁等待、死锁；新增 R3-06 并发购买、R3-07 阶段整理；R3-01/R3-02 按 B 2026-11-24 交付改“已落点” | A / C |
