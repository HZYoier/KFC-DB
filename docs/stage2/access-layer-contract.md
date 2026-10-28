# 访问层接口（`app/common/`）

> 版本：2026-10-28（草案，待 B/C 按各自域的实际调用核对；随 2.2 冻结一并定稿）
>
> 用途：计划 §6.3 要求 A 在共享契约里定义四个 Python 签名。本文是那四个名字的落点、调用口径和边界；实现在 `app/common/db.py`、`tx.py`、`errors.py`、`log.py`。**B、C 的 `dao.py` 只按本文调用，不 import pyodbc、不自己连库、不自己开事务、不新增错误码。**

## 1. 四个签名（冻结面）

| 签名 | 落点 | 语义 |
| --- | --- | --- |
| `open_connection(session=None, *, autocommit=True, config=None) -> pyodbc.Connection` | `db.py` | 唯一开连接的地方。默认 `autocommit=True` |
| `query(session, sql, params=()) -> list[dict]` | `db.py` | 只读查询，`sql` 必须是 `dao.py` 里的常量 |
| `query_procedure(session, name, params=()) -> list[dict]` | `db.py` | 调返回结果集的查询过程（§2.2 那批） |
| `execute_procedure(session, name, params=()) -> list[dict]` | `db.py` | 调写过程；过程自持事务，这里不再包 |
| `run_in_transaction(session, callback) -> Any` | `tx.py` | 同一身份同一连接上跑多个过程，全成功才提交 |

返回行统一是 `dict`（列名 → 值，列名取 `cursor.description`）；`DECIMAL` 原样回 `Decimal`，出 JSON 前过 `db.jsonable(rows)` 或 `db.as_json_value(value)`——金额转字符串，**不转 float**。

## 2. `session` 的形状

`session` 是 `Mapping`，只认三个键：

| 键 | 谁填 | 说明 |
| --- | --- | --- |
| `db_login` | C 的登录上下文 | 员工本人的数据库登录名；缺省则退回 `.env` 的部署账户 |
| `db_password` | C 的登录上下文 | 只活在该请求的内存里，不落库、不写日志 |
| `role` | C 的登录上下文 | 岗位代码，只用于日志字段 |

**每位员工必须用自己的数据库登录连接。** 员工侧过程一律按 `USER_NAME()` 映射 `EmployeeAccount`（要求 `ACTIVE`，多数还要岗位匹配），用共享的部署账户连接会让所有过程落到「操作人未映射」的 `51004`。这条与 `open-issues.md` OI-10 第 3 条（服务端员工凭据生命周期）是同一件事：口令怎么在服务端存在、什么时候丢弃，由 C 定，本文只规定 `session` 的接口形状。

顾客端的 `cust_app` 没有 `EmployeeAccount` 映射，属于另一类连接：它走 §1.1 的 `WITHOUT LOGIN` 用户，服务器端口令由部署模板单独建。应用层怎么把这份凭据交给 `open_connection`，待 OI-10 一并落定。

## 3. 参数

参数一律是 `SqlParam`（`db.py` 里的 `p_*` 构造函数），类型、长度、精度显式给出，值全部走 ODBC 占位符：

```python
p_varchar(value, size) / p_nvarchar(value, size) / p_bigint(value) / p_int(value)
p_bit(value) / p_decimal(value, precision, scale) / p_datetime(value)
```

传裸值（`str` / `int` / `None`）会直接 `TypeError`，不交给驱动猜类型。过程名只接受 `[a-z][a-z0-9_]*`，其余 `ValueError`——名字是标识符，值才是参数，两者不混。

## 4. 事务口径

- **默认 `autocommit=True`。** 库里的写过程自己判 `@@TRANCOUNT = 0` 再 `BEGIN TRANSACTION`；应用层先开了事务，过程就会走 `SAVE TRANSACTION` 分支，提交点从过程挪到应用层，回滚范围也跟着变。所以一次按钮只调一个过程时，**不要**包 `run_in_transaction`。
- `run_in_transaction` 只用于「多个过程必须原子」的情形；`callback` 里禁止另开连接去写。
- 出现不可提交事务时整笔 `ROLLBACK`，不继续使用失败事务；异常路径一定关连接（`try/finally` 已覆盖）。
- 支付后网络中断属于**结果未知**，先查订单与支付状态再决定是否重试，不自动重复写入（计划 §6.3 末段）。

## 5. 错误码

九类与 HTTP 状态见计划 §6.3，映射实现在 `errors.py` 的 `_SQL_NUMBER`：

| 数据库侧 | 应用侧 |
| --- | --- |
| `51000` / `51001` / `51002`·`51003` / `51004` / `51005` | `E_INPUT` / `E_NOTFOUND` / `E_RULE` / `E_FORBIDDEN` / `E_CONFLICT` |
| `52xxx`、C 域过程 `50000`、`53002` | `E_RULE` |
| `53000` / `53001` | `E_INPUT` / `E_NOTFOUND` |
| `229`·`262` / `2627`·`2601`·`547` / `1205`·`3930`·`3960` / `080xx`·`4060`·`18456` | `E_FORBIDDEN` / `E_CONFLICT` / `E_TX` / `E_DB` |
| 其余 | `E_INTERNAL` |

`511xx` / `519xx` 是验收脚本断言码，不进这张表；`09c` / `09d` 的部署期守卫码也不进应用路径（按「产生错误的对象」判断，不按数字段位）。新增码由 C 登记后再进 `_SQL_NUMBER`。

路由与 service **不写 try/except**：`errors.register_error_handlers` 已挂在应用上，异常统一变成 `{code, message, request_id}`，`message` 只取表里的固定文案，SQL 编号、原始消息与堆栈只进日志。

## 6. 日志

每条 JSON 一行，至少六个字段：`ts`、`request_id`、`operation`、`role`、`code`、`result`；原始原因放 `detail`。请求标识优先取请求头 `X-Request-Id`（只接受 8–36 位十六进制），否则新生成，并在响应头回写。日志与异常文本统一过口令抹除（`PWD=` / `PASSWORD=` → `***`），连接串本身不含凭据。

## 7. 依赖与驱动

`requirements.txt` 精确版本（不用范围值）：Flask 3.1.3、pyodbc 5.3.0。Python 下限 3.11，本机实测 3.13.12。驱动为 **ODBC Driver 18 for SQL Server**，三台机器同一版，连接串里显式写驱动名；Driver 18 默认强制加密，本机自签证书要在 `.env` 里 `KFC_DB_TRUST_CERT=yes`，演示环境改回 `no`。配置只从环境变量读，`.env` 不入库，仓库里只有 `config.example.env` 的形状。

## 8. 现状与待办

已验（2026-10-28，本机 `localhost`，信任连接）：`tests/stage2/check_app_common.py` 9 条 PASS——应用工厂可建、配置不含口令、视图可查、DAO 模板可跑、`DECIMAL` 转字符串、空名被应用层挡为 `E_INPUT`、库侧 `51004` 归 `E_FORBIDDEN`、口令被抹除。证据待随 2.3 一并归档到 `result/stage2/`。

待办：① C 的 `run.py` 与 `app/auth`（包里给出 `bp` 即被应用工厂自动注册，不用改 `app/__init__.py`）；② B 用 `sp_create_order` 与一次故障回滚核对事务 helper 的提交/回滚语义；③ C 定顾客端 `cust_app` 的凭据交付方式（OI-10）。

## 9. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-28 | 建立本文：A 按计划 §6.3 交出 `app/common/` 底座，固定四个签名、`session` 形状、参数定型、事务口径、错误码映射与日志字段；本机冒烟 9 条 PASS |
