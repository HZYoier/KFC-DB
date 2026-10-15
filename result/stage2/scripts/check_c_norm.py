# -*- coding: utf-8 -*-
"""c-normalization 对账脚本（2026-10-15，成员 C）。

核对对象：
  A. docs/stage2/c-normalization.md §2 属性与键清单 <-> sql/03_inventory_security_schema.sql
     （表名、列名、类型、可空、主键/唯一键/外键/默认值约束名、IDENTITY、过滤唯一索引）
  B. 文档声明的统计量（10 表 / 56 列 / 3 复合主键 / 16+1 外键 / 15 条 CHECK ...）逐项重算
  C. 文档引用的 R6-xx / I-Cxx 编号在对应文件中存在
  D. docs/er/c-inventory-security.drawio 的实体与主键标注与 sql/03 一致
用法：python -I check_c_norm.py  （0 差异 = PASS）
"""
import re

ROOT = r'D:\DBLab\KFC-DB'
DOC = ROOT + r'\docs\stage2\c-normalization.md'
S03 = ROOT + r'\sql\03_inventory_security_schema.sql'
S06 = ROOT + r'\sql\06_inventory_constraints_crud.sql'
CIS = ROOT + r'\docs\stage2\c-issues.md'
SRC = ROOT + r'\docs\stage2\source-requirements.md'
DRAWIO = ROOT + r'\docs\er\c-inventory-security.drawio'

def read(p):
    return open(p, encoding='utf-8').read()

problems = []
def report(ok, msg):
    tag = 'PASS' if ok else 'FAIL'
    if not ok:
        problems.append(msg)
    print(f'[{tag}] {msg}')

# ---------- A. 解析 sql/03 ----------
s03 = read(S03)
src = {}
for name, body in re.findall(r'CREATE TABLE dbo\.(\w+)\((.*?)\n\);', s03, re.S):
    src[name] = {'cols': {}, 'pk': {}, 'uq': {}, 'fk': {}, 'df': {}}
    cur = None
    for ln in body.split('\n'):
        if not ln.strip():
            continue
        mc = re.match(r'^    ([A-Za-z_]\w*)\s+(.*)$', ln)
        if mc and mc.group(1) not in ('CONSTRAINT', 'PRIMARY', 'UNIQUE', 'FOREIGN'):
            col, rest = mc.group(1), mc.group(2).strip().rstrip(',')
            tm = re.match(r'^([A-Za-z0-9_]+(?:\([^)]*\))?)\s*(.*)$', rest)
            typ, tail = tm.group(1), tm.group(2)
            nullable = ('NOT NULL' not in tail) and re.search(r'\bNULL\b', tail) is not None
            src[name]['cols'][col] = {
                'type': typ, 'nullable': nullable,
                'identity': 'IDENTITY' in rest, 'pk': False, 'df': None}
            cur = col
            continue
        m8 = re.match(r'^        CONSTRAINT (PK_\w+)\s+PRIMARY KEY\b(?!\s*\()', ln)
        if m8 and cur:
            src[name]['pk'][m8.group(1)] = [cur]
            src[name]['cols'][cur]['pk'] = True
            continue
        m8d = re.match(r'^        CONSTRAINT (DF_\w+)\s+DEFAULT \(([^)]*)\)', ln)
        if m8d and cur:
            src[name]['df'][m8d.group(1)] = cur
            src[name]['cols'][cur]['df'] = m8d.group(1)
            continue
    for m in re.finditer(r'CONSTRAINT (PK_\w+)\s+PRIMARY KEY(?:\s*\(([^)]+)\))?', body):
        if m.group(2):
            cols = [c.strip() for c in m.group(2).split(',')]
            src[name]['pk'][m.group(1)] = cols
            for c in cols:
                src[name]['cols'][c]['pk'] = True
    for m in re.finditer(r'CONSTRAINT (UQ_\w+)\s+UNIQUE \(([^)]+)\)', body):
        src[name]['uq'][m.group(1)] = [c.strip() for c in m.group(2).split(',')]
    for m in re.finditer(r'CONSTRAINT (FK_\w+)\s+FOREIGN KEY \((\w+)\)\s+REFERENCES dbo\.(\w+)\((\w+)\)', body):
        src[name]['fk'][m.group(1)] = (m.group(2), m.group(3), m.group(4))

# 过滤唯一索引（不是约束）
uidx = {}
for m in re.finditer(r'CREATE UNIQUE INDEX (UQ_\w+)\s+ON dbo\.(\w+)\((\w+)\)\s*WHERE', s03):
    uidx[m.group(1)] = (m.group(2), m.group(3))
# 03 末尾对 Delivery 的外键
m_del = re.search(r'ALTER TABLE dbo\.Delivery\s+ADD CONSTRAINT (FK_\w+)\s+FOREIGN KEY \((\w+)\)\s+REFERENCES dbo\.(\w+)\((\w+)\)', s03)
delivery_fk = m_del.group(1) if m_del else None

c_tables = ['EmployeeAccount', 'BusinessRole', 'EmployeeBusinessRole', 'RolePermission',
            'Inventory', 'InventoryMovement', 'ReplenishmentSuggestion',
            'PurchaseOrder', 'PurchaseOrderItem', 'AuditLog']
report(sorted(src.keys()) == sorted(c_tables), f'A1 源码表集合 == 10 张 C 域表（实得 {sorted(src.keys())}）')
n_cols = sum(len(t['cols']) for t in src.values())
n_pk = sum(len(t['pk']) for t in src.values())
comp_pk = [k for k, t in src.items() if any(len(v) > 1 for v in t['pk'].values())]
n_uq = sum(len(t['uq']) for t in src.values())
n_fk = sum(len(t['fk']) for t in src.values())
pkfk = [c for k, t in src.items() for c in t['cols'] if t['cols'][c]['pk']
        and any(fk[0] == c for fk in t['fk'].values())]
print(f'源码统计: 表={len(src)} 列={n_cols} 主键={n_pk} 复合主键={sorted(comp_pk)} '
      f'UQ约束={n_uq} 过滤唯一索引={len(uidx)} C域外键={n_fk} PKFK列={pkfk} Delivery外键={delivery_fk}')
report(n_cols == 56, f'A2 总列数 56（实得 {n_cols}）')
report(sorted(comp_pk) == ['EmployeeBusinessRole', 'PurchaseOrderItem', 'RolePermission'],
       f'A3 复合主键 3 张（实得 {sorted(comp_pk)}）')
report(n_fk == 16 and n_uq == 4 and len(uidx) == 1,
       f'A4 16 条 C 域外键 / 4 个 UQ 约束 / 1 个过滤唯一索引（实得 {n_fk}/{n_uq}/{len(uidx)}）')

# ---------- A2. 解析文档 §2 ----------
doc = read(DOC)
rows = re.findall(r'^\| `(\w+)` \| `(\w+)` \| `([^`]+)` \| (否|是) \| ([^|]*)\|\r?$', doc, re.M)
dcols = {}
for tbl, col, typ, nullable, rest in rows:
    toks = set(re.findall(r'(?:PK|UQ|FK|DF)_\w+', rest))
    ftar = set(re.findall(r'→ `(\w+)\(', rest))
    dcols.setdefault(tbl, {})[col] = {
        'type': typ, 'nullable': nullable == '是', 'identity': 'IDENTITY' in rest,
        'toks': toks, 'fk_targets': ftar}
report(set(dcols.keys()) == set(c_tables), f'A5 文档 §2 含全部 10 表（实得 {sorted(dcols.keys())}）')

# 逐表逐列对比
for tbl in c_tables:
    scols, dcols_t = src[tbl]['cols'], dcols.get(tbl, {})
    if set(scols) != set(dcols_t):
        report(False, f'A6.{tbl} 列集合差异: 源码独有={sorted(set(scols)-set(dcols_t))} 文档独有={sorted(set(dcols_t)-set(scols))}')
    else:
        report(True, f'A6.{tbl} 列集合一致（{len(scols)} 列）')
    for col in sorted(set(scols) & set(dcols_t)):
        s, d = scols[col], dcols_t[col]
        if s['type'] != d['type']:
            report(False, f'A7.{tbl}.{col} 类型: 源码 {s["type"]} vs 文档 {d["type"]}')
        if s['nullable'] != d['nullable']:
            report(False, f'A8.{tbl}.{col} 可空: 源码 {s["nullable"]} vs 文档 {d["nullable"]}')
        if s['identity'] != d['identity']:
            report(False, f'A9.{tbl}.{col} IDENTITY: 源码 {s["identity"]} vs 文档 {d["identity"]}')
    # 结构约束名集合（PK/UQ/FK/DF/过滤索引）
    src_toks = set(src[tbl]['pk']) | set(src[tbl]['uq']) | set(src[tbl]['fk']) | set(src[tbl]['df'])
    for nm, (t, c) in uidx.items():
        if t == tbl:
            src_toks.add(nm)
    doc_toks = set()
    for col in dcols_t:
        doc_toks |= dcols_t[col]['toks']
    if src_toks != doc_toks:
        report(False, f'A10.{tbl} 结构约束名差异: 源码独有={sorted(src_toks-doc_toks)} 文档独有={sorted(doc_toks-src_toks)}')
    else:
        report(True, f'A10.{tbl} 结构约束名一致（{len(src_toks)} 项）')
    # FK 目标表
    fk_targets_src = set(fk[1] for fk in src[tbl]['fk'].values())
    fk_targets_doc = set()
    for col in dcols_t:
        fk_targets_doc |= dcols_t[col]['fk_targets']
    if fk_targets_src != fk_targets_doc:
        report(False, f'A11.{tbl} FK 目标表差异: 源码={sorted(fk_targets_src)} 文档={sorted(fk_targets_doc)}')

# ---------- B. 06 CHECK 与统计口径 ----------
s06 = read(S06)
cks = re.findall(r'ADD CONSTRAINT (CK_\w+)', s06)
report(len(cks) == 15, f'B1 06 命名 CHECK 共 15 条（实得 {len(cks)}）')
report('15 条命名 `CHECK` 全部在 `06`' in doc or '15 条命名 `CHECK`' in doc, 'B2 文档声明 15 条 CHECK 与源码一致')
b1_start = s06.index('-- 批次 1')
b1_end = s06.index('\nGO', b1_start)
ck_before = re.findall(r'ADD CONSTRAINT (CK_\w+)', s06[b1_start:b1_end])
report(len(ck_before) == 15, f'B3 15 条 CHECK 全部位于批次 1（批次 1 注释至其后首个 GO）（实得 {len(ck_before)}）')

# ---------- E. 可空列计数、09c 种子统计、permission_name 引用面 ----------
n_nullable = sum(1 for t in src.values() for c in t['cols'].values() if c['nullable'])
report(n_nullable == 8, f'E1 源码可空列共 8（实得 {n_nullable}）')
report('**8 个可空列**' in doc and '可空列共 8 个' in doc, 'E1b 文档两处 8 个可空列口径一致')

s09c = read(ROOT + r'\sql\09c_inventory_opening_seed_data.sql')
vals = re.findall(r"\('(\w+)', '(sp_\w+|v_\w+|fn_\w+)',\s+N'([^']+)'\)", s09c)
codes = {}
for role, code, name in vals:
    codes.setdefault(code, set()).add(name)
report(len(vals) == 52, f'E2 09c 授权映射 52 行（实得 {len(vals)}）')
report(len(codes) == 46, f'E3 权限码 46 个（实得 {len(codes)}）')
multi = {c: sorted(n) for c, n in codes.items() if len(n) > 1}
report(not multi, f'E4 每码名称唯一（多名: {multi}）')

mwl = re.search(r'CHECK \(\s*permission_code IN \((.*?)\)\s*\)', s06, re.S)
wl = set(re.findall(r"'(\w+)'", mwl.group(1)))
report(len(wl) == 46, f'E5 白名单 46 项（实得 {len(wl)}）')
report(set(codes) == wl, f'E5b 种子码集合 == 白名单集合（差: 种独有={sorted(set(codes)-wl)} 白独有={sorted(wl-set(codes))}）')

import glob, os
hits = {}
for f in glob.glob(ROOT + r'\sql\*.sql'):
    txt = read(f)
    if 'permission_name' in txt:
        hits[os.path.basename(f)] = txt.count('permission_name')
report(set(hits) == {'03_inventory_security_schema.sql', '09c_inventory_opening_seed_data.sql'},
       f'E6 permission_name 仅出现于 03/09c（实得 {hits}）')

# ---------- C. 交叉引用 ----------
src_req = read(SRC)
c_iss = read(CIS)
r6_refs = sorted(set(re.findall(r'R6-(\d+)', doc)))
bad_r6 = [r for r in r6_refs if f'R6-{r}' not in src_req]
report(not bad_r6, f'C1 文档引用的 R6 编号均存在（缺: {bad_r6}）')
ic_refs = sorted(set(re.findall(r'I-C(\d+)', doc)))
bad_ic = [i for i in ic_refs if f'I-C{i}' not in c_iss]
report(not bad_ic, f'C2 文档引用的 I-C 编号均存在（缺: {bad_ic}）')
ck_refs = sorted(set(re.findall(r'`(CK_\w+)`', doc)))
bad_ck = [c for c in ck_refs if c not in cks]
report(not bad_ck, f'C3 文档引用的 CK 约束名均在 06（缺: {bad_ck}）')

# ---------- D. ER 子图核对 ----------
drawio = read(DRAWIO)
cells = re.findall(r'value="([^"]*)"', drawio)
entities = {}
for v in cells:
    v2 = v.replace('&lt;', '<').replace('&gt;', '>').replace('&amp;', '&')
    if '<b>' not in v2:
        continue
    lines = v2.split('<br>')
    name = re.sub(r'</?b>', '', lines[0]).strip()
    entities[name] = lines[1:]
c_ent = [e for e in entities if e in c_tables]
report(sorted(c_ent) == sorted(c_tables), f'D1 子图含全部 10 张 C 域实体（实得 {sorted(c_ent)}）')
print(f'子图实体总数 = {len(entities)}：{sorted(entities.keys())}')
for tbl in c_tables:
    if tbl not in entities:
        continue
    pk_marked = set()
    for ln in entities[tbl]:
        m = re.match(r'^(PK|PKFK)\s+(\w+)', ln.strip())
        if m:
            pk_marked.add(m.group(2))
    pk_src = set(c for pkc in src[tbl]['pk'].values() for c in pkc)
    if pk_marked != pk_src:
        report(False, f'D2.{tbl} 子图主键标注差异: 子图={sorted(pk_marked)} 源码={sorted(pk_src)}')
    else:
        report(True, f'D2.{tbl} 子图主键标注一致（{sorted(pk_marked)}）')

print()
if problems:
    print(f'== 结果: {len(problems)} 项差异 ==')
    for p in problems:
        print(' -', p)
else:
    print('== 结果: 0 差异（全部通过）==')
