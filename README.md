# KFC-DB

以现实 KFC 为原型的门店经营数据库课程设计项目，贯穿 17 周共 4 个阶段，让同一套库从"记录业务"逐步建设为"支持经营分析与补货决策的应用"。

## 项目范围

覆盖门店从后台准备到补货闭环的完整经营链路，按业务主线分层建设：商品/BOM/促销等主数据、订单与支付、积分两段式、防超卖库存、补货建议与采购入库，以及后续的经营分析视角。当前已完成**第一阶段关系数据库交付**：可从空库一次部署表、约束、过程、视图、种子和岗位权限，并执行 A/B/C 三域验收。

## 目录结构

```text
KFC-DB/
├── README.md                    本文件：项目范围、业务角色、环境、复现步骤
├── .gitattributes               固定 result/*.txt 的换行，使登记的 SHA-256 可逐字节核对
├── sql/                         全部脚本（20 个），唯一入口 run_all.sql
│   ├── run_all.sql              按固定顺序 :r 串联其余脚本，需从仓库根目录执行
│   ├── 00_create_database.sql   建库；检测到同名库主动报错停止，不覆盖已有数据
│   ├── 01 / 02 / 03             三域建表：主数据、订单、库存与权限
│   ├── 04 / 05 / 06             三域约束与 CRUD 过程
│   ├── 07a / 07b / 07c          三域视图与关键查询
│   ├── 08_roles_permissions.sql 角色与最小授权
│   ├── 09a ~ 09d                三域种子数据
│   ├── 10a / 10b / 10c          三域验收断言
│   └── contract_interface_check.sql   只读跨域接口契约检查（独立执行）
├── docs/                        设计与验收文档（15 份）
│   ├── stage1-阶段报告.md        总报告：设计思路、实验过程、实验总结
│   ├── stage1-a / b / c-stage-report.md   三份成员分工报告
│   ├── stage1-test-report.md     完整测试报告：环境、结果、E2E 结论、三次独立复验
│   ├── stage1-cross-domain-interface-contract.md   A/B/C 之间冻结的接口契约
│   ├── stage1-three-person-implementation-plan.md  第一阶段协作实施计划与分工总览
│   ├── stage2-three-person-implementation-plan.md  第二阶段计划与分工：ER 重建、规范化与迁移、应用开发，含 v0.1 问题清单
│   ├── 主数据 / 订单履约 / 库存权限数据字典.md      三份字段级数据字典
│   ├── 业务流程.md               业务主线 8 步（含异常路径）
│   ├── 数据边界清单.md           进库 / 不进库边界与灰色地带取舍
│   ├── 角色与职能清单.md         7 个业务角色的职责与映射
│   └── AI使用记录.md             AI 协作过程记录
└── result/                      执行证据（31 个）
    ├── README.md                证据清单：逐文件说明与全部 SHA-256
    ├── stage1-full-test-*.txt   三台机器各自从空库整跑的完整原始输出
    ├── stage1-contract-check-*.txt      跨域接口契约检查输出
    ├── stage1-object-inventory-2026-10-01.txt   对象数量清点
    ├── stage1-receiving-*-c-2026-10-01.txt      收货链不变量与边界断言（成员 C）
    ├── stage1-regression-c-2026-10-01.txt       夹具链回归汇总（成员 C）
    ├── stage1-full-test-summary-2026-10-01.png  结果摘要图
    └── stage1-a-*.png           19 张操作截图：建库、CRUD、关键查询、越权、非法数据、权限
```

部署入口只有 `sql/run_all.sql` 一个。`docs/` 与 `result/` 不参与部署，分别是设计依据和执行证据。

## 业务角色

第一阶段落地 7 个业务角色，一律通过数据库角色授权，不向个人账号或业务角色开放任何表级写权限——所有业务写入只经存储过程完成。

| 角色 | 数据库角色名 | 职责 |
| --- | --- | --- |
| 店长 | `role_store_manager` | 主数据维护（商品、分类、BOM、套餐、促销、会员等级）、补货审批、角色分配 |
| 值班经理 | `role_shift_manager` | 库存与预警查看、补货建议提交、外送调度 |
| 收银员 | `role_cashier` | 下单与收款 |
| 厨师 | `role_chef` | 开始/完成制作 |
| 配餐员 | `role_packer` | 出餐、打包、取餐 |
| 骑手 | `role_rider` | 配送确认 |
| 服务员 | `role_waiter` | 只读 |

完整清单（含顾客侧角色与系统自动行为）见[角色与职能清单](docs/角色与职能清单.md)；权限的划分口径与正反例见[第一阶段阶段报告](docs/stage1-阶段报告.md) §1.6。

## 环境

- 数据库平台：SQL Server 2025（17.0，兼容级别不低于 130）
- 已验证实例（三台机器各自从空库整跑，结论一致）：`localhost\MSSQLSERVER2`（Developer Edition）、`.\SQLEXPRESS`（Express Edition）、`localhost`（`@@SERVERNAME` = `DESKTOP-TSLV34Q`，Express Edition）
- 登录方式：Windows 身份验证；部署账号需要建库权限
- 客户端：`sqlcmd`（ODBC Driver 18）或启用 SQLCMD Mode 的 SSMS

> 下文命令中的 `-S` 一律写作 `localhost\MSSQLSERVER2`；实际执行时换成自己的实例名即可，脚本与实例名无关。

## 整体链路

后台准备 → 顾客点餐计价 → 下单支付 → 后厨制作 → 交付配送 → 终态积分/库存处理 → 补货闭环

详细到每一步的状态迁移与数据写入见 [业务流程](docs/业务流程.md)。

## 复现步骤

1. 确认目标实例中不存在 `KFC_DB`。为防误覆盖，建库脚本检测到同名数据库会主动停止。
2. 在仓库根目录执行：

   ```powershell
   sqlcmd -S "localhost\MSSQLSERVER2" -E -N o -C -f 65001 -b -i "sql/run_all.sql"
   ```

3. 成功日志应包含：
   - `RESULT: pass=13 fail=0`（A 域）
   - `RESULT: pass=15 fail=0`（B 域）
   - `RESULT: pass=18 fail=0`（C/权限与集成域）
4. 可另行执行只读接口检查：

   ```powershell
   sqlcmd -S "localhost\MSSQLSERVER2" -E -N o -C -f 65001 -b -i "sql/contract_interface_check.sql"
   ```

完整执行证据见 [`result/`](result/)，实验过程与结论见 [第一阶段测试报告](docs/stage1-test-report.md) 和 [成员 B 阶段报告](docs/stage1-b-stage-report.md)。

## 文档索引

- [**第一阶段阶段报告**](docs/stage1-阶段报告.md) — 总报告：经营场景与数据边界、表设计（主码 / 候选码 / 外码）、角色与权限正反例、部署与验收
- [角色与职能清单](docs/角色与职能清单.md) — 后台/作业/顾客侧角色 + 系统自动行为，供后续 role.sql / 权限设计
- [数据边界清单](docs/数据边界清单.md) — 进/不进库边界与灰色地带取舍
- [业务流程](docs/业务流程.md) — 业务主线 8 步（含异常路径），建库与设计依据
- [跨域接口契约](docs/stage1-cross-domain-interface-contract.md) — 三域之间的冻结接口：对象名、参数顺序与类型、返回列、种子常量，以及只读检查器 `sql/contract_interface_check.sql` 的校验口径
- [第一阶段三人协作实施计划](docs/stage1-three-person-implementation-plan.md) — 对象、接口、角色和验收标准
- [第二阶段三人协作实施计划](docs/stage2-three-person-implementation-plan.md) — ER 重建、规范化迁移与应用开发分工；含员工数据库身份、岗位查询接口、原子迁移/恢复、文件属主和修订自查。当前为待实施计划，第一阶段 SQL 仍为 v0.1
- [主数据数据字典](docs/主数据数据字典.md)、[订单履约数据字典](docs/订单履约数据字典.md)、[库存权限数据字典](docs/库存权限数据字典.md)
- [第一阶段测试报告](docs/stage1-test-report.md)
- 成员分工报告：[成员 A](docs/stage1-a-stage-report.md)（主数据与定价）、[成员 B](docs/stage1-b-stage-report.md)（订单与履约）、[成员 C](docs/stage1-c-stage-report.md)（库存、权限与集成）
- [AI使用记录](docs/AI使用记录.md)
