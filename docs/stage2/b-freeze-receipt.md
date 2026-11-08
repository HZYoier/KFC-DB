# B 冻结回执、11b依赖矩阵与可用代码（2026-10-30）

## B 实际交付回执

- [11b](../../sql/stage2/11b_order_migration.sql) 已交付六个员工查询和两个顾客过程，保留原八写过程及五张表。`run_migration.sql` 串真实三域脚本运行，不再使用 B 临时桩。
- **OI-19 B 回执：** B 的下单和查单只识别手机号（查单还需取餐码），不依赖顾客姓名，同意 A 的建档接口只传 `@mobile`。顾客页面与部署仍归 C；B 不修改共享问题状态。
- [订单工作台](../../app/orders/routes.py) 在 `/orders/`。请 A 更新操作手册的订单章节，C 可在员工首页补入口并据真实脚本复跑验收；本次不改 A/C 所属文件。
- 订单字典已补 v1.0 接口。复跑方法和新增验收范围见 [B 联调记录](../../result/stage2/b-order-acceptance-final.md)。

## 2026-11-05 同步更新（远端 `df485b8`）

- OI-14 的共享层修复已合入：双结果集走 `query_procedure_sets`，延迟异常由 Common 传播。B 已补齐六个冻结查询的 DAO/service 适配和边界测试；不注册页面，不把适配器当作 11b 已部署。
- C 的正式入口已接入两份 B 回归检查，并报告真实三域快照采集证据。B 基线检查现自行开启 QUOTED_IDENTIFIER，不依赖 sqlcmd 开关。
- OI-10 §1.7.1/§1.7.2：B 技术上支持本轮只开放自取、响应丢失不自动恢复、不加幂等键；页面可防连点并明确提示找门店核实，不能自动重下。§1.7.3/§1.7.4 的凭据与部署由 A/C 定，B 不存储凭据、不代签、不改状态表。

## 2026-11-03 同步更新（远端 `3af6765`）

- 以下保留 10-30 的交付回执。当前以共同问题表为准：OI-03 已关闭，员工 §2 已进入冻结后的实施阶段；顾客 §1 的未决项仍不随之冻结。
- C 已使用真实 B/C 快照脚本加 A 临时桩验证采集（17 项通过）；A 后续已交付真实 `baseline_a.sql`，现已具备三份真实快照脚本，但此前的带桩结果不等于三份真实脚本的整链验收。
- A 的 11a 和 C 的 11c 均已到位。B 的 11b 保持五表与八写签名，六查询只依赖原业务表；不在 11b 写权限目录、GRANT 或签名，不提交入口事务。A 的最新共享层变更只增加 TIME 参数绑定，以下关于多结果集和异常传播的交接仍有效。
- 11b 错误码提案，供 C 登记后落地：`52901` 为 `@take` 为空或超出 1..200；`52902` 为订单定位参数不满足恰一有效值；`52903` 为支付详情订单不存在或已非待支付。身份/岗位拒绝沿用现有 B 守卫语义，不返回空集合冒充授权通过。状态查询按有效定位键未查到订单则返回空集合；队列单次有界，不实现无游标循环。

> B；输入远端d741e24。从B技术准备看支持A提议的2026-11-03日期，**不代用户本人或C签字、不把OI-03改为closed**；最终日期由各成员确认。共同契约§2尚未共同冻结，本轮不部署六个新查询或顾客过程。
> 对应[开放问题](open-issues.md) OI-03第③项、[共同契约](application-contract.md) §2、[访问层契约](access-layer-contract.md)、[基线协议](migration-guide.md)。本轮仅修改B实现/材料及追加AI记录。

## 1. B已接收的A/C交付

- OI-09已closed，总ER图25实体/35FK已合并；B不再把C图例/合图列为未交。
- A的八个写接口与六个查询参数/列清单已复核；B保留写接口签名和无结果集语义，不把应用包装的空列表当新订单ID。
- C的快照协议已冻结：batch_id BIGINT、Baseline_<Table>保留全部原列、调用方事务/变量、无GO、不自持事务；11c固定枚举CHECK迁位并扩展已定。B据此交付真实baseline_b.sql，不再称“等C定义形状”。
- A的common已交付。本轮B只接入已部署的八个员工写过程；六个未实现查询和未冻结顾客接口不提供可误调用的伪包装。

## 2. 11b依赖矩阵（B收尾素材）

| 11b对象/动作 | 输入依赖（必须先存在） | 向A/C提供的输出/列契约 | 责任与顺序 |
| --- | --- | --- | --- |
| 保留五表键、金额/促销/数量/积分事件快照 | 完整v0.1对象及同批五表快照 | order_id/order_item_id等ID保持；SalesOrderItem角色、父键和数量不变 | B在11b校验，不重跑02/05；A/C继续读同名列 |
| 既有八写过程不改签名 | A定价/积分接口；C库存/审计和员工档案 | 当前8签名、52xxx原错误传播、同一B外层事务 | 仅有冻结批准的升级才ALTER；本轮DAO调用现有实现 |
| sp_list_orders_for_payment | SalesOrder、EmployeeAccount | @take、RS1四列，按ordered_at/order_id | B11b；C11c补目录/映射，12授权CASHIER |
| sp_get_order_for_payment | SalesOrder/Item、Product、EmployeeAccount | @order_id；订单头RS1与SELLABLE明细RS2 | B11b；A访问层须支持两结果集后才给页面接入 |
| sp_get_order_operation_status | SalesOrder、Payment、EmployeeAccount | @order_id/@order_no恰一；LEFT JOIN支付，NULL不转0 | B11b；C给CASHIER/STORE_MANAGER授权；结果未知先查不重付 |
| sp_list_orders_for_packing | SalesOrder/Item、Product、EmployeeAccount | @take限订单数；固定键集合头/明细两结果集 | B11b；A两结果集支持；C给PACKER授权 |
| sp_list_my_deliveries | Delivery、SalesOrder、EmployeeAccount | 只当前骑手DELIVERING；take与五列按共同§2.2 | B11b；C给RIDER授权；不由调用方提交任意骑手ID查单 |
| sp_list_deliveries_available_for_pickup | Delivery、SalesOrder、EmployeeAccount | READY_FOR_DELIVERY/WAITING_PICKUP/rider NULL；四列 | B11b；C给RIDER授权；实际认领仍在既有事务内竞争 |
| sp_customer_place_order/list_orders | A建档/定价；C cust_app最小授权；共同§1联合边界 | 订单头单结果集、20位自取码、内部C锁库 | 顾客§1仍有联合待定，不趁员工§2冻结把它一并冒充冻结 |
| baseline_b / 13b | C同批@batch_id与辅助表；A/B/C现场一致 | 53列五张快照；13b逐键/逐字段核对 | baseline_b已交；13b在共同冻结/迁移后执行；不往旧10b加新结构测试 |

标准顺序仍为11a→11b→11c→12。B保留A/C引用的所有旧ID/列，六新查询只依赖现有表和A商品名，不依赖新Permission表，所以不要求11c提前执行。C在11c增加查询权限目录/角色映射，12才精确GRANT；B不更改C目录、授权或签名。
新查询的SQL错误编号在冻结清单经C登记后使用，当前不在生产代码新增529xx。I-B08继续基线重复顶层商品拒绝规则，不擅自实现另一套套餐输入策略。

## 3. 对A访问层的实际核对回执

可用部分：SqlParam构造、四参数下单（不传历史时间）、显式None支付、Decimal(10,2)、错误映射、短连接关闭均已由B边界测试接入。BDAO不import pyodbc、不自连库、不自开事务，单过程不包helper。

以下问题交A处理，B不改app/common或共同契约：

1. **队列不是分页**：§2.2没有offset/keyset且没有“读后移出队列”的保证，同参数循环拉取会重复首批；若始终>=take则永不结束。B采用单次有界快照/用户显式刷新，不写循环；建议A将“循环至行数<take停止”修为本轮单页上限说明，或共同另冻游标，不能拿无游标循环当已实现分页。
2. **第二结果集丢失**：db._rows当前返回首个非空集合，不保留RS2；get_order_for_payment和packing的两结果集不能按此直接调用。建议A提供明确的多结果集调用返回形状并覆盖空RS1、完整RS2、ODBC错误；B冻结前不将明细压成未约定JSON、不偷偷改SQL返回列。
3. **nextset异常**：db._rows在nextset抛pyodbc.Error时返回rows，可能把延后到达的数据库错误吞为成功。B的空结果写过程无法独自从[]判断其真成功；A应让异常由共同映射抛出并关闭连接，而不是继续猜成功。这是源码风险提示，本轮未把A函数改掉或称该问题已复现/修复。
4. **员工身份不能回退**：Common允许无session退部署账户仅作本机冒烟。B的DAO与service都先拒绝缺db_login/db_password的session为E_AUTH；不凭session.role授业务权，SQL仍核岗位。C需提供安全请求级凭据，Windows逐员工集成认证路径若需支持，须A/C补上下文协议后B适配，当前不假装支持。
5. **集成认证配置**：真实SQL员工会话不能与Trusted_Connection=yes的部署冒烟配置混用；A/C须验证USER_NAME()确是请求员工，不只看到session里有用户名就宣称身份贯通。
6. **VARCHAR字符/字节边界**：B的Python长度检查只提供字符数上限，不能替代目标排序规则/codepage的字节与可表示性验证；本轮没有验证多字节VARCHAR上限或不支持字符的无损往返。不得据此宣称任意Unicode订单号/支付标签已无损联调，接入页面前须与A明确共享绑定的无损校验策略，拒绝截断/替换，不擅加全ASCII业务枚举。

第1项是共同文本需要改清的循环语义；第2/3项需要A的访问层实现/测试跟进。不影响B基线采集或包装代码交付；第2项阻断两结果集查询验收，第3项也可能影响无结果集写过程，因此员工写入的“成功响应可信、已真实联调通过”同样不可提前宣称。

## 4. B实际代码与使用方法

- [baseline_b.sql](../../sql/stage2/baseline_b.sql)：五表全部53列，去IDENTITY/业务约束，(batch_id,主键)唯一；重复同批拒绝，public显式DENY读写，不改业务表，不提交外层事务。由C capture入口在同连接声明@batch_id后引用。
- [DAO](../../app/orders/dao.py)与[service](../../app/orders/service.py)：create/pay/start/finish/pickup/rider/confirm/cancel八动作；服务层验证正数BIGINT/INT、输入对象白名单、重复顶层商品、金额精度与长度，再经common定型；不复制定价、库存、积分规则，不重试支付。
- service.create_order输入Python list[dict]，仅product_id/quantity；order_no须上层在请求前保存；返回现有过程空列表，不虚构新ID/状态。pay_order金额必须Decimal，None明确绑定第三方流水号；不把支付方式增加为未批准枚举。
- app/orders包暂不暴露bp或路由，所以不会在A应用工厂自动注册公共页面。真实登录、请求级上下文、共享最小验收和多结果集问题收口前，不把骨架当可运行订单Web界面。

## 5. 本轮验证与范围

测试先运行得到15个缺实现失败，再补实现转绿；追加支付方式边界时暴露擅加ASCII限制，写失败用例后移除，不修改共同契约迁就实现。
最终命令与实际结果见[B阶段报告](b-stage-report.md) §9及证据。入口为[run_tests.py](../../tests/stage2/orders/run_tests.py)，显式指定--sql-server；要求18例全运行且无skip，否则非零退出。SQL测试在唯一命名KFC_B_TEST_20261030_<随机后缀>临时库中执行真实baseline_b；源表是与02列形状一致的合成夹具，没有A/C完整FK/业务过程，所以该结果证明B快照脚本，不是25表capture端到端。另用真实Common验证5001字符Unicode MAX绑定、Decimal/None及helper第二步失败完整回滚、成功提交。测试仅删除其本次创建的临时库，KFC_DB没有业务写入。
A common本机9条冒烟在现有KFC_DB只读/预写入守卫下通过；B应用测试使用真实service/DAO/common参数绑定，只替换外部ODBC连接，不声称真实员工支付/下单已联调。端到端采集仍需A的baseline_a，11b/13b及顾客过程仍按冻结门槛推进。

## 6. A/C可继续做的具体事项

A：可接收B技术日期建议、53列快照与11b依赖矩阵；最终日期待用户本人确认，按§3修订分页/多结果集/异常传播并提供访问层测试。
C：可把baseline_b接入已有capture，待baseline_a到后跑25表整链；可按矩阵准备六查询的目录/角色授权；由C本人决定日期回执和OI-03状态。
B：收到共同冻结与A修复后即可按不变签名实现11b六查询、13b与orders页面，不重开A/C已有的结构/权限决议。
