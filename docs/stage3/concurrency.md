# 第三阶段并发实验

A 的隔离级别对照已有原始输出。C 的 26c 脚本已编写，等待在一次性真实数据库上执行并归档。B 补订单完成事务的影响分析。

## 锁等待与超时

| 现象 | 数据与验收判据 | 原因 | 处理 |
| --- | --- | --- | --- |
| 等待后继续 | 两个会话调用 `sp_adjust_inventory` 调整同一个 `IngredientA`。会话 2 等待时，DMV 的 `blocking_session_id` 指向会话 1，且两个会话最终都通过并回滚 | 会话 1 持有库存更新所需的锁，外层事务回滚后释放 | 库存读改写放在短事务里，尽早结束持锁阶段 |
| 超时 | 会话 2 等待上限为 3000 毫秒，捕获 1222 及对应消息，最终事务计数为 0 | 会话 1 持锁时间超过会话 2 的等待预算 | 调用方区分锁超时与业务拒绝，按操作语义决定是否重试 |

## 死锁与统一加锁顺序

| 现象 | 数据与验收判据 | 原因 | 处理 |
| --- | --- | --- | --- |
| 反向加锁 | 会话 1 锁 A 再请求 B，会话 2 锁 B 再请求 A。会话 2 优先级设为 LOW，预期捕获 1205 并回滚，会话 1 随后拿到第二把锁并回滚 | 两条真实 `Inventory` 主键记录上的更新锁构成等待环 | 对照死锁图的 `victim-list`、`process-list` 和 `resource-list`，标出每个 SPID 持有和请求的资源 |
| 同序加锁 | 两个会话均按 A → B 依次锁定。观测到会话 2 等待会话 1，两者最终都取得两把锁并回滚 | 会话 2 在取得第一把锁前等待，无法形成相反方向的依赖 | 涉及相同多原料的事务统一按 `ingredient_id` 升序取锁，缩短事务。若发生 1205，从事务入口重试 |

死锁对照用两个独立的主键查询和 `UPDLOCK, ROWLOCK` 明确表达锁顺序。业务侧的适用性待 B 用订单完成事务复核。

## 隔离级别

A 在 RCSI 关闭的 v1.0 实验库上，用独立实验表观察单行可见性。RR 两次读到 100，会话 2 在读事务结束后更新至 105。RC 第一次读到 100，第二次读到已提交的 105。两轮结束时恢复为 100。RR 的共享锁持有到事务结束，会延长并发写入的等待。真实销售汇总的对照依赖 B 的 `21b`。[26a 分析与原始输出入口](../../result/stage3/a-concurrency-26a-analysis.md)

## 26c 复跑和取证

1. 从仓库根目录部署一次性 v1.0，然后执行 `20 → 21c → 22c`。确认 `test_store_manager` 夹具已部署。选两个有库存行的启用原料，记其 ID 为 A、B，且 A < B。记录实验前两行库存量，以及对应库存流水、数量审计、调整业务审计和补货建议的状态。
2. 在三个 PowerShell 终端中使用相同脚本。前两个终端是业务会话，第三个终端只读 DMV 和扩展事件。使用有数据库模拟权限和服务器 DMV 查询权限的本地测试登录。下例的 `1`、`2` 换成查询得到的原料 ID。

   ```powershell
   $sqlcmd = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn\sqlcmd.exe'
   $labArgs = @('-S', '.\SQLEXPRESS', '-E', '-C', '-f', '65001', '-b',
                '-d', 'KFC_DB', '-i', 'sql/stage3/26c_lock_deadlock_experiment.sql')
   & $sqlcmd @labArgs -v Mode=wait Session=1 IngredientA=1 IngredientB=2
   & $sqlcmd @labArgs -v Mode=wait Session=2 IngredientA=1 IngredientB=2
   & $sqlcmd @labArgs -v Mode=observe Session=0 IngredientA=0 IngredientB=0
   & $sqlcmd @labArgs -v Mode=graph Session=0 IngredientA=0 IngredientB=0
   ```

3. 按 `wait → timeout → deadlock → ordered` 分轮运行，每轮两端使用同一个 Mode。看到会话 1 输出 `26c first lock` 后立即启动会话 2。会话 1 停留 12 秒；在超时轮中，会话 2 启动后 3 秒内运行 `observe`。按 SPID、原料 ID、`wait_resource` 和锁状态关联结果。死锁轮结束后立即运行 `graph`，以 UTC 时间、两个 SPID 和库存对象匹配 `system_health` 环形缓冲区中的图。保存图时用 `-y 0` 保留完整 XML。
4. 每种模式重复三轮。保留双方退出码与 `RESULT`、DMV 输出、死锁 XML 和复查结果。核对两边事务计数为 0，实验前后的业务数据一致，再清理一次性库。若启动过晚、缺少等待快照或死锁图无法匹配，本轮应重跑。将实测输出归档到 `result/stage3/c-concurrency-*.txt`。

本轮 SQL Express Windows 集成登录在建立连接时返回 SSPI 凭证错误。上面的 26c 判据待实测。
