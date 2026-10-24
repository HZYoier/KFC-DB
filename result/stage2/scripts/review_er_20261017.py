# -*- coding: utf-8 -*-
"""C 侧独立复核两张 ER 子图（2026-10-17）。

核对内容：
  A. 实体集合与键标注 vs sql/01（A 域 10 表）+ 跨域灰实体的键 vs sql/02/03。
  B. 边集合：每条边必须对应一条真实外码（无幽灵边、无漏边）。
  C. 箭头语义（标准鸦爪口径：某端符号 = 对端每条记录对应本端多少条）：
       父端 = ERone（外码非空）/ ERzeroToOne（外码可空）；
       子端 = ERzeroToOne（外码列恰为子表主码）/ ERzeroToMany（否则）。
  D. A 域实体属性名集合 vs sql/01 列集合（仅 A 域 10 表）。
  E. 共享实体的同名同键列（A 图主实体 vs C 图灰实体，以及 C 域三表在 A 图中）。
输入：sql/01,02,03；docs/er/a-master.drawio；docs/er/c-inventory-security.drawio
"""
import re, html, os

ROOT = r'D:\DBLab\KFC-DB'
problems = []
def rep(ok, msg):
    if not ok:
        problems.append(msg)
    print(('[PASS] ' if ok else '[FAIL] ') + msg)

def read(p):
    return open(p, encoding='utf-8').read()

# ---------- 解析 sql 建表（宽容版：01/02/03 三种书写风格） ----------
def parse_schema(path):
    t = read(path)
    out = {}
    for m in re.finditer(r'(?is)\bcreate\s+table\s+(?:dbo\.)?(\w+)\s*\(\s*\n(.*?)\n\s*\)\s*;?', t):
        name, body = m.group(1), m.group(2)
        cols, pk_names, pk, uq, fk = {}, [], set(), {}, {}
        cur = None
        body = re.sub(r'--[^\n]*', '', body)  # 剥离行尾注释
        for ln in body.split('\n'):
            if not ln.strip():
                continue
            low = ln.strip().lower()
            if low.startswith('constraint'):
                pm = re.match(r'(?i)constraint\s+(PK_\w+)\s+primary\s+key(?:\s*\(([^)]*)\))?', ln.strip())
                if pm and not pm.group(2) and cur:
                    pk.add(cur)
                if pm and pm.group(2):
                    for c in pm.group(2).split(','):
                        pk.add(c.strip())
                continue
            mc = re.match(r'^\s+\[?([A-Za-z_]\w*)\]?\s+(.*)$', ln)
            if mc and mc.group(1).lower() not in ('constraint', 'primary', 'unique', 'foreign'):
                col, rest = mc.group(1), mc.group(2)
                cols[col] = {'nullable': 'not null' not in rest.lower()}
                if re.search(r'(?i)constraint\s+PK_\w+\s+primary\s+key', rest):
                    pk.add(col)
                cur = col
        for pm in re.finditer(r'(?i)constraint\s+(PK_\w+)\s+primary\s+key(?:\s*\(([^)]*)\))?', body):
            if pm.group(2):
                for c in pm.group(2).split(','):
                    pk.add(c.strip())
        for um in re.finditer(r'(?i)(?:constraint\s+)?(UQ_\w+)\s+unique(?:\s*\(([^)]*)\))?', body):
            if um.group(2):
                uq[um.group(1)] = [c.strip() for c in um.group(2).split(',')]
        for fm in re.finditer(r'(?i)constraint\s+(FK_\w+)\s+foreign\s+key\s*\((\w+)\)\s*references\s+(?:dbo\.)?(\w+)\s*\((\w+)\)', body):
            fk[fm.group(1)] = (fm.group(2), fm.group(3), fm.group(4))
        for c in pk:
            if c in cols:
                cols[c]['nullable'] = False
        out[name] = {'cols': cols, 'pk': pk, 'uq': uq, 'fk': fk}
    return out

s01 = parse_schema(ROOT + r'\sql\01_master_schema.sql')
s02 = parse_schema(ROOT + r'\sql\02_order_schema.sql')
s03 = parse_schema(ROOT + r'\sql\03_inventory_security_schema.sql')
allT = {}
for s in (s01, s02, s03):
    allT.update(s)
# 03 末尾的 ALTER TABLE ... ADD CONSTRAINT 外码（Delivery 骑手）
t03 = read(ROOT + r'\sql\03_inventory_security_schema.sql')
for m in re.finditer(r'(?is)alter\s+table\s+dbo\.(\w+)\s+add\s+constraint\s+(FK_\w+)\s+foreign\s+key\s*\((\w+)\)\s*references\s+dbo\.(\w+)\s*\((\w+)\)', t03):
    tbl, fkname, fcol, reftbl, refcol = m.groups()
    allT[tbl]['fk'][fkname] = (fcol, reftbl, refcol)

# ---------- 解析 drawio ----------
def parse_drawio(path):
    t = read(path)
    id2name, ents, edges = {}, {}, []
    for m in re.finditer(r'<mxCell[^>]*value="([^"]*)"[^>]*vertex="1"[^>]*>', t):
        tag = m.group(0)
        cid = re.search(r'id="([^"]*)"', tag).group(1)
        v = html.unescape(m.group(1))
        name = re.sub(r'</?b>', '', v.split('<br>')[0]).strip()
        attrs = v.split('<br>')[1:]
        plain = name.split('（')[0].strip()
        id2name[cid] = plain
        ents[plain] = {'raw': name, 'attrs': attrs}
    for m in re.finditer(r'<mxCell[^>]*edge="1"[^>]*>', t):
        tag = m.group(0)
        eid = re.search(r'id="([^"]*)"', tag).group(1)
        src = re.search(r'source="([^"]*)"', tag)
        tgt = re.search(r'target="([^"]*)"', tag)
        style = re.search(r'style="([^"]*)"', tag).group(1)
        val = re.search(r'value="([^"]*)"', tag)
        edges.append({
            'id': eid,
            's': id2name.get(src.group(1)) if src else None,
            't': id2name.get(tgt.group(1)) if tgt else None,
            'sa': (re.search(r'startArrow=(\w+)', style) or [None, None])[1] if re.search(r'startArrow=(\w+)', style) else None,
            'ea': (re.search(r'endArrow=(\w+)', style) or [None, None])[1] if re.search(r'endArrow=(\w+)', style) else None,
            'label': html.unescape(val.group(1)) if val else '',
        })
    return ents, edges

a_ents, a_edges = parse_drawio(ROOT + r'\docs\er\a-master.drawio')
c_ents, c_edges = parse_drawio(ROOT + r'\docs\er\c-inventory-security.drawio')
# 图例盒与标题盒不是实体
for junk in list(a_ents):
    if junk.startswith('端点符号'):
        del a_ents[junk]
for junk in list(c_ents):
    if junk.startswith('C 域（库存') or junk.startswith('端点符号'):
        del c_ents[junk]

# ---------- A. 实体与键 ----------
a_domain = ['Category', 'MemberLevel', 'Ingredient', 'Product', 'ProductCategory',
            'Customer', 'ProductBom', 'ComboComponent', 'Promotion', 'PromotionProductRule']
report_entities = []
for tbl in a_domain:
    if tbl not in a_ents:
        rep(False, 'A 图缺实体 %s' % tbl)
        continue
    pk_marked = set()
    for ln in a_ents[tbl]['attrs']:
        m = re.match(r'^(PK|PKFK)\s+(\w+)', ln.strip())
        if m:
            pk_marked.add(m.group(2))
    rep(pk_marked == s01[tbl]['pk'], 'A 域实体 %s 主键标注 == sql/01（图=%s 源=%s）' % (tbl, sorted(pk_marked), sorted(s01[tbl]['pk'])))
gray_expect = ['Inventory', 'ReplenishmentSuggestion', 'PurchaseOrderItem', 'SalesOrder', 'PointLedger', 'SalesOrderItem']
rep(set(a_ents) == set(a_domain) | set(gray_expect), 'A 图实体集合 == 10 A 表 + 6 灰实体（实得 %d）' % len(a_ents))
for tbl in gray_expect:
    if tbl not in a_ents:
        rep(False, 'A 图缺灰实体 %s' % tbl)
        continue
    pk_marked = set()
    for ln in a_ents[tbl]['attrs']:
        m = re.match(r'^(PK|PKFK)\s+(\w+)', ln.strip())
        if m:
            pk_marked.add(m.group(2))
    rep(pk_marked == allT[tbl]['pk'], '灰实体 %s 主键标注 == 源（图=%s 源=%s）' % (tbl, sorted(pk_marked), sorted(allT[tbl]['pk'])))

# ---------- D. A 域属性名集合 ----------
for tbl in a_domain:
    attrs = set()
    for ln in a_ents[tbl]['attrs']:
        m = re.match(r'^(?:PKFK|PK|UK|FK)?\s*\[?(\w+)\]?', ln.strip())
        if m:
            attrs.add(m.group(1))
    src_cols = set(s01[tbl]['cols'])
    rep(attrs == src_cols, 'A 域实体 %s 属性名集合 == sql/01 列（差: 图独有=%s 源独有=%s）' % (tbl, sorted(attrs - src_cols), sorted(src_cols - attrs)))

# ---------- B/C. 边与箭头 ----------
def expected_arrows(child_tbl, fk_cols):
    fk = allT[child_tbl]['fk']
    # 找到引用该 child 的指定外码（按列匹配）
    matches = [v for v in fk.values() if v[0] in fk_cols]
    if not matches:
        return None, None
    nullable = allT[child_tbl]['cols'][matches[0][0]]['nullable']
    parent_end = 'ERzeroToOne' if nullable else 'ERone'
    child_pk = allT[child_tbl]['pk']
    child_end = 'ERzeroToOne' if child_pk == set(fk_cols) else 'ERzeroToMany'
    return parent_end, child_end

def check_edges(label, ents, edges, fk_pairs, notes=None):
    """fk_pairs: list of (parent, child, [fk col sets]) —— 每个元素恰对应图中一条边。
    notes: {edge_id: 说明} —— 已知口径分歧/多外码合并，打印 INFO 不算失败。"""
    notes = notes or {}
    used = set()
    for parent, child, colsets in fk_pairs:
        hit = [e for e in edges if e['id'] not in used and e['s'] == parent and e['t'] == child]
        if not hit:
            rep(False, '%s 缺边 %s -> %s' % (label, parent, child))
            continue
        e = hit[0]
        used.add(e['id'])
        if e['id'] in notes:
            print('[INFO] %s 边 %s（%s->%s）[%s -> %s]：%s' % (label, e['id'], parent, child, e['sa'], e['ea'], notes[e['id']]))
            continue
        exp = expected_arrows(child, colsets[0])
        rep(e['sa'] == exp[0] and e['ea'] == exp[1],
            '%s 边 %s（%s->%s）箭头 [%s -> %s] == 期望 [%s -> %s]' % (label, e['id'], parent, child, e['sa'], e['ea'], exp[0], exp[1]))
    rep(len(used) == len(edges), '%s 边覆盖：%d 条边全部对应真实外码（未用 %d）' % (label, len(edges), len(edges) - len(used)))

# A 图：内部 9 外码 + 入向 7 外码 = 16 条边
a_fk_pairs = [
    ('Category', 'ProductCategory', [{'category_id'}]),
    ('Product', 'ProductCategory', [{'product_id'}]),
    ('Product', 'ComboComponent', [{'combo_product_id'}]),
    ('Product', 'ComboComponent', [{'child_product_id'}]),
    ('Product', 'ProductBom', [{'product_id'}]),
    ('Ingredient', 'ProductBom', [{'ingredient_id'}]),
    ('MemberLevel', 'Customer', [{'member_level_id'}]),
    ('Promotion', 'PromotionProductRule', [{'promotion_id'}]),
    ('Product', 'PromotionProductRule', [{'product_id'}]),
    ('Customer', 'SalesOrder', [{'customer_id'}]),
    ('Customer', 'PointLedger', [{'customer_id'}]),
    ('Product', 'SalesOrderItem', [{'product_id'}]),
    ('Ingredient', 'Inventory', [{'ingredient_id'}]),
    ('Ingredient', 'ReplenishmentSuggestion', [{'ingredient_id'}]),
    ('Ingredient', 'PurchaseOrderItem', [{'ingredient_id'}]),
    ('Promotion', 'SalesOrderItem', [{'promotion_id'}]),
]
check_edges('A 图', a_ents, a_edges, a_fk_pairs)

# C 图：C 域 16 外码 + Delivery 骑手 1 条；r11 是 4 条员工外码合并
c_fk_pairs = [
    ('Ingredient', 'Inventory', [{'ingredient_id'}]),
    ('Inventory', 'InventoryMovement', [{'ingredient_id'}]),
    ('Ingredient', 'ReplenishmentSuggestion', [{'ingredient_id'}]),
    ('Ingredient', 'PurchaseOrderItem', [{'ingredient_id'}]),
    ('ReplenishmentSuggestion', 'PurchaseOrder', [{'replenishment_suggestion_id'}]),
    ('PurchaseOrder', 'PurchaseOrderItem', [{'purchase_order_id'}]),
    ('BusinessRole', 'RolePermission', [{'business_role_id'}]),
    ('EmployeeAccount', 'EmployeeBusinessRole', [{'employee_id'}]),
    ('BusinessRole', 'EmployeeBusinessRole', [{'business_role_id'}]),
    ('EmployeeAccount', 'EmployeeBusinessRole', [{'assigned_by_employee_id'}]),
    ('EmployeeAccount', 'ReplenishmentSuggestion', [{'created_by_employee_id'}]),
    ('EmployeeAccount', 'PurchaseOrder', [{'approved_by_employee_id'}]),
    ('EmployeeAccount', 'Delivery', [{'rider_employee_id'}]),
    ('EmployeeAccount', 'AuditLog', [{'employee_id'}]),
]
check_edges('C 图', c_ents, c_edges, c_fk_pairs, notes={
    'r11': '4 条员工外码合并为一条边（created_by 非空 + 三个审批人可空），按标签人工判断',
    'r6': '已知口径分歧（OI-09）：按现图例「参与约束按业务规则」画 ERoneToMany（业务恰好 1 条）；A 的图按「结构口径」画。待 B 冻结基数口径后统一',
})
rep(len(c_edges) == 14, 'C 图边数 14（实得 %d）' % len(c_edges))
rep(len(a_edges) == 16, 'A 图边数 16（实得 %d）' % len(a_edges))

# ---------- E. 共享实体同名同键列 ----------
# 1) Ingredient：A 图主实体 vs C 图灰实体
a_ing_pk = {re.match(r'^(?:PK|PKFK)\s+(\w+)', x.strip()).group(1) for x in a_ents['Ingredient']['attrs'] if re.match(r'^(PK|PKFK)\s+', x.strip())}
c_ing_pk = {re.match(r'^(?:PK|PKFK)\s+(\w+)', x.strip()).group(1) for x in c_ents['Ingredient']['attrs'] if re.match(r'^(PK|PKFK)\s+', x.strip())}
rep(a_ing_pk == c_ing_pk, '共享实体 Ingredient 主键一致（A=%s C=%s）' % (sorted(a_ing_pk), sorted(c_ing_pk)))
# 2) C 域三表在 A 图中的灰实体 vs C 图主实体的主键
for tbl, cname in [('Inventory', 'Inventory'), ('ReplenishmentSuggestion', 'ReplenishmentSuggestion'), ('PurchaseOrderItem', 'PurchaseOrderItem')]:
    def pkof(attrs):
        return {re.match(r'^(?:PK|PKFK)\s+(\w+)', x.strip()).group(1) for x in attrs if re.match(r'^(PK|PKFK)\s+', x.strip())}
    rep(pkof(a_ents[tbl]['attrs']) == pkof(c_ents[cname]['attrs']), '共享实体 %s 主键一致（A 图灰=%s，C 图=%s）' % (tbl, sorted(pkof(a_ents[tbl]['attrs'])), sorted(pkof(c_ents[cname]['attrs']))))
# 3) 三条跨域联系箭头一致性（A 图 r13/r14/r15 vs C 图 r1/r3/r4）
pairs = [('Ingredient->Inventory', 'r13', 'r1'), ('Ingredient->ReplenishmentSuggestion', 'r14', 'r3'), ('Ingredient->PurchaseOrderItem', 'r15', 'r4')]
for name, aid, cid in pairs:
    ae = [e for e in a_edges if e['id'] == aid][0]
    ce = [e for e in c_edges if e['id'] == cid][0]
    rep((ae['sa'], ae['ea']) == (ce['sa'], ce['ea']), '跨域联系 %s 箭头一致（A %s [%s->%s] vs C %s [%s->%s]）' % (name, aid, ae['sa'], ae['ea'], cid, ce['sa'], ce['ea']))

print()
print('== 结果: %d 项问题 ==' % len(problems))
for p in problems:
    print(' -', p)
