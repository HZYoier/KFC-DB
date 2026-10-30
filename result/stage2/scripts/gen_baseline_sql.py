# -*- coding: utf-8 -*-
"""按 v0.1 源码形状生成 baseline_c.sql（提交）与 A/B 临时桩（仓库外，用于框架测试）。"""
import re, os

ROOT = r'D:\DBLab\KFC-DB'
TMP = r'D:\DBLab\_kfcdb_tmp'

def read(p):
    return open(os.path.join(ROOT, p), encoding='utf-8').read()

def strip_comments(t):
    return re.sub(r'--[^\n]*', '', t)

TYPE_RE = re.compile(r'(?i)^(BIGINT|INT|SMALLINT|TINYINT|BIT|DECIMAL\s*\(\s*\d+\s*,\s*\d+\s*\)|NUMERIC\s*\(\s*\d+\s*,\s*\d+\s*\)|VARCHAR\s*\(\s*\d+\s*\)|NVARCHAR\s*\(\s*(?:\d+|MAX)\s*\)|CHAR\s*\(\s*\d+\s*\)|DATETIME2\s*\(\s*\d+\s*\)|DATETIME|DATE|TIME\s*\(\s*\d+\s*\))')

def norm_type(s):
    s = re.sub(r'\s+', '', s).upper()
    if s.startswith('NVARCHAR(MAX)'):
        return 'NVARCHAR(MAX)'
    return s

def parse_file(path):
    t = strip_comments(read(path))
    out = {}
    for m in re.finditer(r'(?is)create\s+table\s+(?:dbo\.)?(\w+)\s*\(\s*\n(.*?)\n\s*\)\s*;?', t):
        name, body = m.group(1), m.group(2)
        cols, order, last = {}, [], None
        for ln in body.split('\n'):
            s = ln.strip()
            if not s:
                continue
            if re.match(r'(?i)^constraint\s+PK_\w+\s+primary\s+key\s*[,]?\s*$', s) and last:
                cols[last]['pk'] = True
                continue
            if re.match(r'(?i)^(constraint|primary|foreign|references|unique)\b', s):
                continue
            mc = re.match(r'^\[?([A-Za-z_]\w*)\]?\s+(.*)$', s)
            if not mc:
                continue
            col, rest = mc.group(1), mc.group(2)
            tm = TYPE_RE.match(rest)
            if not tm:
                continue
            typ = norm_type(tm.group(1))
            cols[col] = {'type': typ,
                         'nullable': ('not null' not in rest.lower()),
                         'pk': bool(re.search(r'(?i)constraint\s+PK_\w+\s+primary\s+key', rest))}
            order.append(col)
            last = col
        pk = [c for c in order if cols[c]['pk']]
        for pm in re.finditer(r'(?i)constraint\s+PK_\w+\s+primary\s+key\s*\(([^)]*)\)', body):
            for c in pm.group(1).split(','):
                c = c.strip()
                if c in cols and c not in pk:
                    pk.append(c)
        for c in pk:
            cols[c]['nullable'] = False
        out[name] = {'cols': cols, 'order': order, 'pk': pk}
    return out

M = {}
for f in ('sql/01_master_schema.sql', 'sql/02_order_schema.sql', 'sql/03_inventory_security_schema.sql'):
    M.update(parse_file(f))

A = ['Category', 'MemberLevel', 'Ingredient', 'Product', 'ProductCategory', 'Customer',
     'ProductBom', 'ComboComponent', 'Promotion', 'PromotionProductRule']
B = ['SalesOrder', 'SalesOrderItem', 'Payment', 'Delivery', 'PointLedger']
C = ['Inventory', 'InventoryMovement', 'ReplenishmentSuggestion', 'PurchaseOrder', 'PurchaseOrderItem',
     'EmployeeAccount', 'BusinessRole', 'EmployeeBusinessRole', 'RolePermission', 'AuditLog']

def q(name):
    return '[' + name + ']'

def gen(tables, header):
    parts = [header, '']
    for t in tables:
        d = M[t]
        cols = ['batch_id BIGINT NOT NULL']
        for c in d['order']:
            nn = 'NOT NULL' if not d['cols'][c]['nullable'] else 'NULL'
            cols.append('%s %s %s' % (q(c), d['cols'][c]['type'], nn))
        pk = ['batch_id'] + [q(c) for c in d['pk']]
        body = ',\n        '.join(cols)
        parts.append("IF OBJECT_ID(N'dbo.Baseline_%s', N'U') IS NULL\nBEGIN\n    CREATE TABLE dbo.Baseline_%s (\n        %s,\n        CONSTRAINT PK_Baseline_%s PRIMARY KEY (%s)\n    );\nEND;" % (t, t, body, t, ', '.join(pk)))
        parts.append('')
    for t in tables:
        d = M[t]
        collist = ', '.join(['batch_id'] + [q(c) for c in d['order']])
        parts.append('INSERT INTO dbo.Baseline_%s (%s)\nSELECT @batch_id, %s FROM dbo.%s;' % (
            t, collist, ', '.join(q(c) for c in d['order']), t))
        parts.append('')
    return '\n'.join(parts) + '\n'

header_c = '''-- ============================================================================
-- baseline_c.sql — C 域基线采集（库存/权限/审计 10 表）
-- 负责人：C；2026-10-30 建立。协议见 docs/stage2/migration-guide.md §2.5/§3。
-- 由 capture_baseline.sql 在采集事务内 :r 执行；不得含 GO、不得开/提交事务、
-- 不得用临时表；@batch_id 由入口声明。仅创建/写入 dbo.Baseline_<Table> 快照表。
-- ============================================================================
'''
header_a = '''-- TEMPORARY test stub for baseline_a (A domain) — NOT part of the repo.
-- Generated from sql/01 for framework testing only.
'''
header_b = '''-- TEMPORARY test stub for baseline_b (B domain) — NOT part of the repo.
-- Generated from sql/01/02 for framework testing only.
'''

os.makedirs(os.path.join(ROOT, 'sql', 'stage2'), exist_ok=True)
for path, tables, header in [
    (os.path.join(ROOT, 'sql', 'stage2', 'baseline_c.sql'), C, header_c),
    (os.path.join(TMP, 'baseline_a_stub.sql'), A, header_a),
    (os.path.join(TMP, 'baseline_b_stub.sql'), B, header_b),
]:
    data = gen(tables, header).replace('\n', '\r\n').encode('utf-8')
    open(path, 'wb').write(data)
    print('written', path, len(data), 'bytes')

for t in A + B + C:
    print('%-24s cols=%2d pk=%s' % (t, len(M[t]['order']), ','.join(M[t]['pk'])))
