# A 域隔离级别实验分析（26a，供 `docs/stage3/concurrency.md` 合并）

> 属主：A。本文是分析素材，最终由 C 汇总进 `docs/stage3/concurrency.md`。
> 原始输出：`result/stage3/a-concurrency-26a-2026-11-25-*.txt`。
> 脚本：`sql/stage3/26a_isolation_experiment.sql`。

## 1. 实验对象与环境

| 项 | 值 |
| --- | --- |
| 数据库 | `KFC_DB`，`SchemaVersion = v1.0` |
| 服务器 | SQL Server 2025（本机默认实例 `localhost`） |
| RCSI | `sys.databases.is_read_committed_snapshot_on = 0`（未启用快照读） |
| 实验表 | `dbo.Stage3IsolationLab_A`，与 `Inventory` 同构，P 初值 `10.000` |
| 会话 | S1/S2 为两个独立 sqlcmd 连接；每轮 setup 重置 P=10，cleanup 删表 |

实验表独立于真实 `Inventory`，避免改业务库存或触发 `InventoryAudit`；真实库存上的订单/补货锁等待与死锁由 B 的 `26b`、C 的 `26c` 覆盖。

## 2. 过程

```text
setup：建表，P=10
脏读：S1 更新 P=15 不提交；S2 等 3 秒后以 RU 或 RC 读，S1 8 秒后回滚
不可重复读：S1 以 RC 或 RR 读 P=10；S2 等 3 秒后提交 P+5；S1 8 秒后第二次读
cleanup：删表
```

每条命令都带 `-v Session=... -v Mode=... -v Level=...`；S1 先启动，S2 在 3 秒后启动。

## 3. 结果

| 场景 | S1 | S2 |
| --- | --- | --- |
| 脏读，S2=RU | P 更新为 15，随后回滚回 10 | 第一次读到 **15**（未提交），S1 回滚后第二次读 10 |
| 脏读，S2=RC | 同上 | 第一次读等待 S1 回滚，随后两次都读 **10** |
| 不可重复读，S1=RC | 第一次 10，第二次 **15** | P+5 提交，读到 15 |
| 不可重复读，S1=RR | 第一次 10，第二次 **10**；提交后 S2 才继续 | P+5 被 S1 的共享锁挡住，S1 提交后完成 |

RCSI=0；RC 是锁定读，不是语句级快照。

## 4. 判读

1. **RU 脏读**：S2 读到 S1 未提交的 15；S1 回滚后值回到 10。业务上不能用它做库存判断，否则会把不存在的入库当成可用量。
2. **RC 已提交读**：S2 的第一次读被 S1 的排他锁挡住，等 S1 回滚后才读到 10；不会看到未提交值。
3. **RC 不可重复读**：S1 两次读之间 S2 提交了 +5，第二次读到 15；同一事务内数字不稳定。
4. **RR 可重复读**：S1 第一次读持有共享锁到提交，S2 的 +5 等待；S1 两次都读 10。RR 保护“已读过的数据”，但会延长写等待，不等于解决所有并发问题。
5. **业务取舍**：库存判断必须在短事务内“检查 + 更新”一次完成，不能先读 10 再在事务外认定足够；报表需要稳定快照时可用 RR/快照读，但要评估持锁时间。RCSI 是否启用属于部署决策，本实验不修改。

## 5. 局限与后续

- 本实验用独立实验表观察隔离级别；订单事务与补货事务在同一真实 `Inventory` 行上的等待由 B 的 `26b`、C 的 `26c` 验证，二者不能互相替代。
- 本文不提供锁资源/死锁图：C 的 `26c` 用 `sys.dm_tran_locks`、`sys.dm_exec_requests` 与 `system_health` 取证。
- 实验结束已 cleanup，`Stage3IsolationLab_A` 不在库中。

## 6. 复跑命令

```bash
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=setup -v Mode=NA -v Level=NA -i sql/stage3/26a_isolation_experiment.sql

# 脏读：Level=RU 或 RC
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=1 -v Mode=dirty -v Level=NA -i sql/stage3/26a_isolation_experiment.sql &
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=2 -v Mode=dirty -v Level=RU -i sql/stage3/26a_isolation_experiment.sql

# 不可重复读：Level=RC 或 RR
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=1 -v Mode=nonrepeat -v Level=RR -i sql/stage3/26a_isolation_experiment.sql &
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=2 -v Mode=nonrepeat -v Level=NA -i sql/stage3/26a_isolation_experiment.sql

sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=cleanup -v Mode=NA -v Level=NA -i sql/stage3/26a_isolation_experiment.sql
```
