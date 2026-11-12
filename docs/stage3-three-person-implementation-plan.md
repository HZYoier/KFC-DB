# 第三阶段三人协作实施计划

**Goal:** 在 v1.0 数据库和应用的基础上，把补货、订单完成、库存调整、折扣与销售统计落实为可复用的存储过程和函数，用触发器自动维护库存审计与订单完成规则，用窗口函数和递归查询完成经营分析，并用两个可运行业务事务和一组并发实验说明提交、回滚、锁等待、隔离与死锁。

**Architecture:** 沿用前两阶段的业务线——A 主数据、定价与会员，B 订单、支付与履约，C 库存、补货、权限与集成。第三阶段不改这条线，改的是"业务规则放在哪里"：原先散在页面层或过程里的计算下沉为数据库对象，页面只负责取参、调用和展示；数据库结构只做加法，形成 v1.1。

**Spec:** 教学安排《第三阶段 · 第 10—13 周 数据库编程与事务处理》的第 10 周、第 11 周两份讲解（2026-11-12 收到），以及同一份阶段安排里的周次表。第 12、13 周的详细讲解尚未收到，本计划按周次表推导这两周的任务，并在 §2 中标注为待核项；讲解原文按前两阶段约定不归档，C 核对后只保留编号化摘录。

## 0. 阶段目标与四个子阶段

第三阶段按教学周次分成四个子阶段。每周的产出都要能独立运行、独立验证，后一周不替前一周补作业。

| 子阶段 | 周次（按 2026-11-09 起算） | 目标 | 主要产出 | 收敛日 |
| --- | --- | --- | --- | --- |
| 3.1 存储过程与函数 | 第 10 周（11-09—11-15） | 销售统计、库存调整、补货量、销售汇总、折扣五类业务全部由数据库对象实现，页面只调用 | `procedure.sql` / `function.sql` 对应脚本、逐项调用与正反例、结果记录 | 2026-11-15 |
| 3.2 触发器与窗口函数 | 第 11 周（11-16—11-22） | 库存审计与订单完成规则由触发器保证；排名、累计值、移动平均三类查询有明确业务含义 | `trigger.sql`、`window_query.sql`、多行批量测试 | 2026-11-22 |
| 3.3 递归查询与业务事务 | 第 12 周（11-23—11-29） | 完成一项层级递归查询；订单完成与补货入库两个事务各有提交与回滚证据 | `recursive_query.sql`、两项事务脚本与运行结果 | 2026-11-29 |
| 3.4 并发控制 | 第 13 周（11-30—12-06） | 用两个会话观察锁等待、隔离级别与死锁，并验证改进方案 | 双会话脚本、锁信息、运行结果与分析 | 2026-12-06 |

日期以课表为准；本计划写于第 10 周周四（2026-11-12），3.1 只剩四天，优先级是"五个对象先全部可调用"，测试与文档在 11-15 前补齐，不把 3.1 的尾巴拖进 3.2。

**版本口径。** v1.0 是第二阶段的交付（26 张表——25 张业务表 + 权限目录 `Permission`、15 个 v1.0 过程、58 个权限码、71 行角色授权）。第三阶段对 v1.0 只做加法：新增一张库存审计表、给订单明细补两个折扣快照列、新增过程/函数/触发器与相应权限，不改既有业务列的语义、不重写存量数据、不删表删库。完成后的结构记为 **v1.1**，由 `SchemaVersion` 新增一行标记；v1.0 标记与基线批次保留不动，供回归对照。

只做加法的原因很实际：v1.0 的 38 条回归和 118 条应用测试是第二阶段的验收证据，第三阶段每加一个对象都要证明它们仍然全绿；如果顺手改表语义，就要同时重做基线、回归和页面映射，第四周的并发实验会被返工拖垮。确实需要改既有对象时只在三处开口：`sp_adjust_inventory` 的复核升级（C）、`sp_create_order` 与 `sp_customer_place_order` 的折扣落库（B），三处都要在 3.1 开工冻结时写明影响面。

### 0.1 周度责任矩阵

| 子阶段 | A | B | C |
| --- | --- | --- | --- |
| 3.1 过程与函数 | 折扣函数、销售汇总函数、口径文档、应用层计算清单 | 已结算视图、销售统计过程、`procedure-vs-function.md`、两条下单路径折扣落库 | 库存调整复核、补货量函数、v1.1 结构脚本、入口骨架 |
| 3.2 触发器与窗口 | 排名查询、移动平均查询、报表页 | 订单完成触发器、累计值查询、旧夹具排查 | 审计表与库存触发器、审计查询页、权限脚本 |
| 3.3 递归与事务 | 销售口径复核、金额/折扣断言素材 | 递归查询、订单完成事务 | 补货入库事务、`verify_stage3.sql` 骨架 |
| 3.4 并发控制 | 隔离级别实验与段落 | 订单侧第二会话与影响分析 | 锁等待/死锁实验、改进方案、`concurrency.md` 汇总 |
| 收口 | 组级报告、README/手册、总索引 | 成员报告、过程/函数说明定稿 | 版本/权限/测试报告、迁移与回归总入口 |

## 1. 第三阶段新增的全局约束

前两阶段的约束继续有效，第三阶段另有几条：

- **业务计算只留在数据库。** 折扣率与折扣金额、补货量、销售汇总、排名/累计/移动平均一律由函数、过程或查询完成；页面只传参、调用、展示。现有页面若已在 Python 里算过其中任何一项，3.1 内替换掉并在提交说明里点名，不允许"数据库算一遍、页面再算一遍"。
- **触发器只做两件事：审计与不变量。** 触发器不得承载复杂业务流程、不得调用会再改本表的业务过程、不得使用游标逐行处理；一次触发可能对应多行，必须用 `inserted` / `deleted` 集合运算。库存审计触发器只写审计表，订单完成触发器只做校验与拒绝，不修改订单。
- **日期与金额口径先冻结再写代码。** 销售统计统一按"已完成订单的售卖明细"计，日期区间为起始日含、结束日含当天（实现为 `>= @start AND < DATEADD(DAY, 1, @end)`）；金额按明细行 `ROUND(unit_price * quantity, 2)` 后求和，折扣金额按行计算一次，不在汇总层二次舍入。口径写在 `docs/stage3/sales-semantics.md`，所有统计对象只读同一张已结算销售视图。
- **权限继续"目录 = 授权目标"。** 每个新过程/函数都要进 `Permission` 目录并落到 `RolePermission` 与 `GRANT`；表值函数按 `SELECT`、标量函数按 `EXECUTE` 授权。新增权限码会把 58/71 推到新的总数，第二阶段的 `13c` 断言要改成"按当前版本取期望值"（见 §8.3），不能靠删断言过关。
- **对象已存在必须报错。** 新对象用 `CREATE` 而不是 `CREATE OR ALTER`；既有过程只有三个允许以 `ALTER PROCEDURE` 显式升级：`sp_adjust_inventory`（C，补拒绝路径）、`sp_create_order` 与 `sp_customer_place_order`（B，两条下单路径写折扣快照）。三处都要在 3.0 冻结时登记影响面，并各配一组"升级前后行为一致"的回归。重跑入口靠 `SchemaVersion('v1.1')` 拦住，不靠"反正会覆盖"。
- **测试分母硬编码、skip 判失败、真库留证。** 新脚本沿用 `RESULT: pass=… fail=…` 收尾；第二阶段的 `regression` 38/0 与七套应用测试 118/0 在 v1.1 上必须继续全绿，任何一条因新对象变红都算第三阶段的返工，不算"预期变化"。
- **凭据与报文不入仓。** 并发实验用临时登录或现有测试账号，口令不打印、不写文件；事务脚本不保存支付报文。
- **错误码分段。** 业务 `THROW`：A 用 `541xx`、B 用 `542xx`、C 用 `543xx`，版本与集成用 `544xx`；测试断言用 `549xx`。沿用"断言码不当业务码"的口径，过程返回的错误文案同时保留原始编号。

## 2. 教学要求与落点

编号是本计划自建的溯源编号，C 在 `docs/stage3/source-requirements.md` 里按原文逐条核对后沿用；第 12、13 周条目先按周次表登记，标"待核"。

### 2.1 第 10 周（3.1）

| 编号 | 教学要求 | 本仓落点 | 主笔 |
| --- | --- | --- | --- |
| R10-01 | 销售统计过程：输入起止日期，统计订单数、销售数量、销售金额与商品销售情况；检查日期范围，正确处理无销售记录 | `sp_sales_report`（`21b_order_programmability.sql`） | B |
| R10-02 | 库存调整过程：输入商品编号、调整数量、原因、操作员工编号；商品不存在、数量为零、库存不足拒绝；成功后保存新数量与调整记录 | 复核并升级既有 `sp_adjust_inventory`（`21c_inventory_programmability.sql`） | C |
| R10-03 | 补货量函数：按当前库存、最低或目标库存算补货量；达到目标返回 0；商品不存在明确处理；不得为负 | `fn_replenishment_qty`（`21c`） | C |
| R10-04 | 销售汇总表值函数：输入日期范围，返回商品编号、名称、销售数量、金额、订单数，可在 `SELECT` 中调用 | `fn_product_sales_summary`（`21a_master_programmability.sql`） | A |
| R10-05 | 折扣业务：按会员身份、订单金额或商品分类算折扣率与折扣金额；用函数；历史订单保存实际折扣与成交价 | `fn_calculate_discount`（`21a`）+ `SalesOrderItem.discount_rate/discount_amount` + 两条下单路径落库（B） | A / B |
| R10-06 | 整合进 v1.0；应用里已实现的替换掉；SQL Server 内完成，页面只调用 | `run_stage3.sql` 入口；A 做应用层计算清单与替换核对，B/C 改各自页面 | A / B / C |
| R10-07 | 交 `procedure.sql`、`function.sql`、调用与测试脚本，覆盖正常、空值、错误编号、错误日期、非法数量、非法折扣、重复调用 | `21a/21b/21c` + `tests/stage3/{a,b,c}_programmability/` | A / B / C |
| R10-08 | 区分存储过程与函数：过程做会改数据的业务，函数做计算或查询 | `docs/stage3/procedure-vs-function.md` | B |
| R10-09 | 结果记录：输入参数、预期、实际、成功/错误提示、未写入不完整数据的验证 | `result/stage3/{a,b,c}-programmability-*.txt` | A / B / C |
| R10-10 | 起止日期是否含当天要说明；商品编号和日期不得写死；参数/表名/字段名与设计一致；正确与错误数据都要测 | `docs/stage3/sales-semantics.md`；所有对象参数化；测试清单固定 | A / B / C |

### 2.2 第 11 周（3.2）

| 编号 | 教学要求 | 本仓落点 | 主笔 |
| --- | --- | --- | --- |
| R11-01 | 库存审计触发器：库存增、减、改时自动记录商品编号、调整前后数量、变化量、时间、操作类型、操作人员 | `tr_Inventory_Audit` + `InventoryAudit`（`22c_inventory_triggers.sql`、`20_schema_v1_1.sql`） | C |
| R11-02 | 订单完成规则触发器：状态改为完成时检查明细、商品、数量、库存、金额；不满足拒绝；已完成不得重复完成 | `tr_SalesOrder_Complete_Check`（`22b_order_triggers.sql`） | B |
| R11-03 | 排名查询：用 `RANK` / `DENSE_RANK` / `ROW_NUMBER` 按销量、金额或订单数排名，说明业务含义 | `23a_window_queries.sql` 第一条 | A |
| R11-04 | 累计值查询：按订单日期或商品顺序统计累计金额或数量，明确排序字段 | `23b_window_queries.sql` | B |
| R11-05 | 移动平均查询：最近 3 天、3 笔或 3 个月的平均销量/金额，说明窗口范围与业务用途 | `23a_window_queries.sql` 第二条（按商品最近 3 笔，供补货参考） | A |
| R11-06 | 交 `trigger.sql`、`window_query.sql`；测试单条插入、单条修改、多条修改、正常、非法、触发器拒绝 | `22b/22c`、`23a/23b`、`tests/stage3/{b,c}_triggers/` | A / B / C |
| R11-07 | 结果记录：审计记录、订单状态、排名、累计、移动平均结果与业务预期 | `result/stage3/` 各域证据 | A / B / C |
| R11-08 | 触发器一次可能处理多行，不能只用一个变量存一行；结合 `inserted` / `deleted`；考虑插入、修改、删除；业务不要过重 | 触发器的多行测试与实现评审清单（§5.4） | B / C |
| R11-09 | 窗口函数不减少行数；累计值明确排序；移动平均说明窗口大小 | 三条查询各配"行数前后一致"与"窗口帧"说明 | A / B |

### 2.3 第 12—13 周（3.3、3.4，待核）

| 编号 | 周次表要求 | 本仓落点 | 主笔 |
| --- | --- | --- | --- |
| R3-01 | 完成一项层级递归查询，结果层级正确 | `24b_recursive_query.sql`：订单明细的套餐组件树 | B |
| R3-02 | 实现订单完成事务，验证提交与回滚 | `25b_tx_order_completion.sql` | B |
| R3-03 | 实现模拟补货入库事务，验证提交与回滚 | `25c_tx_replenishment_receipt.sql` | C |
| R3-04 | 围绕库存与补货记录完成锁等待、隔离级别、死锁实验，并验证改进方案 | `26a_isolation_experiment.sql`（A）、`26c_lock_deadlock_experiment.sql`（C） | A / C |
| R3-05 | 两个会话的实验脚本、锁信息、运行结果与分析；能指出被锁数据、等待关系、死锁原因和解决方法 | `docs/stage3/concurrency.md` + `result/stage3/c-concurrency-*.txt` | C（A/B 提供各自会话与分析） |

## 3. 分工原则

**域主不变。** A 继续管主数据、定价、会员与销售口径，B 管订单、支付、履约与递归展开，C 管库存、补货、权限、审计与总集成。第三阶段的对象都长在各自的表和过程上，换人等于重读别人的业务规则。

**一个对象只有一个主人。** 合并类产物（`run_stage3.sql`、`verify_stage3.sql`、`27_permissions.sql`、并发分析文档、测试汇总）由 C 主笔；其余两人只提交自己域内的脚本和证据，不直接改合并后的文件。应用层按现有 `app/<域>/` 分目录，新增的销售报表页由 A 建，菜单入口由 C 在其属主的模板里加。

**契约与口径归 A，过程与函数的分界归 B，版本与权限归 C。** A 写 `sales-semantics.md`（已结算口径、折扣政策、日期边界）并统一 README/操作手册；B 写 `procedure-vs-function.md`，把每个对象为什么是过程/函数讲清楚；C 写 `source-requirements.md`、`concurrency.md`、`test-report.md` 与阶段分工一页。

**跨域调用只经冻结签名。** A 的折扣函数被 B 的下单过程调用，B 的已结算销售视图被 A/C 的统计查询读取，C 的补货函数被补货页面调用——调用方只按冻结签名写，改动签名先改契约、再改调用方，不在一处偷偷加参数。

## 4. 子阶段 3.1：存储过程与函数（第 10 周）

| 成员 | 负责范围 |
| --- | --- |
| A | `fn_calculate_discount`、`fn_product_sales_summary`；`sales-semantics.md`；折扣快照的需求与验收；应用层"已实现计算"清单的第一遍排查；A 域测试 |
| B | `v_settled_sales_line`（已结算销售视图）、`sp_sales_report`；`procedure-vs-function.md`；折扣在 `sp_create_order` / `sp_customer_place_order` 两条路径的落库与分币分摊；B 域测试 |
| C | 复核并升级 `sp_adjust_inventory`；`fn_replenishment_qty`；`20_schema_v1_1.sql`（与 A/B 对齐列）；`run_stage3.sql` 骨架；C 域测试 |

### 4.1 先冻结一张已结算销售视图（B）

所有统计对象共用同一份口径，避免"销售统计过程算已支付、表值函数算已完成、窗口查询又换一种"：

`v_settled_sales_line`（B 属主，`21b_order_programmability.sql` 内创建）列：`order_id`、`order_no`、`completed_at`、`product_id`、`product_name`、`category_id`、`quantity`、`gross_amount`、`discount_amount`、`net_amount`。过滤条件固定为：`SalesOrder.order_status IN ('PICKED_UP', 'COMPLETED')`、`SalesOrderItem.item_role = 'SELLABLE'`、`quantity > 0`、`completed_at IS NOT NULL`；`gross_amount = ROUND(unit_price * quantity, 2)`，`net_amount = gross_amount - discount_amount`。这里必须同时收两个终态：本库自取订单的终点是 `PICKED_UP`（`sp_pick_up_order` 写 `completed_at`），配送订单的终点才是 `COMPLETED`（`sp_confirm_delivery` 写 `completed_at`）；只认 `COMPLETED` 会把自取销售全部漏掉。套餐按售卖父项计一行，组件不计收入；需要制作量时由递归查询另算（3.3）。

这张视图是 3.1 的第一个依赖：A 的函数和 B 的过程都读它，C 的移动平均（若引用销售）也读它。视图签名冻结后，统计口径的争议只在 `sales-semantics.md` 里改，不在三条 SQL 里各改各的。

### 4.2 A：折扣函数与销售汇总表值函数

**`fn_calculate_discount(@customer_id BIGINT, @order_amount DECIMAL(10,2), @category_id BIGINT = NULL)`** 返回表 `(discount_rate DECIMAL(5,4), discount_amount DECIMAL(10,2))`。默认政策：

- 会员身份：按顾客当前等级的 `level_name` 取——`N'金卡会员'` 0.95、`N'银卡会员'` 0.98、其余或无等级 1.00，等级 `status <> 'ACTIVE'` 按普通处理；不写死 `member_level_id`；
- 订单金额：`@order_amount >= 100.00` 时在会员折扣上再减 0.02；
- 折扣率下限 0.90，上限 1.00；`discount_amount = ROUND(@order_amount * (1 - discount_rate), 2)`；
- 顾客不存在或金额为 NULL 时返回 1.00 / 0.00，不抛错——调用方（下单过程）本来就应先校验顾客；函数不替过程做存在性裁决；
- `@category_id` 预留分类折扣，本期不启用，文档写明"参数存在但不改变结果"，避免为了演示硬编码分类 ID 或分类名。

历史快照：`SalesOrderItem` 新增 `discount_rate DECIMAL(5,4) NOT NULL DEFAULT (0)` 与 `discount_amount DECIMAL(10,2) NOT NULL DEFAULT (0.00)`（B 在 `20_schema_v1_1.sql` 里加列，A 提供语义）。B 在两条下单路径 `sp_create_order`（员工代下单）与 `sp_customer_place_order`（顾客自助，v1.0 已有）里都调用 A 的函数，把当时的折扣率与金额写进明细，成交价仍是 `unit_price`；两条路径的 `total_amount` 都改为按明细 `net_amount` 求和，同一份 `@items_json` 走两条路径必须得到相同的折扣与总额。订单级折扣分到行时按行金额比例分摊，分币残差落在金额最大的一行，测试断言 `SUM(SalesOrderItem.discount_amount)` 等于函数返回的订单级金额，避免"行加总差一分"。存量订单两列为 0，语义是"无折扣"，历史金额不变。

**`fn_product_sales_summary(@start_date DATE, @end_date DATE)`** 内联表值函数，返回 `product_id, product_name, sold_qty, sales_amount, order_count`，读 `v_settled_sales_line`，日期按 `completed_at` 过滤，结束日含当天。日期为 NULL 或起大于止时返回空集（表值函数不抛错），由调用过程 `sp_sales_report` 负责报 `542xx`；空区间返回空集而不是一行零，调用方自行决定是否补零行。

### 4.3 B：销售统计过程

**`sp_sales_report(@start_date DATE, @end_date DATE)`**：

- 参数校验：NULL → `54201`；`@start_date > @end_date` → `54202`；错误文案带上两个日期；
- 第一个结果集：一行汇总（`order_count`、`sold_qty`、`sales_amount`），无销售时返回 0/0/0 而不是空集；
- 第二个结果集：按商品分组的 `product_id, product_name, sold_qty, sales_amount, order_count`，按金额降序、商品编号升序稳定排序；
- 只读，不建临时表；不写死商品编号、日期或门店；
- 供 A 的销售报表页与 A 的表值函数交叉核对：同一区间、同一口径下，过程汇总与函数逐商品求和必须相等，测试里直接断言这一点。

### 4.4 C：库存调整复核与补货量函数

**`sp_adjust_inventory` 复核。** 既有过程已具备参数（原料、增量、员工、原因）、非零校验、员工身份与店长角色校验、行锁与流水写入。3.1 只做三件事：① 对照本周要求逐条核对"原料不存在、增量为零、库存不足"的拒绝路径，缺哪条补哪条，错误码统一到 `543xx`；② 复核成功后确实写入新数量与 `InventoryMovement`，审计由 3.2 的触发器接管数量快照，过程不再重复写数量审计；③ 补"重复调用"测试（同一调整连做两次，第二次基于新值计算，结果可预期）。不改签名、不改调用方。

**`fn_replenishment_qty(@ingredient_id BIGINT, @target_qty DECIMAL(12,3), @min_qty DECIMAL(12,3) = NULL)`** 返回 `DECIMAL(12,3)`：

- 当前量取"可售量"= `on_hand_qty - locked_qty`，与库存看板一致；文档写明不用账面在库量；
- 需求目标 = `COALESCE(@target_qty, @min_qty)`；两者都为 NULL 返回 NULL；
- 当前量已达到或超过目标返回 0；否则返回差值，保留 3 位小数，结果永不为负；
- 原料不存在返回 NULL（标量函数不抛错），由补货页面/建议过程按 `543xx` 拒绝；不接受负的目标量，负数按 NULL 处理并在文档中说明。

### 4.5 整合与"替换原实现"核查（A 牵头）

教学要求"应用里已经实现的替换掉"。3.1 开工时 A 对 `app/` 做一遍只读排查，列出所有在 Python 里算的业务值（金额、折扣、汇总、可售量、补货量），逐条标注"已在数据库 / 只在页面展示 / 仍在 Python 计算"。仍在 Python 的由属主在本周内改为调用数据库对象，A 只汇总清单与验收，不直接改 B/C 的模块。清单与结论进 `docs/stage3/sales-semantics.md` 附录，作为 R10-06 的证据。

### 4.6 3.1 完成标准

五个对象（折扣函数、销售汇总函数、销售统计过程、库存调整过程、补货量函数）全部可从 sqlcmd 重复调用；正常、空值、错误编号、错误日期、非法数量、非法折扣、重复调用七类用例都有预期/实际/错误提示记录；`sp_sales_report` 与 `fn_product_sales_summary` 同区间结果一致；`sp_adjust_inventory` 在不改变签名的前提下通过原有回归；v1.0 的 `regression` 38/0 与七套 118/0 仍全绿。

## 5. 子阶段 3.2：触发器与窗口函数（第 11 周）

| 成员 | 负责范围 |
| --- | --- |
| A | 排名查询与移动平均查询（`23a`）；业务含义与窗口帧说明；报表页接入 |
| B | 订单完成规则触发器（`22b`）；累计值查询（`23b`）；触发器多行测试；既有夹具排查 |
| C | `InventoryAudit` 表与库存审计触发器（`22c`）；多行测试；审计查询页；权限与只读授权 |

### 5.1 库存审计表与触发器（C）

新增 `InventoryAudit`（`20_schema_v1_1.sql`）：

```
inventory_audit_id BIGINT IDENTITY PK
ingredient_id      BIGINT NOT NULL FK -> Inventory(ingredient_id)
before_on_hand     DECIMAL(12,3) NULL
after_on_hand      DECIMAL(12,3) NULL
delta_on_hand      DECIMAL(12,3) NOT NULL
before_locked      DECIMAL(12,3) NULL
after_locked       DECIMAL(12,3) NULL
delta_locked       DECIMAL(12,3) NOT NULL
operation_type     VARCHAR(10) NOT NULL   -- INSERT / UPDATE / DELETE
operated_by        VARCHAR(128) NOT NULL  -- USER_NAME()
employee_id        BIGINT NULL FK -> EmployeeAccount
operated_at        DATETIME2(0) NOT NULL
```

`tr_Inventory_Audit` 为 `AFTER INSERT, UPDATE, DELETE`，用 `inserted` / `deleted` 全外连接逐行生成审计；过滤 `delta_on_hand = 0 AND delta_locked = 0` 的更新（只改 `updated_at` 不算库存变化）；`operated_by` 记当前数据库用户，`employee_id` 能按 `database_user_name` 解析到启用员工就填、解析不到留 NULL（直接 DML 或系统主体不阻塞业务）。触发器只写审计表，不再改 `Inventory`，因此不会递归；不使用游标。

与既有 `AuditLog` 的分工写进数据字典：`AuditLog` 记"谁做了什么业务动作"，`InventoryAudit` 记"哪一行数量从多少变到多少"；两者可以同时存在，不算重复。角色对 `InventoryAudit` 只有 `SELECT`，`INSERT` 由触发器经所有权链完成，直接 DML 仍被 `Inventory` 的表级 `DENY` 挡住。

### 5.2 订单完成规则触发器（B）

`tr_SalesOrder_Complete_Check` 为 `AFTER UPDATE`，只在"进入终态"时工作：`deleted.order_status NOT IN ('PICKED_UP','COMPLETED') AND inserted.order_status IN ('PICKED_UP','COMPLETED')`（`IF UPDATE(order_status)` 先收窄）。终态要按履约方式取：自取订单 `READY_FOR_PICKUP → PICKED_UP`，配送订单 `DELIVERING → COMPLETED`；如果只守 `COMPLETED`，自取订单的完成校验等于没做。一次 `UPDATE` 涉及多笔订单时集合处理：

1. 每笔新完成订单至少有一条 `SELLABLE` 明细；
2. 每条售卖明细 `quantity > 0`、`unit_price >= 0`；
3. `total_amount` 等于售卖明细 `SUM(ROUND(unit_price * quantity, 2) - discount_amount)`（差一分即拒绝）；
4. 订单的原料消耗流水存在（该订单有 `CONSUME` 类型的 `InventoryMovement`），且相关原料 `on_hand_qty >= 0`；没有 BOM 的商品跳过此项并在测试清单登记；
5. `completed_at` 已写入；
6. 原本已是终态的订单再次写同一个终态直接拒绝（重复完成），错误码 `542xx`。

触发器只读其它表、只抛错，不改订单、不调用过程；`sp_pick_up_order`、`sp_confirm_delivery` 的既有路径继续可用。B 在开工前排查 `10b`/`13b`/应用测试里所有"直接 `UPDATE` 订单状态到 `COMPLETED`"的夹具：能用过程的改过程，必须直写的补齐明细与流水，不能靠放宽触发器让测试变绿。

### 5.3 三类窗口查询（A / B）

三条查询都只读 `v_settled_sales_line`，都配"查询目的、排序字段、窗口帧、结果行数前后一致"的说明：

- **排名（A，`23a` 第一条）**：按商品销售金额降序，同时列 `RANK()` 与 `DENSE_RANK()`，用同额商品说明两者并列后的名次差异；用 CTE + `WHERE rk <= 10` 取前十，业务含义是"畅销商品榜"，供陈列与备货参考。
- **累计值（B，`23b`）**：按日期聚合每日销售额，再 `SUM(sales_amount) OVER (ORDER BY sale_date ROWS UNBOUNDED PRECEDING)` 求累计；排序字段固定为 `sale_date`，无销售日不补行但累计值仍正确，文档写明"累计按有销售的日期推进"。
- **移动平均（A，`23a` 第二条）**：按商品取最近 3 笔已完成订单的销售额，`AVG(net_amount) OVER (PARTITION BY product_id ORDER BY completed_at, order_id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)`；前两笔只有部分窗口，文档说明；业务用途是"近期单笔销售趋势"，为补货目标量提供参考，不直接回写补货建议。

### 5.4 触发器评审清单与完成标准

每个触发器提交前由另一人按清单复核：是否集合处理、是否使用游标、是否只做审计/校验、是否可能递归、是否考虑 INSERT/UPDATE/DELETE 三种事件、多行更新是否产生对应行数的审计或一次性拒绝、是否影响原有 38 条回归与 118 条应用测试。单条插入、单条修改、多条修改、非法数据、触发器拒绝五类测试全部留证；`InventoryAudit` 一次更新 3 行必须正好 3 条审计，订单完成触发器一次完成 2 笔订单要么全过、要么整句回滚且无半完成。

## 6. 子阶段 3.3：递归查询与业务事务（第 12 周）

| 成员 | 负责范围 |
| --- | --- |
| A | 销售口径复核与事务前置数据核对；订单完成事务的金额/折扣断言素材；A 域回归 |
| B | 递归查询（`24b`）；订单完成事务（`25b`）；提交与回滚证据；B 域回归 |
| C | 补货入库事务（`25c`）；提交与回滚证据；`verify_stage3.sql` 汇总骨架；C 域回归 |

### 6.1 层级递归查询（B）

以 `SalesOrderItem.parent_order_item_id` 自引用为树：输入一个 `@order_id`，从顶层售卖项出发递归展开套餐组件，返回层级、路径、父项、商品、数量、单价、行金额与"相对整单的展开数量"（父项数量 × 子项份数）。业务含义是配餐展开与套餐成本核算：收银只卖父项、配餐要知道实际要做几个子件。

当前种子数据只有一层套餐，且 `sp_set_combo_component` 在第一阶段明确拒绝嵌套套餐，所以真实订单里通常只有一层。B 在回滚事务里直接构造一组两层明细（父套餐 → 子套餐 → 单品）验证多级，并在文档里写明：查询按"将来允许嵌套"写，当前应用规则不产生这种数据，测试数据只用于证明递归本身正确；用 `OPTION (MAXRECURSION 10)` 防失控，并在 `WHERE` 里加路径判重防环。查询只读，不留测试数据。

### 6.2 订单完成事务（B）

`25b_tx_order_completion.sql` 用显式事务演示两条路径：

- **提交路径**：选一笔已支付/制作完成的测试订单，`BEGIN TRAN` → 调既有的取餐或送达过程 → 断言订单状态、`completed_at`、积分流水、库存流水都已落库 → `COMMIT` → 重新查询确认持久化；
- **回滚路径**：同一形状再开一个事务，过程调用成功后人为注入一次失败（例如金额断言不成立或重复完成），验证 `@@TRANCOUNT` 归零、订单状态、积分、库存流水全部回到事务前，且没有留下半条记录。

提交路径在迁移后的临时副本库上执行，避免主库测试订单被写死；回滚路径可在主库执行（不留数据）。两条路径都记录事务前后行数与关键值，脚本可重复运行。

### 6.3 补货入库事务（C）

`25c_tx_replenishment_receipt.sql` 覆盖"建议 → 采购单 → 收货"：

- **提交路径**：批准建议生成采购单，分两次收货（部分到货、全部到货），断言 `PurchaseOrder` 状态、`Inventory.on_hand_qty`、`InventoryMovement` 与建议状态同步推进，`COMMIT` 后复查；
- **回滚路径**：在第二次收货时制造失败（超收、状态不符或数量非法），验证采购单、库存、流水、建议状态全部回到事务前，部分收货也不残留。

与 6.2 一样，提交路径在临时副本上做，回滚路径留在主库；脚本记录 `@@TRANCOUNT`、受影响行数、关键数量前后值。

### 6.4 3.3 完成标准

递归结果层级正确（一层与临时两层两种数据都验证）；两个事务各有提交成功与失败回滚的原始输出；回滚后无半条订单/库存/积分/采购记录；`regression` 38/0 与七套 118/0 仍全绿；`verify_stage3.sql` 能汇总本阶段全部断言。

## 7. 子阶段 3.4：并发控制（第 13 周）

| 成员 | 负责范围 |
| --- | --- |
| A | 隔离级别实验：销售统计在 `READ COMMITTED` 与 `REPEATABLE READ` 下对并发下单的可见性差异 |
| B | 订单完成侧的第二个会话脚本与业务影响分析（完成与库存调整相遇时谁等谁） |
| C | 锁等待、死锁实验与改进方案；`concurrency.md` 汇总；全部原始输出 |

### 7.1 锁等待（C）

两个 sqlcmd 会话：会话 1 开事务调用 `sp_adjust_inventory` 锁住某原料行并 `WAITFOR DELAY`；会话 2 对同一原料发起调整，设置 `SET LOCK_TIMEOUT 3000`。用 `sys.dm_tran_locks`、`sys.dm_exec_requests` 抓被锁资源、等待类型与阻塞链，分别记录"等待后成功"和"超时失败"两种结果。分析要指出被锁的业务数据（哪一行库存）、等待关系（谁阻塞谁）、业务上是否可以接受。

### 7.2 隔离级别（A）

会话 1 在 `REPEATABLE READ` 中先读销售汇总，`WAITFOR` 后重读；会话 2 在同一区间完成一笔新订单（`COMPLETED`）。对照 `READ COMMITTED`：前者两次读一致，后者能看到新增；若数据库已启用 `READ_COMMITTED_SNAPSHOT`，另记一组快照读结果，未启用则不擅自改库设置。实验说明"报表要稳定就读高一级隔离，但会持锁更久"的取舍。

### 7.3 死锁与改进（C 主笔，B 提供订单侧会话）

构造两会话反向加锁：会话 1 先锁原料 A 再锁 B，会话 2 先 B 再 A（或订单完成与补货收货各持一半资源），触发死锁；从 `system_health` 或 `DBCC TRACEON(1222)` 抓死锁图，指出牺牲者、两个会话各持有什么、循环等待在哪。改进方案：所有涉及多原料的事务按 `ingredient_id` 升序加锁、缩短事务、失败重试；改后重跑同一脚本，两个会话都成功、无死锁。B 补一段"订单完成在该场景下的等待与失败表现"，不另写一套死锁。

### 7.4 3.4 完成标准

锁等待、隔离级别、死锁三类现象各有可复现脚本与原始输出；死锁图能读出资源与等待环；改进方案在同一脚本上验证通过；`concurrency.md` 按"现象—数据—原因—解决"四段写，C 汇总，A/B 各写自己那一段；实验全部回滚，不留锁与测试数据。

## 8. 贯穿全程的约定

- 数据字典随对象新增同步：`InventoryAudit` 进库存权限字典，折扣两列进订单履约字典；谁的域谁改，C 复核。
- 每个子阶段结束三人对一遍产出，上游签名冻结后才开下游；跨域调用方只按冻结签名写。
- 提交粒度按用途：一个提交只做一类对象或一份证据，不把三个域的脚本混在一起；动手前先拉最新。
- AI 辅助过程各记各的，并入 `docs/AI使用记录.md`；计划不写成已完成。

### 8.1 文件属主与提交素材

| 路径 | 唯一属主 | 输入与验收 |
| --- | --- | --- |
| `docs/stage3-three-person-implementation-plan.md` | A | 本计划；C 在此登记冻结日期与状态 |
| `docs/stage3/source-requirements.md` | C | 第 10、11 周讲解逐条编号（R10/R11），第 12、13 周标待核；原文核对后删除、不入仓 |
| `docs/stage3/sales-semantics.md` | A | 已结算口径、日期边界、折扣政策、应用层计算清单 |
| `docs/stage3/procedure-vs-function.md` | B | 每个对象为何是过程/函数，对照教学两组职责 |
| `docs/stage3/concurrency.md` | C | 三类并发实验的现象、数据、原因与改进；A/B 提供各自段落 |
| `docs/stage3/test-report.md`、`result/stage3/README.md` | C | 汇总执行环境、断言、证据与截图；每人证据用字母前缀 |
| `docs/stage3/team-division.md` | C | 阶段作业要求的"小组分工说明"，由本计划 §3、§4—§7 抽取一页 |
| `sql/stage3/20_schema_v1_1.sql` | C | 新增 `InventoryAudit`；B 的折扣两列在此合入，A 提供语义；只加不删 |
| `sql/stage3/21a_master_programmability.sql`、`21b_order_programmability.sql`、`21c_inventory_programmability.sql` | A、B、C 各自文件 | 各自域的过程/函数；`v_settled_sales_line` 在 `21b`；不提交外层事务 |
| `sql/stage3/22b_order_triggers.sql`、`22c_inventory_triggers.sql` | B、C 各自文件 | 订单完成校验、库存审计；集合处理，无游标 |
| `sql/stage3/23a_window_queries.sql`、`23b_window_queries.sql` | A、B 各自文件 | 排名与移动平均、累计值；配业务说明 |
| `sql/stage3/24b_recursive_query.sql`、`25b_tx_order_completion.sql` | B | 递归树与订单完成事务；提交/回滚两路径 |
| `sql/stage3/25c_tx_replenishment_receipt.sql` | C | 补货入库事务；提交/回滚两路径 |
| `sql/stage3/26a_isolation_experiment.sql`、`26c_lock_deadlock_experiment.sql` | A、C 各自文件 | 双会话脚本；固定等待与超时，输出可直接留证 |
| `sql/stage3/27_permissions.sql` | C | 新权限码、RolePermission、GRANT、目录/映射/实际授权核对 |
| `sql/stage3/run_stage3.sql`、`verify_stage3.sql` | C | 单事务入口（20→21→22→27→检查→v1.1 标记）与提交后回归汇总 |
| `sql/stage3/28a/28b/28c_stage3_regression.sql` | A、B、C 各自文件 | 本域断言、硬编码分母、精确错误码、回滚夹具 |
| `sql/stage2/13c_inventory_security_regression.sql` 中权限计数 | C | 按 v1.1 期望更新 58/71、新增 12 码与 19 行授权等断言；断言条数不变，仍 38/0 |
| `tests/stage3/{a,b,c}_programmability/`、`{b,c}_triggers/` | A、B、C 各自测试 | 假连接输入边界；分母硬编码；skip 判失败 |
| `tests/stage3/run-all.ps1` | C | 串联三套并校验分母；沿用 `RESULT: run-all files=… failed=…` |
| `app/reports/`、销售报表模板 | A | 只调用 `sp_sales_report` 与表值函数，不在 Python 汇总 |
| `app/orders/` 折扣展示 | B | 展示数据库返回的折扣率/金额，不在页面重算 |
| `app/inventory/` 审计列表与补货量展示 | C | 读 `InventoryAudit`/函数结果；不改其它域模板 |
| `app/__init__.py` 蓝图注册、菜单入口 | A 改工厂，C 改其属主模板 | A 注册 `reports` 蓝图；C 在身份页加入口 |
| 三份数据字典、`README.md`、`docs/stage3/user-manual.md` | A 汇总，各域提供字段说明 | 按域更新后 A 统一入口与索引 |
| `docs/stage3/reports/{a,b,c}-stage3-report.md`、组级 `阶段报告.md` | A、B、C 各写域；总报告 A | 设计、实现、测试、截图与证据索引 |

### 8.2 阶段门槛与顺序

1. **3.0 冻结（11-12—11-13）**：三人确认 v1.1 的加法范围（审计表、折扣两列）、折扣政策、已结算口径、触发器不变量、权限映射与文件命名；C 建 `source-requirements.md` 并标注第 12、13 周待核。未冻结不开写。
2. **3.1（11-13—11-15）**：B 先交 `v_settled_sales_line` 与 `sp_sales_report` 骨架；A 交两个函数；C 交 `sp_adjust_inventory` 复核与 `fn_replenishment_qty`；C 串 `run_stage3.sql` 骨架；三人各自跑通正反例，冻结 3.1 签名。
3. **3.2（11-16—11-22）**：C 建审计表与触发器，B 建订单完成触发器并排查旧夹具，A/B 交三条窗口查询；C 起 `27_permissions.sql`；全组跑一遍 v1.0 的 38 条回归与七套应用测试，变红先修触发器/夹具，不放宽断言。
4. **3.3（11-23—11-29）**：B 交递归查询与订单完成事务，C 交补货入库事务；提交路径在临时副本、回滚路径在主库；C 起 `verify_stage3.sql`，A 复核销售口径与金额断言。
5. **3.4（11-30—12-06）**：C 领先跑锁等待与死锁，A 做隔离实验，B 补订单侧分析；C 汇总 `concurrency.md` 与测试报告；A 出组级报告，B/C 出成员报告。
6. **收口（12-07 前）**：v1.1 迁移在干净副本上从 v1.0 一次通过；`regression` 38/0、七套 118/0、`verify_stage3.sql` 全绿；README、字典、ER 图、操作手册与 v1.1 一致。

### 8.3 版本、脚本与权限口径

- **入口**：`run_stage3.sql` 要求 `SchemaVersion('v1.0')` 存在且 `v1.1` 不存在；在一个外层事务里按 `20 → 21a → 21b → 21c → 22b → 22c → 27` 执行，事务内检查对象数、权限数、触发器数、列存在性，全部通过后写 `SchemaVersion('v1.1')` 并 `COMMIT`；任何一步失败整体回滚，库仍是 v1.0。`run_stage3.sql` 不建库、不删库、不删表、不重写存量行。
- **对象**：新过程/函数/触发器用 `CREATE`；只有 `sp_adjust_inventory`（C）、`sp_create_order` 与 `sp_customer_place_order`（B）用 `ALTER PROCEDURE`，三处都在 `run_stage3.sql` 内执行并留升级前后对照；重复执行由 v1.1 标记拒绝，已应用时只报告"已应用"，不重复创建。
- **权限**：`27_permissions.sql` 新增权限码、RolePermission 行与实际 `GRANT`（表值函数 `SELECT`、标量函数 `EXECUTE`、审计表 `SELECT`），并核对"目录 = 映射 = 实际授权"三方一致；`13c` 的 58/71、新增 12 码与 19 行授权等期望改为按版本取常量（v1.0 或 v1.1），断言条数不变。
- **回归**：`verify_stage3.sql` 顺序调用 `28a/28b/28c`，汇总实际断言数与预期分母，非零退出即失败；`regression.sql` 的 38 条继续作为"没弄坏第二阶段"的门槛，应用七套 118 条同理。
- **留证**：每个对象至少一份正例输出、一份反例输出；事务两条路径、并发三类实验各一份原始 txt；证据用 `-o` 落盘，文件名带日期与域前缀，`result/stage3/README.md` 登记 SHA-256。

## 9. 开工前置项

1. **第 12、13 周讲解未到。** 本计划的两周任务按阶段周次表推导，细节可能少于讲解原文；C 在 `source-requirements.md` 中把它们标为"待核"，原文到达后逐条补编号与落点，不改已冻结的 3.1/3.2 口径。不能拿"计划里写了"当"讲解已核对"。
2. **v1.1 三处冻结项**：审计表 vs 复用 `AuditLog`、折扣是否落两列、订单完成触发器的库存断言。默认采用本计划的方案（独立审计表、落两列、要求消耗流水）；若 3.0 冻结时改为复用 `AuditLog` 或不加列，必须同时改 `sales-semantics.md`、`20_schema_v1_1.sql` 与回归预期，不许实现到一半再换。
3. **讲解原文处理**：两份 `.docx` 在桌面，C 核对后按前两阶段约定删除原文、只留编号摘录；不要把原文或转换稿提交进仓库。
4. **环境**：SQL Server 2025、`sqlcmd -C -f 65001 -b`；并发实验需要两个终端与足够长的 `WAITFOR`；快照隔离是否启用由 A 先查 `sys.databases`，未启用就不改库设置。
5. **应用层替换清单**：A 在 3.1 开工前完成只读排查，列出仍在 Python 里算的业务值，交各属主确认；清单未清空不进 3.2。

## 10. 已知风险

**触发器最容易打坏旧回归。** 订单完成触发器会拦住所有直写 `COMPLETED` 的夹具，审计触发器会改变库存更新后的行数断言。缓解：先跑一遍不加触发器的 v1.0 回归作为基线；加触发器后逐条重跑，变红先改夹具或实现，不放宽触发器；审计与业务审计分表，避免行数互相污染。

**权限计数会牵动第二阶段的断言。** 新增权限码必然让 `13c` 的 58/71、新增 12 码与 19 行授权失效；如果直接改小分母或跳过断言，就等于用"减少检查"换绿。缓解：`13c` 按 `SchemaVersion` 取期望值，v1.0 与 v1.1 两套常量都写在脚本里，断言条数不变，证据同时给出两版的输出。

**统计口径三处各写各的。** 过程、表值函数、窗口查询都涉及"哪些订单算销售、日期含不含当天、套餐怎么算"。缓解：只读 `v_settled_sales_line` 一张视图，口径写在 `sales-semantics.md`；测试里断言过程汇总与函数逐商品求和相等。

**并发实验难复现。** 锁等待与死锁依赖时序，换机器可能等不到。缓解：固定会话脚本、显式 `WAITFOR` 与 `LOCK_TIMEOUT`、DMV 抓等待链；每类实验连跑三次，结果一致才留证；死锁优先用确定性反向加锁构造，不靠碰运气。

**第 10 周只剩四天。** 五个对象、正反例与文档要在 11-15 前收口。缓解：3.1 先保"五个对象可调用 + 七类用例"，报表页与润色放 3.2 并行；宁可少一个页面，不缺口试脚本。

**第 12、13 周要求可能比推导更细。** 讲解未到，递归查询的层级对象、事务的验收点、并发实验的期望现象都可能被补充要求改变。缓解：两周的脚本与文档留出可替换的边界（递归只换查询、事务只换脚本、并发只换会话），不把它们的结论提前写死进 v1.1 迁移。

**范围膨胀。** 第三阶段只做教学要求的对象与两个事务，不顺手加新业务表、不重做报表系统、不改前两阶段已冻结的接口。确实需要新表时先登记开放问题，三人同意后再进 v1.1。

## 11. 最终交付集（v1.1）

| 类别 | 教学交付名 | 本仓落点 | 主笔 |
| --- | --- | --- | --- |
| 过程 | `procedure.sql` | `21b_order_programmability.sql`（销售统计）+ `21c_inventory_programmability.sql`（库存调整升级） | B / C |
| 函数 | `function.sql` | `21a_master_programmability.sql`（折扣、销售汇总）+ `21c`（补货量） | A / C |
| 触发器 | `trigger.sql` | `22b_order_triggers.sql` + `22c_inventory_triggers.sql` | B / C |
| 窗口查询 | `window_query.sql` | `23a_window_queries.sql`（排名、移动平均）+ `23b_window_queries.sql`（累计） | A / B |
| 递归查询 | `recursive_query.sql` | `24b_recursive_query.sql` | B |
| 业务事务 | 订单完成 / 补货入库 | `25b_tx_order_completion.sql` + `25c_tx_replenishment_receipt.sql` | B / C |
| 并发实验 | 双会话脚本、锁信息、分析 | `26a_isolation_experiment.sql` + `26c_lock_deadlock_experiment.sql` + `docs/stage3/concurrency.md` | A / C |
| 结构 | v1.1 增量 | `20_schema_v1_1.sql` + `27_permissions.sql` + `run_stage3.sql` + `verify_stage3.sql` | C |
| 测试 | 调用与测试脚本、结果记录 | `tests/stage3/` + `result/stage3/` + `docs/stage3/test-report.md` | A / B / C，C 汇总 |
| 应用 | 页面只调用数据库 | `app/reports/`（销售报表）、订单折扣展示、库存审计/补货展示 | A / B / C |
| 文档 | 分工、口径、分界、并发、手册 | `docs/stage3/` 五份 + `docs/stage3/user-manual.md` 增补 + `README.md` | A / B / C |
| 报告 | 阶段报告 | `docs/stage3/reports/` 三份成员报告 + 组级 `阶段报告.md` | 各域；总报告 A |

表中 `sql/stage3/`、`tests/stage3/`、`result/stage3/`、`docs/stage3/` 与 `app/reports/` 都是**计划落点，尚未建立**；每个文件由表中属主在对应子阶段创建，不是当前已有链接。教学交付名与本仓文件名的对应关系以本表为准，提交时在 `test-report.md` 里再列一次，避免老师按 `procedure.sql` 找不到文件。

## 12. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-11-12 | 建立本计划：按第 10、11 周讲解与阶段周次表划出 3.1—3.4，冻结 v1.1 只做加法的范围、五个 3.1 对象、两个触发器、三类窗口查询、递归与两项事务、并发实验与文件属主；第 12、13 周条目标"待核" |

## 13. 本次设计自查

- 第 10 周六项任务（销售统计、库存调整、补货量、销售汇总、折扣、整合）全部有落点与主笔，R10-01—R10-10 无遗漏；
- 第 11 周五项任务与三条注意事项全部有落点，R11-01—R11-09 无遗漏；第 12、13 周按周次表登记 R3-01—R3-05，并明确"待核"；
- 四个子阶段各有可验收的收敛日与完成标准，上游签名冻结后才开下游；
- 每个对象/脚本只有一个属主，合并入口与权限归 C，跨域调用只经冻结签名；
- v1.1 只有加法，`run_stage3.sql` 单事务、失败回滚、重复执行被版本标记拦住，不删库不删表；
- 第二阶段的 `regression` 38/0 与七套 118/0 被写成前置门槛，权限计数改成按版本取期望值而不是删断言；
- 风险清单覆盖触发器打旧回归、权限计数、统计口径、并发复现、第 10 周时间与第 12/13 周要求缺口。
