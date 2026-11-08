# B 第二阶段联调验收记录

环境：`localhost\MSSQLSERVER2`；随机命名的隔离库及临时 SQL 登录。测试不修改原业务库，退出时删除本次创建的库和账号。

## 复跑命令

```powershell
.venv\Scripts\python.exe -X utf8 tests/stage2/orders/check_migration.py --sql-server 'localhost\MSSQLSERVER2' --web
```

`--web` 需要支持 SQL 登录的测试实例，以及创建、清理临时库和登录的权限。脚本不会修改实例认证模式。

## 这轮补测的内容

| 场景 | 实际核对 |
| --- | --- |
| 骑手、店长页面 | 用真实登录从 Flask 提交认领、送达、未付款取消和已付款全额退款；再查订单、配送、支付、库存流水和积分状态 |
| 两骑手同时认领 | 两个真实骑手登录、两个 SQL 会话，经屏障同时发起认领。一个成功、另一个报 52602；核对唯一配送归属、库存和流水不变。非归属骑手送达报 52702，成功送达后再提交报 52701 |
| 事务 helper | 用实际收银身份提交超过 4000 字符的订单 JSON，同连接确认订单已写入后抛测试异常；外层回滚，订单、明细和库存锁恢复到前态 |
| 取餐、库存与退款回滚 | 停用临时顾客后真实 A 入账接口报 51002，订单和积分保持前态；恢复后成功取餐，再取报 52501。用 B 表上的临时触发器在实扣、释放库存之后抛错，检查订单、配送、支付、积分和库存恢复 |
| 结果恢复 | 不使用下单响应的正文或跳转地址，按提交前已有的订单号查到待支付订单；再次提交同一表单被拒绝。现金付款后按原号查到成功，支付记录只有一笔，流水号仍为 NULL |
| 员工及顾客库存不足 | 分别调用两个下单过程，均收到“可用库存不足”，没有留下订单、明细或库存流水 |

## 终端输出摘录

```text
PASS phase stage1
PASS phase capture_baseline
PASS injected pre-commit failure rolls back procedures, permissions and version marker
[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]RESULT: migration committed (v1.0 marker written; 11a/11b/11c/12).
PASS phase run_migration
[Microsoft][ODBC Driver 18 for SQL Server][SQL Server]RESULT: regression files=4 expected_pass=38 fail=0 (13a 10 + 13b 5 + 13b 8 + 13c 15)
PASS phase regression
PASS guest authorization, exact lookup, stock lock, cashier result sets and negative inputs
PASS six Flask roles: login/logout, cashier create/pay, chef start, packing/pickup, waiter board, rider/manager pages, CSRF/replay/role negatives
PASS BT-10 lookup by pre-submit number recovers discarded response; disabled waiter loses workbench session
PASS Flask rider claim and delivery completion, effective points
PASS Flask manager cancellation and full refund, release and voided points
PASS BT-07 concurrent real rider logins: one claim, loser SQL 52602, cross-rider 52702, repeat completion 52701
PASS BT-08 real Common transaction rolls back long-JSON order, items and stock lock
PASS temporary SQL logins removed
PASS BT-05 point denial rolls back pickup, subsequent pickup credits once, duplicate 52501
PASS finish failure after stock consumption restores inventory, order and delivery
PASS refund failure after stock release restores lock, payment and points
PASS BT-03 insufficient stock rolls back employee and guest orders, items and stock movements
PASS disposable database removed
```

退出码 0。联合 SQL 回归 **38/38**；五套应用测试 **96/96**。隔离库及临时账号已清理。

边界：B 的故障触发器只装在本次临时库的 B 表上，不替换 A/C 存储过程，不等同于对 C 的审计过程做故障注入。结果恢复用例模拟丢弃响应，没有断开真实网络连接。顾客网页、员工首页入口及整组现场部署由对应属主负责。
