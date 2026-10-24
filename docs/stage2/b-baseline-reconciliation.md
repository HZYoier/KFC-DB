# B 迁移基线与逐字段对账规范

> B；2026-10-14。供 C 冻结批次/存储协议、B 实现 baseline_b/13b 使用；本轮仅设计，无已采集批次或迁移执行结果。
> 依据：[重构方案](refactoring-design.md)、[范式分析](b-normalization.md)、[测试用例](b-test-cases.md)。目前B推荐保留五表，默认列映射为恒等；若冻结后拆表，先补明确映射再执行。

## 1. 捕获前提与一致性边界

C负责数据库辅助表、CAPTURING→COMPLETED/FAILED→VOID、应用锁和版本协议；B只提供本域查询与快照内容，不另建一套批次机制。
停止所有应用写入并验证备份后，在C的同一采集事务中一次读取五表；不得五次随意连接读取造成支付前订单和支付后积分混在一批。若未能证明停写，拒绝采集；应用锁自身不能阻止普通DML。
捕获batch_id、源码基线、数据库现场结构/对象摘要、采集时间和比较口径版本。采集成功批次不可覆盖；迁移前再次比较现场，漂移就停止并重新备份/采集，不能改旧批次使其匹配现场。
金额、NULL、时间和字符串均原值保存；辅助表名称和列类型等C协议确定后才绑定baseline_b写入语句。

## 2. 字段清单（53/53）

每表按主码逐行保留全部业务字段，不只保留SUM或哈希；版本/迁移辅助表不算业务表。下列“可空”取自02源码，不从当前种子值推断。

### SalesOrder：15列；比较键 order_id（order_no 为附加唯一核对键）

| 字段 | SQL类型 | 可空 | 保留/比较要求 |
| --- | --- | --- | --- |
| order_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| order_no | VARCHAR(50) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| customer_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| order_status | VARCHAR(20) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| fulfillment_method | VARCHAR(20) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| pickup_code | VARCHAR(20) | 是 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| total_amount | DECIMAL(10,2) | 否 | 固定精度十进制等值，不经浮点/格式化字符串比较 |
| ordered_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| paid_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| production_started_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| production_finished_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| completed_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| cancelled_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| created_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| updated_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |

### SalesOrderItem：10列；比较键 order_item_id

| 字段 | SQL类型 | 可空 | 保留/比较要求 |
| --- | --- | --- | --- |
| order_item_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| order_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| product_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| parent_order_item_id | BIGINT | 是 | 父快照键可空；匹配父行且与子行同order_id |
| item_role | VARCHAR(20) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| quantity | INT | 否 | 原正整数；组件保留下单时数量，不用当前套餐配置重算 |
| unit_price | DECIMAL(10,2) | 否 | 历史成交快照，不用当前定价重算 |
| promotion_id | BIGINT | 是 | 历史成交快照，不用当前定价重算 |
| created_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| updated_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |

### Payment：11列；比较键 payment_id（order_id 唯一）

| 字段 | SQL类型 | 可空 | 保留/比较要求 |
| --- | --- | --- | --- |
| payment_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| order_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| payment_method | VARCHAR(20) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| paid_amount | DECIMAL(10,2) | 否 | 固定精度十进制等值，不经浮点/格式化字符串比较 |
| payment_status | VARCHAR(20) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| paid_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| refunded_amount | DECIMAL(10,2) | 否 | 固定精度十进制等值，不经浮点/格式化字符串比较 |
| refunded_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| third_party_txn_no | VARCHAR(100) | 是 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| created_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| updated_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |

### Delivery：8列；比较键 delivery_id（order_id 唯一）

| 字段 | SQL类型 | 可空 | 保留/比较要求 |
| --- | --- | --- | --- |
| delivery_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| order_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| rider_employee_id | BIGINT | 是 | 原值等值；保留关联键或状态，不擅自重编号 |
| delivery_status | VARCHAR(20) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| picked_up_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| delivered_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| created_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| updated_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |

### PointLedger：9列；比较键 point_ledger_id（order_id 唯一）

| 字段 | SQL类型 | 可空 | 保留/比较要求 |
| --- | --- | --- | --- |
| point_ledger_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| order_id | BIGINT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| customer_id | BIGINT | 否 | 原顾客键；另核对与对应SalesOrder顾客相同 |
| paid_amount_snapshot | DECIMAL(10,2) | 否 | 固定精度十进制等值，不经浮点/格式化字符串比较 |
| point_multiplier_snapshot | DECIMAL(5,2) | 否 | 固定精度十进制等值，不经浮点/格式化字符串比较 |
| point_delta | INT | 否 | 原值等值；保留关联键或状态，不擅自重编号 |
| ledger_status | VARCHAR(20) | 否 | 原值与字节长度；按明确二进制语义比较，防排序规则/尾空格掩盖差异 |
| created_at | DATETIME2(0) | 否 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |
| effective_at | DATETIME2(0) | 是 | DATETIME2(0)原值；NULL与非NULL严格区分，不重新盖采集时间 |

## 3. 行集合与值比较算法

1. 先比较每表主码集合的双向差集：old−new、新−old均为空。再验证每表主码/已声明唯一键没有重复，不用EXCEPT去重掩盖重复行。
2. 保留方案按主码FULL OUTER JOIN找缺失/新增；对匹配行逐列比较，记录old/new和值类型。NULL与NULL相同，NULL与0/空串/时间不同；不得仅写 old<>new 让三值逻辑漏检。
3. 字符串按明确二进制值与字节长度比较，不能只依赖默认不区分大小写或忽略尾空格的排序规则；不要在比较前TRIM、统一大小写或转换显示格式。
4. DECIMAL精确比较；DATETIME2(0)原样比较，不转本机时区或字符串；IDENTITY键只比较已有行保留情况，计数器元数据另按批准迁移设计核对。
5. 若批准拆表，先把new映射回旧业务关系，再逐业务键比所有旧事实；行数变化附映射证明，不能简单要求每张新表与旧表相同行数。
6. 每个差异输出batch_id、表、业务键、列名、old/new、规则ID和解释；正常保留方案任何未批准差异都是FAIL。定义摘要/计数/哈希只能辅助定位，不能替代逐值比较。

## 4. 必须额外核对的不变量

| ID | 规则与查询形状 | 通过标准 / 注意事项 |
| --- | --- | --- |
| BB-01 | 每订单以LEFT JOIN售卖项分组，计数SELLABLE | 每成功持久订单>=1，不能INNER JOIN让空订单消失 |
| BB-02 | SUM(CONVERT高精度(quantity)×unit_price)，仅SELLABLE | 与total_amount逐单精确相等；中间精度足够，最终DECIMAL(10,2)边界有效 |
| BB-03 | COMPONENT自联父行 | 父存在、同单、父为SELLABLE；子非自身、零价、促销NULL |
| BB-04 | 支付按order_id关联订单 | 业务成功支付的原paid_amount=total_amount，退款不把原总额/实付清零；当前只有全额退款 |
| BB-05 | PointLedger关联订单/支付 | 顾客与订单相同，paid_amount_snapshot等于原实付；按当前冻结公式FLOOR(P×M)=point_delta且不越INT范围 |
| BB-06 | 状态组合 | 未支付取消无支付；PAID/IN_PRODUCTION正常有SUCCESS支付和PENDING积分；READY_FOR_PICKUP/READY_FOR_DELIVERY/DELIVERING仍PENDING；PICKED_UP/COMPLETED为EFFECTIVE；已付取消为REFUNDED/VOIDED |
| BB-07 | Delivery与订单关联 | 自取无配送；外送READY_FOR_DELIVERY有WAITING_PICKUP且骑手NULL；DELIVERING骑手非NULL；COMPLETED配送DELIVERED且骑手非NULL |
| BB-08 | 终态时间 | PICKED_UP/COMPLETED有completed_at；CANCELLED有cancelled_at；送达有delivered_at；原时间逐字段保留 |
| BB-09 | 唯一与引用 | Payment/Delivery/PointLedger.order_id至多一；外键存在且启用/可信，保留主码及过滤自取码唯一语义 |
| BB-10 | C订单库存关联 | 将本批订单键清单交C核对LOCK/RELEASE/CONSUME与现有/锁定量；不把reference_id当已有FK |
| BB-11 | A顾客累计/等级 | 与A基线对照迁移前后保持；保存opening_offset=baseline_current_points−baseline_EFFECTIVE积分和，迁移后保持offset与逐笔事实；不能直接以本库流水和替代全余额 |

BB-03只比较历史已存组件数量，不用当前ComboComponent重算旧单；有效商品类型/配置曾由下单过程校验，当前配置变化可能合理。构造新单测试时才按该次下单配置验证乘法关系。
2026-10-24确认：09a给顾客2/3分别设置500/1500期初积分，不产生B积分流水；因此上述offset是已知必须处理的事实，不只是未来可能性。任意现场按采集时余额与已生效流水计算，不能硬套种子常数。纠正A稿拟用的无期初SUM断言见[汇总说明](refactoring-design.md) §7.1。
BB-06面向当前真实业务入口可达状态，Payment虽有PENDING/VOIDED枚举但当前支付过程只产生SUCCESS/REFUNDED；遇到额外状态先记录来源，不静默改成“合理”状态。
所有不变量须捕获前也验证：旧数据本来不一致则阻断迁移、报告键和来源，不把“迁移前后都错”记为通过。业务范围外的DBA直写不能由迁移自动修复。

## 5. 统计对账口径

固定区间[start_at,end_at)，用订单completed_at，终态仅PICKED_UP/COMPLETED。按SELLABLE.product_id汇总quantity和quantity×unit_price，套餐按销售父项计销量/收入；COMPONENT另列制作量，不重复计收入。
订单主表金额在连接明细后会重复，不对v_order_detail的重复total_amount直接SUM；按订单去重或单独聚合。
退款量/金额按退款时间与Payment退款字段另列；未付取消不能计退款实收。时区与营业日边界由全组报告约定，B不自定“零点切日”替代业务定义。
积分分PENDING/EFFECTIVE/VOIDED汇总，记录笔数、point_delta和实付快照；单笔事实对账优先于总和。所有迁移前后使用同一批数据与同一区间/状态条件。

## 6. 验证对账器确实能发现错误

在专用副本/独立测试数据上分别注入：少一明细、交换两行单价但总和不变、错误父order_id、ledger错误顾客、NULL变0、历史时间改变、无支付LEFT JOIN被遗漏、订单详情重复总额聚合。每例对账必须失败并指出具体键/字段；恢复后同批检查通过。
这些是未来对账器的负向验收，不修改共享库、不开岗位直写权限。C冻结采集协议后B实现，再把实际命令、期望/实际、退出码和清理证据归档；本文不宣称已通过这些注入测试。

## 7. C需确认的最小协议

批次键类型与辅助表schema、快照保留/权限、同一采集连接传递方式、跨域顾客/库存键交接、拒绝漂移的标准化摘要、重复运行行为、对账输出与失败退出约定。B提交53字段和BB规则，不预设C最终辅助表的物理列名。
