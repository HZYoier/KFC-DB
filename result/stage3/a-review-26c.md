# A 对 C `26c` 的审阅（对照第十三周讲解）

> 审阅人：A；对象：`sql/stage3/26c_lock_deadlock_experiment.sql`、`docs/stage3/concurrency.md`（C，2026-11-22 版本）。
> 依据：`docs/stage3/three-person-implementation-plan.md` §7、第十三周讲解。只审阅，不改 C 的文件。

## 结论

**现有 26c 可以作为“库存行锁/死锁”的技术基线，但不能直接当作第十三周业务并发实验的最终交付。** 需要 C 按 §7 改成订单事务与补货事务的双会话场景，并重跑证据。

## 已有的部分（可保留）

- `wait` / `timeout`：两个会话对同一库存行加锁，`sys.dm_exec_requests` 抓 `blocking_session_id`、`wait_type`、`wait_resource`；超时确认 `1222`；
- `deadlock`：P/Q 反向加锁，`system_health` 读死锁图，确认 `1205` 与牺牲者；
- `ordered`：按 `IngredientA < IngredientB` 的顺序加锁，验证反向循环被消除；
- `observe` / `graph` 与清理、`@@TRANCOUNT` 检查齐全。

这些说明 SQL Server 层面的锁/死锁观察方法是对的，C 的 26c 实测证据也可以保留为“技术基线”。

## 与第十三周要求的差距

| 要求 | 26c 现状 | 需要 |
| --- | --- | --- |
| 订单事务 vs 补货事务 | `wait`/`timeout` 调用 `sp_adjust_inventory`，不是 `25b` 订单完成或 `25c` 补货入库 | 改为 B 的订单会话（`25b`/`sp_finish_production`）+ C 的补货会话（`25c`/收货过程），否则不是“订单与补货”的业务等待 |
| P 扣 2 / 补货加 5，提交后 P=13、回滚后 P=15 | 每次只 `+1` 调整库存，没有订单/补货单据结果 | 按 §7.1 的夹具与预期重写，记录订单/补货状态 |
| 死锁后改进两项业务 | 死锁/ordered 用直接 `UPDLOCK` 读库存，不是 25b/25c 的加锁路径 | 改进方案要落到订单/补货事务的实际加锁顺序，并在同一场景重跑 |
| 两笔 P×6 并发购买 | 没有 | 属于 B 的 `26b`，不是 26c；C 的 `concurrency.md` 需要引用 B 的结果 |
| 脏读 / RC/RR | 26c 固定 RC，没有 RU/RR | A 的 `26a` 已覆盖；`concurrency.md` 汇总时引用 A 证据，不重复造脚本 |

## 建议

1. C 保留 26c 的 `observe`/`graph`/`ordered` 骨架，把 `wait`/`timeout`/`deadlock` 的业务动作替换为 `25b` 订单事务和 `25c` 补货事务；
2. 按 §7.1 记录 P=13/15 两种结果，按 §7.3 记录订单/补货单据状态与死锁图；
3. `concurrency.md` 增加 A 的脏读/RC/RR 与 B 的 P×6 购买，形成三域合并；
4. 现 26c 证据保留为技术基线，不冒充第十三周最终业务证据。
