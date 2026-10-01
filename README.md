# KFC-DB

以现实 KFC 为原型的门店经营数据库课程设计项目，贯穿 17 周共 4 个阶段，让同一套库从"记录业务"逐步建设为"支持经营分析与补货决策的应用"。

## 项目范围

覆盖门店从后台准备到补货闭环的完整经营链路，按业务主线分层建设：商品/BOM/促销等主数据、订单与支付、积分两段式、防超卖库存、补货建议与采购入库，以及后续的经营分析视角。当前已完成**第一阶段关系数据库交付**：可从空库一次部署表、约束、过程、视图、种子和岗位权限，并执行 A/B/C 三域验收。

## 环境

- 数据库平台：SQL Server 2025（17.0，兼容级别不低于 130）
- 已验证实例：`localhost\MSSQLSERVER2`
- 登录方式：Windows 身份验证；部署账号需要建库权限
- 客户端：`sqlcmd`（ODBC Driver 18）或启用 SQLCMD Mode 的 SSMS

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
   - `RESULT: pass=17 fail=0`（C/权限与集成域）
4. 可另行执行只读接口检查：

   ```powershell
   sqlcmd -S "localhost\MSSQLSERVER2" -E -N o -C -f 65001 -b -i "sql/contract_interface_check.sql"
   ```

完整执行证据见 [`result/`](result/)，实验过程与结论见 [第一阶段测试报告](docs/stage1-test-report.md) 和 [成员 B 阶段报告](docs/stage1-b-stage-report.md)。

## 文档索引

- [角色与职能清单](docs/角色与职能清单.md) — 后台/作业/顾客侧角色 + 系统自动行为，供后续 role.sql / 权限设计
- [数据边界清单](docs/数据边界清单.md) — 进/不进库边界与灰色地带取舍
- [业务流程](docs/业务流程.md) — 业务主线 8 步（含异常路径），建库与设计依据
- [第一阶段三人协作实施计划](docs/stage1-three-person-implementation-plan.md) — 对象、接口、角色和验收标准
- [主数据数据字典](docs/主数据数据字典.md)、[订单履约数据字典](docs/订单履约数据字典.md)、[库存权限数据字典](docs/库存权限数据字典.md)
- [第一阶段测试报告](docs/stage1-test-report.md)、[成员 B 阶段报告](docs/stage1-b-stage-report.md)
- [AI使用记录](docs/AI使用记录.md) 
