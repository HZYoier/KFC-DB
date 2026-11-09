# A 域 JSON 接口实库证据（2026-11-09，v1.0 真实库）

> 属主：A（主数据、定价、会员）。本目录是 `app/api/` 的实库探针输出：以 `test_store_manager` 登录本机 `KFC_DB`（v1.0），逐个打 `/api/master` 的端点，记录状态码与错误体。
> 离线单测（`tests/stage2/api`，12 条，连接换成假的）单独一套，见文末。

## 环境

- 实例与库同 `result/stage2/a-master-ui/README.md`：`localhost` 上的 `KFC_DB`，由 v0.1 就地迁移到 v1.0（15 过程 / 58 权限码 / 71 行授权），`regression` 38/0。
- 探针账号：`test_store_manager`（`employee_id = 1`，`STORE_MANAGER`）。口令从本机临时文件读取，不写入仓库；文件不存在时脚本直接报错退出，不做降级。
- 探针脚本：[`tests/stage2/api/probe_api_live.py`](../../../tests/stage2/api/probe_api_live.py)，用 Flask test client 走完整请求栈（登录 → 会话 → 路由 → service → `app/common/db.py` → 真 ODBC 连接）。
- 脚本只做**不写库**的动作：取数、元数据、令牌、错令牌、非法枚举值、未知动作。没有任何一次成功写入，因此本目录不涉及数据变化。

## 复现

```powershell
# 仓库根目录；口令临时文件路径可用 KFC_PROBE_PW_FILE 覆盖
.venv\Scripts\python tests\stage2\api\probe_api_live.py > result/stage2/a-api/a-api-live-2026-11-09.txt
```

## 结果（`a-api-live-2026-11-09.txt`，11 条）

| # | 请求 | 状态 | 结论 |
| --- | --- | --- | --- |
| 1 | 登录 `test_store_manager` | — | 成功，会话里拿到 `db_login` / `db_password` |
| 2 | `GET /api/master/meta` | 200 | 9 个实体、18 个动作；`bom` / `combo` / `promotion-rule` 标记 `filterable_by_status = false` |
| 3 | `GET /api/master/product` | 200 | `rows = 6`，首行 `product_id = 1` 香辣鸡腿堡 `base_price = "19.00"`（`Decimal` 已转字符串） |
| 4 | `GET /api/master/product?status=ACTIVE` | 200 | `rows = 6`，与不带筛选一致——现有 6 个商品全是 `ACTIVE` |
| 5 | `GET /api/master/product?status=INACTIVE` | 200 | `rows = 0`，筛选参数确实下推到 `sp_list_master_records` |
| 6 | `GET /api/master/nope` | 404 | `E_NOTFOUND`，未到数据库就在路由层拒绝 |
| 7 | `GET /api/csrf` | 200 | 令牌长度 64（`token_hex(32)`） |
| 8 | `POST /api/master/product/status` 无令牌 | 403 | `E_FORBIDDEN`，未开连接 |
| 9 | 同上，`X-CSRF-Token: deadbeef` | 403 | `E_FORBIDDEN` |
| 10 | 同上，合法令牌 + `status = "BAD"` | 400 | `E_INPUT`，由 service 的枚举校验拒绝，错误码与页面路径一致 |
| 11 | `POST /api/master/product/delete`（未知动作） | 404 | `E_NOTFOUND`；全库没有删除过程，也没有删除动作 |

每个错误响应的 `request_id` 都非空，与页面路径共用 `app/common/log.py` 的同一套追踪。

## 口径与边界

- 本目录证明的是「接口层在本机 v1.0 库上按预期取数与拒绝」，**不**证明 `run-all.ps1` 已覆盖接口套件：`tests/stage2/api` 目前是独立入口，尚未并入汇总，已登记为 OI-21。
- 第 3–5 行只验证 `product` 一个实体走通全链路；其余八个实体页仍是服务端渲染，接口虽然按同一张 `ENTITIES` 表通用放行，但没有逐个实库跑——给出的是结构一致性，不是九实体的逐一实测。
- 写入路径只用「非法输入」验证了拒绝分支，没有提交任何一次合法写入（避免在真实库留测试数据）。写入的正常分支由离线套件的 `sp_create_product` / `sp_set_product_bom` 两条断言覆盖。
- 截图证据在 [`result/stage2/a-master-ui/a-master-ui-05-product-2026-11-09.png`](../a-master-ui/a-master-ui-05-product-2026-11-09.png)，该页顶部已标注取数与提交改走 `/api/master`。

## 文件

| 文件 | 说明 | SHA-256 |
| --- | --- | --- |
| `a-api-live-2026-11-09.txt` | sqlcmd 同款 `-o` 之外的探针输出（脚本自写 UTF-8，无 BOM） | `55633bbc43b65bf268c1d19bbcb3e000a8b810d558ba12937c865d17a4caff91` |
| `tests/stage2/api/probe_api_live.py` | 实库探针（手动执行，不进 `run-all`） | `3515984a3e1ef7eb447185a4036bd3d4d5813db19cffc7915a3c6b35366c5d4c` |
| `tests/stage2/api/test_api.py` | 离线单测 12 条 | `ee8378ed8d8c0ee34ffa7f4ace7b37da3c904eb71917736b633dc94597ae90b7` |

`.gitattributes` 对本目录加 `-text`，保证换行不被换行符转换改写，哈希可复核。
