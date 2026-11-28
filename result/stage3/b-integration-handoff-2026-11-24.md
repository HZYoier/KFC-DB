# B 联合验收交接

> 本文为 11 月 24 日历史演练记录。11 月 28 日已完成正式权限迁移与联合复测，当前结论见 [B 正式收尾回执](b-closeout-2026-11-28.md)。

2026 年 11 月 24 日同步到 `79da9c6`，在本机 `localhost\MSSQLSERVER2` 新建隔离库，部署真实 v1.0，再按 `20 → 21b → 21a → 21c → 22b → 22c` 应用域对象。

运行入口如下。

```powershell
.venv/Scripts/python.exe -X utf8 tests/stage3/b_programmability/run_b_stage3.py --sql-server 'localhost\MSSQLSERVER2' --verify-all
```

`--verify-all` 在 B 专项之后展开 C 的 `verify_stage3.sql`，顺序调用真实 `28a/28b/28c`。C 的 SQLCMD `Mode` 固定为 `rollback`。任何 SQL 错误均使入口失败，结束时核对事务数为零，随后删除隔离库。

| 检查 | 实测 |
| --- | --- |
| v1.0 及域对象安装后的旧 SQL 回归 | 各 38 条通过 |
| B 既有专项 | 21 条通过 |
| 收银折扣 | 实际查询返回快照，模板渲染通过，旧列兼容通过 |
| 24b | 一层和两层、根节点、子树、叶子和不存在编号通过 |
| 25b | 7 个场景通过 |
| 联合 28a/28b/28c | 52 + 8 + 63 = 123 条通过 |
| 七套应用 | 118 条通过，无跳过 |

本轮采用域对象演练的 v1.1 标记，权限保持 v1.0。`27_permissions.sql` 尚未交付，正式 `run_stage3.sql` 的整事务升级与权限计数仍需 C 完成后验收。原始输出见 [联合 SQL 验收](b-joint-verification-2026-11-24.txt) 和 [应用回归](b-app-regression-2026-11-24.txt)。

供 C 更新集成材料时使用的 B 回执如下。

- S3-03 的版本化 `13b` 已在本地完成。旧列数据漂移和额外列仍会被拒绝，域对象安装前后 38 条回归通过。
- `28b` 的固定分母为 8，两组测试。失败会抛出准确错误码，夹具全部回滚。
- 支付详情 RS2 在原有六列后追加 `discount_rate DECIMAL(5,4)` 和 `discount_amount DECIMAL(10,2)`。参数、收银权限和 RS1 保持原契约。订单履约数据字典第 9 节记录 v1.1 返回列。
- `sp_finish_production` 增加售卖明细缺失校验，错误码为 `52402`。请 A 在迁移变更清单记录，C 的权限仍使用原过程授权。
- C 的并发材料已到货，B 的订单完成与库存调整并发实测及个人报告仍需继续完成。
