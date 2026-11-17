# A 域隔离级别实验分析（26a，供 `docs/stage3/concurrency.md` 合并）

> 属主：A。本文是分析素材，最终由 C 汇总进 `docs/stage3/concurrency.md`。
> 原始输出：`result/stage3/a-concurrency-26a-{setup,rr-s1,rr-s2,rc-s1,rc-s2,cleanup}.txt`。
> 脚本：`sql/stage3/26a_isolation_experiment.sql`。

## 1. 实验对象与环境

| 项 | 值 |
| --- | --- |
| 数据库 | `KFC_DB`，`SchemaVersion = v1.0` |
| 服务器 | SQL Server 2025（本机默认实例 `localhost`） |
| RCSI | `sys.databases.is_read_committed_snapshot_on = 0`（未启用快照读） |
| 实验表 | `dbo.Stage3IsolationLab_A`，只有 `lab_id / on_hand_qty / note`，初值 `on_hand_qty = 100.000` |
| 隔离级别 | 会话 1 分别用 `REPEATABLE READ`（RR）与 `READ COMMITTED`（RC）；会话 2 用默认 RC |

实验表与 `Inventory` 同构但独立，不碰真实库存行，也不触发 `InventoryAudit`；真实库存行的锁等待、超时与死锁由图 C 的 `26c` 覆盖。这样做是为了在 v1.1 尚未应用时也能复现隔离级别差异。

## 2. 过程

两个会话都执行同一脚本，用 `-v` 区分角色：

```text
终端 0：-v Session=setup   -v Level=NA   建表并置 100.000
终端 1：-v Session=1       -v Level=RR   开事务 → 第一次读 → WAITFOR 8 秒 → 第二次读 → 提交
终端 2：-v Session=2       -v Level=NA   WAITFOR 3 秒 → 更新 +5 并提交 → 读 → WAITFOR 8 秒 → 还原 -5
```

终端 1 的 `Level` 改成 `RC` 再跑一遍，最后 `-v Session=cleanup` 删表。

## 3. 结果

| 轮次 | 会话 1 第一次读 | 会话 1 第二次读 | 会话 2 提交后 | 会话 2 还原后 |
| --- | --- | --- | --- | --- |
| REPEATABLE READ | 100.000 | **100.000** | 105.000 | 100.000 |
| READ COMMITTED | 100.000 | **105.000** | 105.000 | 100.000 |

两轮里会话 2 的更新都成功提交；差别只在会话 1 的第二次读是否看得见这次提交。RR 轮次中会话 2 的 `UPDATE` 被会话 1 持有的共享锁挡住，等会话 1 提交后才执行。

## 4. 判读

1. **RC 的读锁只到语句结束。** 会话 1 第一次读拿到共享锁，语句完成即释放；会话 2 在两次读之间提交，第二次读按新的已提交版本返回 105。这是“报表能读到实验期间新完成的订单”的对应现象。
2. **RR 的共享锁持有到事务结束。** 会话 1 的第一次读把共享锁留到 `COMMIT`，会话 2 的更新只能等待；会话 1 两次读都在同一事务快照（锁定读）下完成，都是 100。这是“同一份报表在一次事务内数字不变”的对应现象。
3. **RCSI = 0 时 RC 不是快照读。** 如果把数据库改为 `READ_COMMITTED_SNAPSHOT ON`，RC 的第二次读仍会看到 105，但会话 2 不再被会话 1 的读阻塞；本实验不修改数据库设置，只记录当前为 0。
4. **业务取舍。** 销售报表要“一次生成、口径不漂”，应把读取放在同一事务并考虑 RR 或快照读；但 RR 会把共享锁持有到事务结束，期间可能挡住下单与库存更新。报表页面应尽量缩短事务，只读一次 `sp_sales_report`，不在事务里做格式化或外部调用。是否启用 RCSI 属于部署决策，A 不擅自改库。

## 5. 局限与后续

- 本实验用独立实验表验证隔离级别的可见性，不是真实销售汇总。B 的 `21b`（`v_settled_sales_line` / `sp_sales_report`）到齐后，A 应把会话 1 的读取换成“同一区间的销售汇总”，再补一组 RR/RC 对照，作为 `concurrency.md` 的最终 A 段。
- 本文不提供锁资源、等待链与死锁图：那部分由 C 的 `26c` 用 `sys.dm_tran_locks` / `sys.dm_exec_requests` / `system_health` 取证。
- 实验结束后已执行 cleanup，`Stage3IsolationLab_A` 不在库中；证据文件里保留了建表时的 `rcsi_enabled = 0`。

## 6. 复跑命令

```bash
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=setup   -v Level=NA -i sql/stage3/26a_isolation_experiment.sql
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=1       -v Level=RR -i sql/stage3/26a_isolation_experiment.sql &
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=2       -v Level=NA -i sql/stage3/26a_isolation_experiment.sql
# 等两个会话都结束后，把 Level 改成 RC 再跑一轮
sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=cleanup -v Level=NA -i sql/stage3/26a_isolation_experiment.sql
```
