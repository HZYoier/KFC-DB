# A 域 v1.1 真库联调清单

> 属主：A。用途：`21b/22b` 与 `27_permissions.sql` 均已到齐，按本清单把 A 的对象、回归、报表页一次跑完并留证。C 已在一次性库跑过正式 v1.1（64/78、28a 52/0），本清单用于本机主库/最终演示库复核。
> 前置：`KFC_DB` 已由 `run_migration.sql` 提交 v1.0；应用停写；本机 `sqlcmd` 能连 `localhost`。
> 不在本清单里：B/C 的脚本内容、C 的 `verify_stage3.sql` 汇总、组级报告。

## 0. 文件到齐检查

- [ ] `sql/stage3/20_schema_v1_1.sql`
- [ ] `sql/stage3/21b_order_programmability.sql`（B；含 `v_settled_sales_line`、`sp_sales_report`、折扣落库）
- [ ] `sql/stage3/21a_master_programmability.sql`
- [ ] `sql/stage3/21c_inventory_programmability.sql`
- [ ] `sql/stage3/22b_order_triggers.sql`（B）
- [ ] `sql/stage3/22c_inventory_triggers.sql`
- [ ] `sql/stage3/27_permissions.sql`（C）
- [ ] `sql/stage3/run_stage3.sql`

```bash
ls sql/stage3/{20_schema_v1_1,21b_order_programmability,21a_master_programmability,21c_inventory_programmability,22b_order_triggers,22c_inventory_triggers,27_permissions,run_stage3}.sql
```

**当前到齐情况（2026-11-28）：** B 的 `21b/22b`、C 的 `27_permissions.sql` 均已交付；C 的正式 v1.1 在一次性库通过（64/78、28a 52/0、28b 8/0、28c 63/0）。本机主库已于 2026-11-28 备份后执行 `run_stage3`，得到 v1.1 / 64/78，`28a` 52/0，`verify_stage3` 123/0；证据见本节命令产物。

## 1. 备份与迁移前快照

- [ ] 先建好备份目录（例如 `D:\backup\`，不要放进仓库）
- [ ] 备份 `KFC_DB`（不要加 `WITH COMPRESSION`，Express 不支持）
- [ ] 确认仍是 v1.0、没有 v1.1 标记

```sql
BACKUP DATABASE KFC_DB
TO DISK = N'D:\backup\KFC_DB_before_v1.1_20261122.bak'
WITH INIT;

SELECT version_code, applied_at FROM dbo.SchemaVersion ORDER BY applied_at;
-- 期望只有 v0.1 / v1.0，没有 v1.1
```

## 2. 应用 v1.1

- [ ] 用 `run_stage3.sql` 一次应用；失败会整体回滚，库仍是 v1.0
- [ ] 看到收尾行：`RESULT: stage3 migration committed (v1.1 marker written; 20/21b/21a/21c/22b/22c/27).`
- [ ] 证据写到 `result/stage3/a-run-stage3-2026-11-28.txt`

```bash
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB \
  -i sql/stage3/run_stage3.sql \
  -o result/stage3/a-run-stage3-2026-11-28.txt
```

失败处理：不要重跑、不要改 C 的入口；先看 `SchemaVersion` 是否仍无 v1.1、事务是否回滚，必要时用备份恢复，再把错误原文交给对应属主。

## 3. 迁移后对象检查

- [ ] `SchemaVersion` 出现 v1.1
- [ ] A 的三个对象存在
- [ ] 视图存在且非空
- [ ] 折扣两列存在
- [ ] 权限计数为 64 / 78（v1.0 58/71 + v1.1 6/7）

```sql
SET NOCOUNT ON;
SELECT version_code, applied_at FROM dbo.SchemaVersion ORDER BY applied_at;

SELECT name, type_desc
FROM sys.objects
WHERE name IN (N'v_settled_sales_line', N'sp_sales_report',
               N'fn_calculate_discount', N'fn_product_sales_summary',
               N'tr_SalesOrder_Complete_Check', N'tr_Inventory_Audit');

SELECT COUNT(*) AS view_rows FROM dbo.v_settled_sales_line;
SELECT COL_LENGTH(N'dbo.SalesOrderItem', N'discount_rate') AS rate_col,
       COL_LENGTH(N'dbo.SalesOrderItem', N'discount_amount') AS amount_col;
SELECT (SELECT COUNT(*) FROM dbo.Permission) AS permission_codes,
       (SELECT COUNT(*) FROM dbo.RolePermission) AS role_grants;
-- 期望 64 / 78（v1.0 58/71 + v1.1 6/7）
```

## 4. A 域回归（28a）

**预检（不需要 27）：** B 的 `tests/stage3/b_programmability/run_b_stage3.py --verify-all` 会建一次性库、部署 `20/21b/21a/21c/22b/22c` 并调用 `28a`；A 已于 2026-11-25 跑过并归档 `result/stage3/a-28a-precheck-2026-11-25.txt`（28a 52/0、28b 8/0、28c 63/0），证据注明“域对象预检，不是正式 v1.1”。

- [x] `28a_stage3_regression.sql` 通过，收尾行 `RESULT: stage3-a-regression suites=3 pass=52 fail=0`（2026-11-28 主库实测）
- [ ] 单独跑 `run_a_programmability.sql`，保留三条 `RESULT` 行（27/15/10）
- [ ] 证据写到 `result/stage3/a-programmability-2026-11-22.txt`、`a-28a-2026-11-28.txt`

```bash
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB \
  -i tests/stage3/a_programmability/run_a_programmability.sql \
  -o result/stage3/a-programmability-2026-11-22.txt

sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB \
  -i sql/stage3/28a_stage3_regression.sql \
  -o result/stage3/a-28a-2026-11-28.txt
```

失败处理：先保留原始失败行和 `THROW` 文案；不要改断言分母或放宽条件。若失败点在 21b 的视图/过程，交给 B；若在 A 的函数/窗口，由 A 修。

**4b. 合并验收（28b 已到；主库 2026-11-28 已通过）**

- [x] `sql/stage3/verify_stage3.sql` 顺序跑 `28a/28b/28c`；主库 2026-11-28 实测 **123/0**（52+8+63）
- [x] 证据写到 `result/stage3/a-verify-stage3-2026-11-28.txt`

```bash
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB \
  -i sql/stage3/verify_stage3.sql \
  -o result/stage3/a-verify-stage3-2026-11-22.txt
```

`verify_stage3.sql` 由 C 维护；A 只跑并记录，失败时按 28a/28b/28c 的 `RESULT` 行定位域，不代改别域的断言。

## 5. 23a 窗口查询证据

- [ ] 在真实 `v_settled_sales_line` 上跑两条查询，结果非空（或确认区间内确实无销售）
- [ ] 证据写到 `result/stage3/a-window-2026-11-22.txt`

```bash
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB \
  -i sql/stage3/23a_window_queries.sql \
  -o result/stage3/a-window-2026-11-22.txt
```

检查截图/文本里：排名榜单的名次、移动平均的 `window_rows = 1/2/3`、行数与视图明细一致。

## 6. 报表页联调

前置：`sp_sales_report` 已创建且店长有权限；`.env` 指向 `KFC_DB`；员工登录可用（C 的 `app/auth`）。

- [ ] 启动应用：`python run.py`（或项目约定的启动方式）
- [ ] 以店长账号登录，身份页出现“销售报表”入口（C 已加权限码判断）
- [ ] `/reports/sales?start=...&end=...` 返回汇总与商品明细
- [ ] 页面数字与 `sp_sales_report` 原始结果一致，页面不重算
- [ ] 空区间显示 0/0/0 与“无已结算销售”，不报 500
- [ ] 截图存 `result/stage3/a-reports-2026-11-22/`，README 写明每张图对应的日期区间与账号

交叉核对（可选，确认过程与函数的汇总一致）：

```sql
-- 函数侧：按商品汇总
SELECT product_id, SUM(sales_amount) AS sales_amount, SUM(sold_qty) AS sold_qty
FROM dbo.fn_product_sales_summary('2026-11-01', '2026-11-30')
GROUP BY product_id
ORDER BY product_id;

-- 过程侧：看第一个结果集的 order_count/sold_qty/sales_amount
EXEC dbo.sp_sales_report @start_date = '2026-11-01', @end_date = '2026-11-30';
```

两边同区间、同口径的汇总应相等；日期换成真实售出日期，不要写死。

## 7. 应用回归与收尾

- [ ] `common` 18/0、`a_app` 9/0、`master` 36/0、`api` 12/0
- [ ] 若 C 的 `run-all.ps1` 已并入 `a_app`，跑一次七套/八套汇总并留证
- [ ] 关闭 Flask；清理本地测试登录与临时文件（口令不入库、不进证据）
- [ ] `@@TRANCOUNT = 0`；没有遗留 `Stage3IsolationLab_A`
- [ ] `result/stage3/` 的文件名用 `a-` 前缀，`.txt` 已由 `.gitattributes` 标 `-text`

```bash
./.venv/Scripts/python.exe tests/stage2/common/run_common_tests.py
./.venv/Scripts/python.exe tests/stage3/a_app/run_a_app_tests.py
./.venv/Scripts/python.exe tests/stage2/master/run_master_tests.py
./.venv/Scripts/python.exe tests/stage2/api/run_api_tests.py
```

## 8. 证据命名与报告

- `a-run-stage3-2026-11-28.txt`：迁移入口原始输出
- `a-programmability-2026-11-22.txt`：21a + 23a 三套测试
- `a-28a-2026-11-28.txt`：A 域回归汇总
- `a-window-2026-11-22.txt`：23a 两条查询结果
- `a-reports-2026-11-22/`：报表页截图与 `README.md`（日期区间、账号角色、每图说明）

报告里只写实际跑出的数字；未跑或失败的项目如实标注，不用桩库结果冒充真库结果。
