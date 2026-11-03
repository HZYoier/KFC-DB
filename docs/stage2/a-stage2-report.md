# A 第二阶段阶段性报告：主数据域迁移与应用落地

> 日期：2026-11-01；角色：A（主数据、定价、会员）。对应提交：`9ce8971`。
> 状态：A 的 2.1 分析定稿、2.2 迁移脚本（`baseline_a` / `11a` / `13a`）与 2.3 主数据域三层已交付并自测；**真实迁移批次下的证据尚未归档**——`run_migration.sql` 仍由 C 编写。本报告只陈述 A 域，B/C 的结果见各自报告，不为全组结论背书。

## 1. 实验思路

四条取舍决定了这一轮怎么做：

1. **迁移用 `ALTER` 补，不重建表。** v0.1 已在三台机器整链验收，重建意味着 47 份证据里的对象名与验收结论全部重来。因此五个候选码以 `ADD CONSTRAINT` 补声明，`01` 的书写风格偏差（`naming.md` N-02/N-03/N-04）登记不落地。
2. **三类验证分开做，不互相冒充。** 静态核对（脚本形状、签名与契约/源码一致）证明的是「写得对」；库内实测（临时身份执行真过程）证明的是「跑得通」；应用层测试（假连接）证明的是「分层没错、参数定型没走样」。三者分母不同，报告里分开计。
3. **身份不用后门。** 过程按 `USER_NAME()` 映射 `EmployeeAccount`，验证就用临时 SQL 登录 + `role_store_manager` + 临时账户行，验完立刻删账户、撤授权。不为了好测在代码里留一个「跳过守卫」的开关——那会把越权验收变成一句空话。
4. **只认有判别力的断言。** 全绿一次不算数：人为改一条 `Baseline_Customer.current_points`、改一笔 `PointLedger.point_delta`，确认 `13a` 真的变红，再改回复跑。

## 2. 过程与产物

### 2.1 设计层（2.1 收口，2026-10-28）

- [范式分析](a-normalization.md)：A 域 **10 表 / 47 列 / 10 主键**（含 3 个复合主键）；§4 冻结三条语义——`current_points = 期初 offset + SUM(EFFECTIVE point_delta)`、`member_level_id` 是快照且停用即置空、同窗多档促销合法而 `fn_get_effective_product_price` 按 `priority DESC, rule_id ASC` 取一；§5 定稿五项候选码动作，其中 5 个 `UQ_*` 进 `11a`。
- [问题清单](a-issues.md)：I-A08–I-A12 结论定稿；[命名口径](naming.md)情形验证四项达标（35 条外键全具名）。
- README「数据库设计」五栏目（ER、依赖分析、更新异常、范式、分解方案）落稿，合并总图 25 实体 / 35 外键 / 103 判据。

### 2.2 迁移层

| 文件 | 内容 |
| --- | --- |
| [baseline_a.sql](../../sql/stage2/baseline_a.sql) | A 域 10 表 47 列采集，`batch_id` + 原键，去 `IDENTITY`、去业务约束，`public` DENY；不持事务、不切连接，嵌进 C 的同一采集事务 |
| [11a_master_migration.sql](../../sql/stage2/11a_master_migration.sql) | §1 前置校验 `53300`–`53306`（v0.1 形状 + 重复值逐条列举）；§2 五个 `UQ_*` 候选码；§3 终态复核 `53310`–`53316`；§4 四个查询/注册过程 |
| [13a_master_regression.sql](../../sql/stage2/13a_master_regression.sql) | 10 条域回归 A1–A10，`51930`/`51931` 前置夹具、`51998`/`51999` 断言失败与分母检查，非零退出 |

三份都遵守迁移协议：由 `run_migration.sql` 在外层事务内 `:r`，自身不 `BEGIN`/`COMMIT`/`ROLLBACK`、不切连接，失败由入口整体回滚并 `THROW`。

`13a` 的 10 条与设计条款一一对应：A1–A5 打五条候选码的直接 DML 反例（期望 `2627` 且约束名对得上）；A6–A7 对账变动（`current_points − SUM(EFFECTIVE)` 与基线相符、逐笔 `EFFECTIVE` 流水不变，不许用补造流水抹平 offset）；A8–A9 验停用置空与不回溯；A10 验同窗两档价取高优先级。

### 2.3 应用层

- [app/common/](../../app/common/)：`config` / `db` / `errors` / `log` / `tx` 五个模块 + 应用工厂与蓝图自动注册。`db.py` 是唯一 pyodbc 入口，参数一律经 `SqlParam` 显式定型（`p_time` 用 `SQL_SS_TIME2`，长 JSON 用 `NVARCHAR(MAX)` 不被截断）。
- [app/master/](../../app/master/) 三层：DAO 23 个包装、service 23 个业务函数（另有 10 个校验小工具）、routes 9 个实体 × 18 个动作、13 份模板（4 页 + 9 张表单）。界面全程只经过程取数，**未给任何岗位开基表 `SELECT`**。
- [契约 §2.4](application-contract.md)：四个 v1.0 接口的签名、返回列、错误码与授权清单落文，`GRANT` 交 C 的 `12_permissions`。
- [tests/stage2/master/](../../tests/stage2/master/)：36 条测试，把 ODBC 连接换成假连接，不连库、不需要员工账号。

### 2.4 协作

- `application-contract.md` §1 顾客端草案已合入 B 的三项决定（查单只回订单头、取餐码 20 位十六进制撞号即 `E_CONFLICT`、锁库规则全文入 §1.3）与 C 的两项决定（`530xx` 三码、`cust_app` 显式 `GRANT` 不建角色）；**§1 仍未冻结**。
- 2026-10-28 提议冻结日 2026-11-03，B 技术回执、C 于 10-31 确认，OI-03 关闭。

## 3. 本轮核验结果

| 核验 | 实际结果 | 判定方法 |
| --- | --- | --- |
| A 域模型 | 10 表 / 47 列 / 10 主键（3 复合） | 扫 `01` 的 `CREATE TABLE`，与合并总图的 25 实体 / 35 外键对照 |
| `11a` 候选码 | 5 条 `UQ_*` 全部落地，`§3` 复核无遗漏 | 本机在 v0.1 库上执行，`533xx` 守卫逐条走通 |
| `13a` 域回归 | **10 PASS / 0 FAIL**，退出码 0；重跑仍 10 PASS | 模拟 `COMPLETED` 批次 + `baseline_a/b/c` + `11a` 作夹具；两次注入破坏确认断言变红 |
| `11a` 四个新过程 | **14/14** 断言 | 临时店长 SQL 登录实测；含两个越权方向（缺 `GRANT` → `229`、岗位不符 → `51004`），以及「临时错授后过程层仍 `51004`」 |
| 主数据域测试 | **36 PASS / 0 FAIL / 0 skip**，分母硬编码 36 | `tests/stage2/master/run_master_tests.py`，假连接，无需数据库 |
| 共享访问层冒烟 | **9 PASS** | `tests/stage2/check_app_common.py`（本机 2026-11-01 复跑，B 于 10-30 归档过同口径证据） |
| 环境复原 | 25 表 / 34 键约束 / 42 过程 / 0 残留授权 / 0 残留夹具行 | 每次实测后逐项核对 |

固化测试时测出一个真缺陷：BOM 与套餐的 JSON 里直接放 `Decimal` 会让 `json.dumps` 抛 `TypeError`，任何一次合法的 BOM 保存都会在 service 层崩掉。改为按字符串绑定后，`OPENJSON ... WITH DECIMAL` 照常转换且不丢「0.500」的末位；已在临时店长身份下用真实 `sp_set_product_bom` 在回滚事务内验证。

## 4. 决策记录与边界

- **不重建表换写法。** `01` 不带 `dbo.`、关键字小写等偏差维持现状（`naming.md` N-03/N-04），风险是部署账号默认模式必须为 `dbo`，已写进部署说明。
- **重复值先列举再报错。** `11a` §1 发现重复值时 `THROW` 会带出重复的业务键，而不是让人对着约束名猜是哪一行。
- **对象已存在即报错。** `11a` 的 `53301` 守住「只跑一次」，不静默覆盖。
- **越界拒绝而非静默截断。** `@take` 只接受 1..200，超出报错；返回行数小于 `@take` 即停，不做 offset/keyset。
- **边界一：** 没有跑过真实 `run_migration.sql`。`13a` 的 10 PASS 来自本机模拟批次的夹具，不是迁移后证据；归档要等 C 串起入口。
- **边界二：** 四个新过程的 `GRANT` 尚无脚本落位。本机验证用临时授权，验完已撤；正式授权归 C 的 `12_permissions`。
- **边界三：** 契约 §1 未冻结，`sp_customer_register` **没有**写进 `11a`——避免签名一改就要改迁移脚本。
- **边界四：** `docs/stage2/user-manual.md` 未写。七岗位操作说明要等 C 的登录与启动入口、B/C 的页面成形，现在写只能编。

## 5. 可交接与下一阶段

- **给 C**：`11a` 由 `run_migration.sql` 在 `11b` 之前 `:r`；`13a` 要放在 `SchemaVersion('v1.0')` 提交之后读 `batch_id`；四个过程的 `GRANT` 清单见契约 §2.4.5；`533xx` 是 `11a` 的部署段，不进应用调用路径。
- **给 B**：收银下单页取商品价走 `sp_list_sale_products`（`@take` 1..200），但**展示价不替代订单快照**，落单金额仍由 `sp_create_order` 记录；`sp_find_customer_for_order` 无结果返回空集合而非报错；`sp_register_customer_for_order` 自身无结果集，得回查取 `customer_id`。
- **下一步（A）**：契约定 §1 并合入 OI-10 剩余四条联合边界（顾客外送凭据、下单结果未知的恢复、服务端员工凭据生命周期、`cust_app` 登录映射）；写 `user-manual.md` 的 A 域一节；真实迁移跑通后归档 `13a` 证据到 `result/stage2/`。

## 6. 补记：2026-11-03 冻结日

C 于当天交付 `12_permissions` / `13c` / `run_migration` / `regression` 与 `app/auth`、`app/inventory`，A 侧两件事随之落地：

- **OI-13 回执**：`12_permissions.sql` 的白名单行、四条 `GRANT` 与角色种子同契约 §2.4.5 逐条比对一致（`sp_list_master_records` → `role_store_manager`，其余三个 → `role_cashier`），A 侧无偏差。
- **OI-14 修复**：C 指出 `app/common/db.py` 只取首个非空结果集、且 `nextset()` 抛错时把已读到的行当成功。已拆成 `_read_sets`（按序读完、空集占位）+ `_first_non_empty`，新增 `query_procedure_sets`，`nextset` 异常一律冒泡并走 §5 映射；`query_procedure` / `execute_procedure` 语义不变，B/C 现有调用不用改。
  - 新测试 `tests/stage2/common/run_common_tests.py` **13 PASS / 0 FAIL**（两集与三集顺序、空集占位、`E_RULE`/`E_TX` 映射、出错仍关连接、非法过程名不连库）。
  - 本机临时过程实测：三集返回 `[1, 0, 1]`（中间空集未被跳过），「先 `SELECT` 后 `THROW 50000`」的过程抛 `E_RULE` 而非返回行；验完删过程，库回到 42 过程 / 25 表。
  - 待 C 把 `tests/stage2/run-all.ps1` 补上 `common` 一行，并把 `app/auth/dao.py` 的临时适配器收成一次 `query_procedure_sets` 调用。

真实迁移仍未在 A 本机跑：C 已有 `run_migration` 全回滚与临时 11b 桩的证据，完整链路等 B 的真实 `11b` 与顾客三过程。
- **OI-10 四条联合边界出提案**：契约新增 §1.7，每条给选项、代价与推荐（外送只开自取、响应丢失不伪装恢复、员工凭据采纳进程内存 8 小时并改计划口径、`cust_app` 共享非身份账户）。回执齐后 §1 冻结；未回执前 OI-10 保持 open。
