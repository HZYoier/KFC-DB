# 第三阶段并发实验

## 订单制作与补货收货（正式 v1.1）

C 使用真实 `sp_finish_production` 和 `sp_receive_inventory`。每轮创建新原料、真实订单和已审批采购单。两个业务会话分别以配餐员和值班经理身份执行，第三个会话用 DMV 观察。SQL Server 2025 Express，READ COMMITTED，RCSI 关闭。

| 场景 | 数据与会话结果 |
| --- | --- |
| 收货等待订单提交 | P 初值 10，制作完成扣 2、持锁，收货 +5 等待。订单提交后，P=13、锁定量 0、订单待取餐、采购单关闭 |
| 收货等待订单回滚 | 订单回滚后 P 恢复 10，收货继续。P=15、锁定量恢复为 2、订单仍制作中、采购单关闭 |
| 反向持锁 | 订单先完成 P，补货先收 Q。订单请求完成 Q，补货再收 P。三轮补货均为 1205 牺牲者，回滚后两笔采购单仍已审批、收货量 0，P/Q=8/6，只有实扣流水和相应审计 |
| 统一加锁顺序 | 双方先逐项对 P、Q 依原料 ID 升序取更新锁，再执行同样的制作与收货过程。收货在第一个键等待。双方均提交，P/Q=13/11，采购单关闭，实扣及收货流水和审计成对 |

实际图中的环跨两张表。订单会话持有 `PK_Inventory` 的 X 锁，收货在该键请求 U 锁。收货会话持有 `PK_InventoryMovement` 的 X 锁，订单实扣在汇总锁定流水时请求 S 锁。统一顺序把等待提前到业务写入前，避免这组循环。改进实现于实验的外层事务；业务过程按原入口调用。

四种场景各三轮，每轮核对三个会话的 `@@TRANCOUNT=0`。通过 Windows 集成身份运行，脚本要求基线标识为 `C-Stage3-Disposable` 的一次性 v1.1 库：

```powershell
& 'D:\Miniconda\envs\py_env3.11\python.exe' tests/stage3/c_concurrency/run_c_business_concurrency.py
```

结束后立即用 26c 的 `Mode=graph` 取事件，以 UTC 时间、SPID、被阻塞的键资源与此次运行对照。实际轮次和从图提取的锁归属见[业务并发证据](../../result/stage3/c-business-concurrency-2026-11-25.txt)。

## A 的隔离级别对照

A 以同构实验表 P=10 运行四组。RU 可读到未提交的 15，回滚后读 10。RC 等待写事务回滚后读 10。RC 在两次读取之间遇到已提交收货，读到 10→15。RR 持共享锁至提交，两次都读 10，收货等待。实验 RCSI 关闭，临时表已清理。[A 的场景与原始输出](../../result/stage3/a-concurrency-26a-analysis.md)

## B 的并发购买

B 的两个会话各购买 P×6。P 从 10 开始，三轮都只有一笔成功，失败单报库存不足，最终 P=4、锁定量 0。失败单未留下订单、明细或库存流水。C 在正式 v1.1 独立库复跑 B 的三组实验，结果 9/0。[B 的步骤和实测](../../result/stage3/b-26b-handoff-2026-11-25.md)

## 26c 技术基线

### 锁等待与超时

| 现象 | 数据与验收判据 | 原因 | 处理 |
| --- | --- | --- | --- |
| 等待后继续 | 两个会话调用 `sp_adjust_inventory` 调整同一个 `IngredientA`。会话 2 等待时，DMV 的 `blocking_session_id` 指向会话 1，且两个会话最终都通过并回滚 | 会话 1 持有库存更新所需的锁，外层事务回滚后释放 | 库存读改写放在短事务里，尽早结束持锁阶段 |
| 超时 | 会话 2 等待上限为 3000 毫秒，捕获 1222 及对应消息，最终事务计数为 0 | 会话 1 持锁时间超过会话 2 的等待预算 | 调用方区分锁超时与业务拒绝，按操作语义决定是否重试 |

### 死锁与统一加锁顺序

| 现象 | 数据与验收判据 | 原因 | 处理 |
| --- | --- | --- | --- |
| 反向加锁 | 会话 1 锁 A 再请求 B，会话 2 锁 B 再请求 A。会话 2 优先级设为 LOW，预期捕获 1205 并回滚，会话 1 随后拿到第二把锁并回滚 | 两条真实 `Inventory` 主键记录上的更新锁构成等待环 | 对照死锁图的 `victim-list`、`process-list` 和 `resource-list`，标出每个 SPID 持有和请求的资源 |
| 同序加锁 | 两个会话均按 A → B 依次锁定。观测到会话 2 等待会话 1，两者最终都取得两把锁并回滚 | 会话 2 在取得第一把锁前等待，无法形成相反方向的依赖 | 涉及相同多原料的事务统一按 `ingredient_id` 升序取锁，缩短事务。若发生 1205，从事务入口重试 |

死锁对照用两个独立的主键查询和 `UPDLOCK, ROWLOCK` 明确表达锁顺序。业务侧对照见本页的正式 v1.1 实验。

### 26c 复跑和取证

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

3. 按 `wait → timeout → deadlock → ordered` 分轮运行，每轮两端使用同一个 Mode。看到会话 1 输出 `26c first lock` 后立即启动会话 2。会话 1 停留 12 秒；在超时轮中，会话 2 启动后 3 秒内运行 `observe`。按 SPID、原料 ID、`wait_resource` 和锁状态关联结果。死锁轮结束后立即运行 `graph`，以 UTC 时间、两个 SPID 和库存对象匹配 `system_health` 事件文件中的图（可能需等待事件写入后再次查询）。保存图时用 `-y 0` 保留完整 XML。
4. 每种模式重复三轮。保留双方退出码与 `RESULT`、DMV 输出、死锁 XML 和复查结果。核对两边事务计数为 0，实验前后的业务数据一致，再清理一次性库。若启动过晚、缺少等待快照或死锁图无法匹配，本轮应重跑。将实测输出归档到 `result/stage3/c-concurrency-*.txt`。

Windows 集成登录获准后，26c 四种模式各三轮通过。每轮双方回滚，五张业务相关表的行数据复查一致。28c 同次通过 63/0，测试库已清理。[26c 与 28c 实测证据](../../result/stage3/c-concurrency-2026-11-22.txt)
