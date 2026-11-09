# 第二阶段团队分工与交接

> 属主：成员 C（总集成）。依据：`docs/stage2-three-person-implementation-plan.md` §7.1 属主表、§6.3/§6.4 应用分工。本文只记录协作边界，不改计划正文。

## 1. 角色

| 成员 | 域 | 主要职责 |
| --- | --- | --- |
| A | 主数据、定价、会员 | 表结构/过程/视图（`01/04/07a/09a/10a`）、`baseline_a`、`11a`、`13a`、`app/common`、`app/master`、接口契约与 README |
| B | 订单、支付、配送 | 表结构/过程/视图（`02/05/07b/09b/10b`）、`baseline_b`、`11b`、`13b`、`app/orders`、订单接口与冻结回执 |
| C | 库存、补货、员工权限、审计、总集成 | 表结构/过程/视图（`00/03/06/07c/08/09c/09d/10c`）、`baseline_c`、`11c/12/13c`、`run_migration/regression`、`app/auth`、`app/inventory`、`run.py`、`tests/stage2` |

## 2. 文件属主

| 产物 | 属主 | 其他成员 |
| --- | --- | --- |
| `sql/stage1/01/04/07a/09a/10a`、`11a`、`13a`、`baseline_a` | A | 只读/复核 |
| `sql/stage1/02/05/07b/09b/10b`、`11b`、`13b`、`baseline_b` | B | 只读/复核 |
| `sql/stage1/00/03/06/07c/08/09c/09d/10c`、`11c`、`12`、`13c`、`baseline_c`、`run_migration`、`regression` | C | 只读/复核 |
| `app/common`、`app/master` | A | B/C 只读；C 的 auth 复用 Common |
| `app/orders` | B | C 只读 |
| `app/auth`、`app/inventory`、`run.py`、`tests/stage2` | C | A/B 只读 |
| `docs/stage1/*`、`docs/er/*`、`docs/stage2/*` | 按各文件头 | 共享文件按约定追加 |
| `README.md` | A 主笔 | C/B 提供域素材 |

**规则：** 一个产物一个属主；C 不代写 A/B 的 `11a/11b`、`baseline_a/b`、`app/master/orders`；A/B 不改 C 的迁移/权限/应用文件。发现跨域问题写 `open-issues.md` 或汇报用户转达。

## 3. 集成顺序

1. v0.1 部署：`sql/stage1/run_all.sql`（C 维护入口，A/B 脚本只读）。
2. 停写、备份、三域基线：`capture_baseline.sql` + `baseline_a/b/c.sql`；批次 `COMPLETED` 才可迁移。
3. 迁移：`run_migration.sql` 固定 `11a → 11b → 11c → 12`，单连接单外层事务；域脚本不 COMMIT。
4. 回归：`13a` / `13b` / `13c`，由 `regression.sql` 汇总；实际断言数入 `RESULT`。
5. 应用：`app/common` → `app/auth` → 各域页面；员工身份由数据库 `USER_NAME()` 兜底，UI 不缓存“我是谁”。

## 4. 当前交接状态（2026-11-09）

| 项 | 状态 | 下一位 |
| --- | --- | --- |
| A `baseline_a/11a/13a`、`app/master` | 已到 | C 已集成/复跑 |
| A Common 多结果集（OI-14） | 已修复，C 已改用 `query_procedure_sets` | C 已复核 |
| A Common `pooling=False`（OI-16） | 已修复，C 已复核关闭 | — |
| B `baseline_b/13b` | 已到；B orders 适配 Common，20/0 | C 已集成 |
| B 真实 `11b_order_migration.sql` | **已到并验收**：六员工查询 + place/list；真实迁移 15 过程/38 回归 | C 已复核 |
| 顾客三过程/OI-10 | **已收口**：A register + B place/list + C 12 授权；C 顾客页已落 | C/操作者做真实顾客登录部署 |
| C `11c` 58/71、`12/13c/run_migration/regression` | 已落稿；真实 11b 迁移 15 过程/3 个 `cust_app` GRANT；regression 38/0 | C |
| C `app/auth`/`app/inventory`/`app/auth/customer*`/`run.py` | 已落；auth 10/0、inventory 12/0、customer 10/0、run-all 六套 106/0 | C |
| 真实员工/顾客 SQL 登录部署 | 模板已落，**未执行**（口令由操作者输入） | C + 操作者 |

## 5. 共享约定

- 迁移协议以 `docs/stage2/migration-guide.md` 为准；接口以 `application-contract.md` 为准；访问层以 `access-layer-contract.md` 为准。
- 证据放 `result/stage2/`，SHA 入 `result/stage2/README.md`；对账/检查按 H20 三段式。
- 密码/连接串不入仓、不入日志、不写 AI 记录；员工 SQL 登录由操作者通过部署模板显式创建。
- 每次 pull 后先核对 `git log/status`、`11b` 是否到货、`KFC_DB` 状态，再决定复跑/等待。
