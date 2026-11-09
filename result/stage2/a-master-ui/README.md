# A 主数据页面截图（2026-11-09，v1.0 真实库）

> 属主：A（主数据、定价、会员）。本目录是 A 域页面的运行截图与环境说明；2026-11-08 那版是在 `11a` + `11c` 演示库上拍的，2026-11-09 本机完成 v1.0 迁移后 12 张全部重拍并覆盖。

## 环境

- 实例：`localhost`（SQL Server 2025 Express 17.0.1000.7，Windows 身份部署，混合模式已开）。
- 库：`KFC_DB`，由第一阶段 v0.1 **就地迁移**而来，没有换库名、没有删库：
  1. `capture_baseline.sql`（`-v SourceBaseline="v0.1-2026-10-03" -v ConfirmAppStopped=YES`）→ `batch_id = 1`，25 张基线表快照，`schema_digest = EFD5DDE8…4AD8245`；
  2. `run_migration.sql` 在一个外层事务里串 `11a → 11b → 11c → 12`，提交 **v1.0** 标记；
  3. `regression.sql` 跑出 **38/0**（`13a` 10 + `13b` 5 + `13b` 8 + `13c` 15）。
- 迁移后对象：**15 个 v1.0 过程 / 58 个权限码 / 71 行角色授权**，`cust_app` 拿到三个顾客过程的 `EXECUTE`。
- 演示账号：`test_store_manager`（`employee_id = 1`，`STORE_MANAGER`，库角色 `role_store_manager`，身份页显示 **39 个权限码**）。口令随机生成，只存在于本机临时文件，不写入仓库。
- 截图方式：Flask test client 以该账号登录，逐页 `GET` 后保存 HTML（模板自带内联样式，无外部静态资源），再用 Edge headless 以 1360×900 渲染成 PNG。页面里的数据是 `KFC_DB` 的真实行，不是桩数据。

## 边界

- 这组图证明的是：A 域九个主数据实体页在 **v1.0** 库上、以店长（`role_store_manager`）身份可取数与渲染。全链路验收结论以 `result/stage2/c-real-migration-2026-11-09.txt` 与 `docs/stage2/test-report.md` 为准，本目录不为全组背书。
- 登录页截图未填口令；身份页只显示「权限码（39）」的折叠标题，展开内容未截图。
- 订单工作台、库存与补货、顾客自助属于 B/C 的页面，不在本目录。
- 演示库 `KFC_DB_DEMO`（2026-11-08 由 v0.1 复制、只跑 `11a` + `11c`）仍留在本机，已被本组 v1.0 截图取代，不再作为证据引用。

## 文件

| 文件 | 页面 |
| --- | --- |
| `a-master-ui-01-login-2026-11-09.png` | 员工登录（未填写口令，含「顾客自助」入口） |
| `a-master-ui-02-identity-2026-11-09.png` | 我的身份（`sp_get_current_employee_context`：店长角色 + 39 个权限码 + 四个入口） |
| `a-master-ui-03-master-index-2026-11-09.png` | 主数据总览（九实体卡片） |
| `a-master-ui-04-category-2026-11-09.png` | 分类 |
| `a-master-ui-05-product-2026-11-09.png` | 商品（列表 + 新建/改价/改状态） |
| `a-master-ui-06-ingredient-2026-11-09.png` | 原料 |
| `a-master-ui-07-member-level-2026-11-09.png` | 会员等级 |
| `a-master-ui-08-customer-2026-11-09.png` | 顾客（列表 + 建档/改等级） |
| `a-master-ui-09-bom-2026-11-09.png` | 商品配方 |
| `a-master-ui-10-combo-2026-11-09.png` | 套餐组成 |
| `a-master-ui-11-promotion-2026-11-09.png` | 促销活动 |
| `a-master-ui-12-promotion-rule-2026-11-09.png` | 促销规则 |
