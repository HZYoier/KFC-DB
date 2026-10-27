# -*- coding: utf-8 -*-
"""生成第二阶段合并总 ER 图：docs/er/stage2-model.drawio 与 .svg（同源同布局）。
依据：sql/01,02,03 建表 + 03/05 唯一约束/索引，docs/stage2/business-rule-mapping.md（BR 编号）。
口径：端点只表达 DDL 结构基数（OI-09 于 2026-10-24 由 B 冻结），业务条件见标签与 mapping。
版面：手工坐标 + 显式正交折线（每条边逐段避开实体盒）；标签自动避让。
"""
import re, os, html, math

ROOT = r'D:\DBLab\KFC-DB'
BOX_W = 300
HEAD_H = 26
ROW_H = 20
PAD_B = 6
CANVAS_W = 2920
CANVAS_H = 1940

# ---------------- 解析源码 ----------------
def read(p):
    return open(os.path.join(ROOT, p), encoding='utf-8').read()

def strip_comments(t):
    return re.sub(r'--[^\n]*', '', t)

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
            if mc and mc.group(1).lower() not in ('constraint', 'primary', 'foreign', 'references', 'unique'):
                col, rest = mc.group(1), mc.group(2)
                cols[col] = {'nullable': ('not null' not in rest.lower()),
                             'pk': bool(re.search(r'(?i)constraint\s+PK_\w+\s+primary\s+key', rest)),
                             'uk_inline': bool(re.search(r'(?i)constraint\s+UQ_\w+\s+unique', rest))}
                order.append(col)
                last = col
        pk = [c for c in order if cols[c]['pk']]
        for pm in re.finditer(r'(?i)constraint\s+PK_\w+\s+primary\s+key\s*\(([^)]*)\)', body):
            for c in pm.group(1).split(','):
                c = c.strip()
                if c in cols and c not in pk:
                    pk.append(c)
        for c in pk:
            cols[c]['nullable'] = False  # 主码列必非空（A 的复合主码列未写 NOT NULL）
        uq = {}
        for um in re.finditer(r'(?i)constraint\s+(UQ_\w+)\s+unique\s*\(([^)]*)\)', body):
            uq[um.group(1)] = [c.strip() for c in um.group(2).split(',')]
        for c in order:
            if cols[c]['uk_inline']:
                uq['UQ_inline_' + c] = [c]
        fk = []
        for fm in re.finditer(r'(?i)constraint\s+(FK_\w+)\s+foreign\s+key\s*\(([^)]*)\)\s*references\s+(?:\w+\.)?(\w+)\s*\(([^)]*)\)', body):
            fk.append({'name': fm.group(1), 'cols': [c.strip() for c in fm.group(2).split(',')],
                       'parent': fm.group(3), 'pcols': [c.strip() for c in fm.group(4).split(',')]})
        out[name] = {'cols': cols, 'order': order, 'pk': pk, 'uq': uq, 'fk': fk}
    return out

MODEL = {}
for f in ('sql/01_master_schema.sql', 'sql/02_order_schema.sql', 'sql/03_inventory_security_schema.sql'):
    MODEL.update(parse_file(f))

t03 = strip_comments(read('sql/03_inventory_security_schema.sql'))
for m in re.finditer(r'(?is)alter\s+table\s+(?:\w+\.)?(\w+)\s+add\s+constraint\s+(FK_\w+)\s+foreign\s+key\s*\(([^)]*)\)\s+references\s+(?:\w+\.)?(\w+)\s*\(([^)]*)\)', t03):
    tbl, name, cc, pt, pc = m.groups()
    MODEL[tbl]['fk'].append({'name': name, 'cols': [c.strip() for c in cc.split(',')],
                             'parent': pt, 'pcols': [c.strip() for c in pc.split(',')]})

t05 = strip_comments(read('sql/05_order_constraints_crud.sql'))
for m in re.finditer(r'(?is)alter\s+table\s+(?:\w+\.)?(\w+)\s+add\s+constraint\s+(UQ_\w+)\s+unique\s*\(([^)]*)\)', t05):
    tbl, name, cc = m.groups()
    MODEL[tbl]['uq'][name] = [c.strip() for c in cc.split(',')]

FILTERED = set()
for f in ('sql/01_master_schema.sql', 'sql/03_inventory_security_schema.sql', 'sql/05_order_constraints_crud.sql'):
    t = strip_comments(read(f))
    for m in re.finditer(r'(?is)create\s+unique\s+index\s+(UQ_\w+)\s+on\s+(?:\w+\.)?(\w+)\s*\(([^)]*)\)([^;]*)', t):
        name, tbl, cc, tail = m.groups()
        MODEL[tbl]['uq'][name] = [c.strip() for c in cc.split(',')]
        if re.search(r'(?i)\bwhere\b', tail):
            FILTERED.add(name)

ALL_FK = {}
for tbl, d in MODEL.items():
    for fk in d['fk']:
        ALL_FK[fk['name']] = dict(fk, child=tbl)

assert len(MODEL) == 25, len(MODEL)
assert len(ALL_FK) == 35, len(ALL_FK)

# ---------------- 实体版面 ----------------
# (table, x, y, domain)
ENTS = [
    ('Category', 60, 80, 'A'), ('ProductCategory', 460, 80, 'A'), ('Product', 860, 80, 'A'),
    ('Promotion', 1260, 80, 'A'), ('MemberLevel', 1660, 80, 'A'),
    ('Ingredient', 60, 340, 'A'), ('ProductBom', 460, 340, 'A'), ('ComboComponent', 860, 340, 'A'),
    ('PromotionProductRule', 1260, 340, 'A'), ('Customer', 1660, 320, 'A'),
    ('SalesOrder', 1660, 720, 'B'), ('SalesOrderItem', 2060, 720, 'B'), ('Payment', 2060, 1060, 'B'),
    ('Delivery', 2460, 720, 'B'), ('PointLedger', 2460, 1010, 'B'),
    ('Inventory', 60, 800, 'C'), ('InventoryMovement', 60, 1020, 'C'),
    ('ReplenishmentSuggestion', 460, 800, 'C'), ('PurchaseOrder', 460, 1120, 'C'),
    ('PurchaseOrderItem', 460, 1360, 'C'),
    ('BusinessRole', 900, 1000, 'C'), ('RolePermission', 900, 1180, 'C'),
    ('EmployeeBusinessRole', 1250, 1000, 'C'), ('EmployeeAccount', 1250, 1250, 'C'),
    ('AuditLog', 1600, 1250, 'C'),
]
DOMAIN_FILL = {'A': ('#dae8fc', '#6c8ebf'), 'B': ('#d5e8d4', '#82b366'), 'C': ('#fff2cc', '#d6b656')}

def ent_h(n):
    return HEAD_H + n * ROW_H + PAD_B

POS = {t: (x, y, dom) for t, x, y, dom in ENTS}
assert set(POS) == set(MODEL)

# 实体互不重叠
def rect(t):
    x, y = POS[t][0], POS[t][1]
    return (x, y, x + BOX_W, y + ent_h(len(MODEL[t]['order'])))

_rs = [(t,) + rect(t) for t in MODEL]
for i in range(len(_rs)):
    for j in range(i + 1, len(_rs)):
        a, b = _rs[i], _rs[j]
        if a[3] > b[1] and b[3] > a[1] and a[4] > b[2] and b[4] > a[2]:
            raise SystemExit('BOX OVERLAP: %s %s' % (a[0], b[0]))

# ---------------- 属性行 ----------------
def col_marker(tbl, c):
    d = MODEL[tbl]
    is_pk = c in d['pk']
    fks = [fk for fk in d['fk'] if c in fk['cols']]
    uk_sets = [v for k, v in d['uq'].items() if v == [c]]
    is_uk = bool(uk_sets)
    is_filtered = any(k for k, v in d['uq'].items() if v == [c] and k in FILTERED)
    if is_pk and fks:
        mark = 'PKFK'
    elif is_pk:
        mark = 'PK'
    elif fks and is_uk:
        mark = 'FK/UK*' if is_filtered else 'FK/UK'
    elif fks:
        mark = 'FK'
    elif is_uk:
        mark = 'UK*' if is_filtered else 'UK'
    else:
        mark = ''
    text = (mark + ' ' + c).strip()
    if d['cols'][c]['nullable'] and not is_pk:
        text += ' (NULL)'
    return text

def attr_lines(tbl):
    return [col_marker(tbl, c) for c in MODEL[tbl]['order']]

# ---------------- 联系路由 ----------------
# (BR, FK 名, [出口点, 折点..., 入口点], 附加标签)
ROUTES = [
    ('BR-01', 'FK_ProductCategory_Product', [(760, 126), (860, 126)], ''),
    ('BR-02', 'FK_ProductCategory_Category', [(460, 126), (360, 126)], ''),
    ('BR-03', 'FK_Customer_MemberLevel', [(1810, 320), (1810, 212)], ''),
    ('BR-04', 'FK_ProductBom_Product', [(700, 340), (700, 250), (900, 250), (900, 212)], ''),
    ('BR-05', 'FK_ProductBom_Ingredient', [(460, 386), (360, 386)], ''),
    ('BR-06', 'FK_ComboComponent_ComboProduct', [(930, 340), (930, 212)], ''),
    ('BR-07', 'FK_ComboComponent_ChildProduct', [(1090, 340), (1090, 212)], ''),
    ('BR-08', 'FK_PromotionProductRule_Promotion', [(1410, 340), (1410, 232)], ''),
    ('BR-09', 'FK_PromotionProductRule_Product', [(1300, 340), (1300, 280), (1100, 280), (1100, 212)], ''),
    ('BR-10', 'FK_SalesOrder_Customer', [(1810, 720), (1810, 472)], ''),
    ('BR-11', 'FK_SalesOrderItem_SalesOrder', [(2060, 820), (1960, 820)], '· 成功订单 ≥1 明细（过程）'),
    ('BR-12', 'FK_SalesOrderItem_Product', [(1160, 180), (1210, 180), (1210, 600), (2110, 600), (2110, 720)], ''),
    ('BR-13', 'FK_SalesOrderItem_Parent', [(2150, 952), (2150, 990), (2330, 990), (2330, 952)], '· 仅组件有父项（过程）'),
    ('BR-14', 'FK_SalesOrderItem_Promotion', [(1560, 150), (1610, 150), (1610, 640), (2250, 640), (2250, 720)], ''),
    ('BR-15', 'FK_Payment_SalesOrder', [(2060, 1150), (2010, 1150), (2010, 1000), (1960, 1000)], '· 支付成功恰 1 行'),
    ('BR-16', 'FK_Delivery_SalesOrder', [(1960, 760), (2010, 760), (2010, 680), (2425, 680), (2425, 800), (2460, 800)], '· 外送完成恰 1 行'),
    ('BR-17', 'FK_PointLedger_SalesOrder', [(1950, 1052), (1950, 1440), (2510, 1440), (2510, 1222)], '· 支付后恰 1 行'),
    ('BR-18', 'FK_PointLedger_Customer', [(1960, 400), (2390, 400), (2390, 1116), (2460, 1116)], ''),
    ('BR-19', 'FK_EmployeeBusinessRole_Employee', [(1330, 1112), (1330, 1250)], ''),
    ('BR-20', 'FK_EmployeeBusinessRole_BusinessRole', [(1250, 1056), (1200, 1056)], ''),
    ('BR-21', 'FK_EmployeeBusinessRole_AssignedByEmployee', [(1430, 1112), (1430, 1250)], ''),
    ('BR-22', 'FK_RolePermission_BusinessRole', [(1050, 1180), (1050, 1112)], ''),
    ('BR-23', 'FK_Inventory_Ingredient', [(150, 800), (150, 472)], ''),
    ('BR-24', 'FK_InventoryMovement_Inventory', [(210, 1020), (210, 912)], ''),
    ('BR-25', 'FK_ReplenishmentSuggestion_Ingredient', [(300, 472), (300, 760), (610, 760), (610, 800)], '· 开放建议至多 1 条'),
    ('BR-26', 'FK_ReplenishmentSuggestion_CreatedByEmployee', [(760, 850), (780, 850), (780, 1310), (1250, 1310)], ''),
    ('BR-27', 'FK_ReplenishmentSuggestion_SubmittedByEmployee', [(760, 900), (805, 900), (805, 1330), (1250, 1330)], ''),
    ('BR-28', 'FK_ReplenishmentSuggestion_ApprovedByEmployee', [(760, 950), (830, 950), (830, 1350), (1250, 1350)], ''),
    ('BR-29', 'FK_ReplenishmentSuggestion_RejectedByEmployee', [(760, 1000), (855, 1000), (855, 1370), (1250, 1370)], ''),
    ('BR-30', 'FK_PurchaseOrder_ReplenishmentSuggestion', [(610, 1120), (610, 1012)], '· 单次审批 1 单（过程）'),
    ('BR-31', 'FK_PurchaseOrder_ApprovedByEmployee', [(760, 1240), (870, 1240), (870, 1390), (1250, 1390)], ''),
    ('BR-32', 'FK_PurchaseOrderItem_PurchaseOrder', [(610, 1360), (610, 1272)], '· 业务恰 1 条（过程）'),
    ('BR-33', 'FK_PurchaseOrderItem_Ingredient', [(460, 1416), (420, 1416), (420, 406), (360, 406)], ''),
    ('BR-34', 'FK_AuditLog_Employee', [(1600, 1330), (1550, 1330)], ''),
    ('BR-35', 'FK_Delivery_RiderEmployee', [(2760, 896), (2810, 896), (2810, 1470), (1500, 1470), (1500, 1402)], ''),
]
DASHED = {'BR-07', 'BR-21'}

assert len(ROUTES) == 35
assert sorted(r[1] for r in ROUTES) == sorted(ALL_FK)

EDGES = []
for br, fkname, pts, suffix in ROUTES:
    fk = ALL_FK[fkname]
    parent, child = fk['parent'], fk['child']
    nullable = any(MODEL[child]['cols'][c]['nullable'] for c in fk['cols'])
    start_arrow = 'ERzeroToOne' if nullable else 'ERone'
    child_cols = set(fk['cols'])
    unique_child = (child_cols == set(MODEL[child]['pk'])) or any(
        set(v) == child_cols and k not in FILTERED for k, v in MODEL[child]['uq'].items())
    end_arrow = 'ERzeroToOne' if unique_child else 'ERzeroToMany'
    EDGES.append({'br': br, 'fk': fkname, 'parent': parent, 'child': child,
                  'pts': pts, 'label': br, 'start': start_arrow,
                  'end': end_arrow, 'dashed': br in DASHED,
                  'nullable': nullable, 'unique_child': unique_child})

# 锚点必须落在所属实体盒边界上；方向统一为「父端 -> 子端」
def on_border(pt, tbl):
    x, y = pt
    bx, by = POS[tbl][0], POS[tbl][1]
    w, h = BOX_W, ent_h(len(MODEL[tbl]['order']))
    on_v = (abs(x - bx) < 0.6 or abs(x - (bx + w)) < 0.6) and by - 0.6 <= y <= by + h + 0.6
    on_h = (abs(y - by) < 0.6 or abs(y - (by + h)) < 0.6) and bx - 0.6 <= x <= bx + w + 0.6
    return on_v or on_h

for e in EDGES:
    first_parent = on_border(e['pts'][0], e['parent'])
    last_child = on_border(e['pts'][-1], e['child'])
    if not (first_parent and last_child):
        first_child = on_border(e['pts'][0], e['child'])
        last_parent = on_border(e['pts'][-1], e['parent'])
        if first_child and last_parent:
            e['pts'] = list(reversed(e['pts']))
            first_parent = last_parent = True
            last_child = first_child = True
        else:
            raise SystemExit('BAD ROUTE %s %s -> %s %s' % (e['br'], e['parent'], e['child'], e['pts'][0]))
    if not on_border(e['pts'][0], e['parent']):
        raise SystemExit('BAD EXIT %s %s %s' % (e['br'], e['parent'], e['pts'][0]))
    if not on_border(e['pts'][-1], e['child']):
        raise SystemExit('BAD ENTRY %s %s %s' % (e['br'], e['child'], e['pts'][-1]))

# ---------------- 标签避让 ----------------
def seg_len(a, b):
    return abs(a[0] - b[0]) + abs(a[1] - b[1])

def label_w(s):
    return sum(11.5 if ord(ch) > 127 else 6.8 for ch in s) + 8

placed = []
TITLE_TOP = 1770

def hit_box(x0, y0, x1, y1, inflate=4):
    for t in MODEL:
        bx0, by0, bx1, by1 = rect(t)
        if x1 > bx0 - inflate and x0 < bx1 + inflate and y1 > by0 - inflate and y0 < by1 + inflate:
            return True
    return False

for e in EDGES:
    pts = e['pts']
    lw, lh = label_w(e['label']), 16
    total = sum(seg_len(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
    cands = []
    acc = 0.0
    for i in range(len(pts) - 1):
        a, b = pts[i], pts[i + 1]
        L = seg_len(a, b)
        frac = (acc + L / 2) / total if total else 0.5
        score = abs(frac - 0.5)
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        if a[1] == b[1]:  # 水平段：标签放上/下
            for dy in (-12, -26, 10, 24):
                cands.append((score + abs(dy) / 200, mx - lw / 2, my + dy - lh / 2))
        else:             # 垂直段：标签放左/右
            for dx in (12, 26, -12 - lw, -26 - lw):
                cands.append((score + abs(dx) / 200, mx + dx, my - lh / 2))
        acc += L
    cands.sort()
    chosen = None
    for _, cx, cy in cands:
        if cx < 4 or cy < 4 or cx + lw > CANVAS_W - 4 or cy + lh > TITLE_TOP - 4:
            continue
        if hit_box(cx, cy, cx + lw, cy + lh):
            continue
        if any(cx + lw > px - 3 and cx < px + pw + 3 and cy + lh > py - 2 and cy < py + ph + 2
               for px, py, pw, ph in placed):
            continue
        chosen = (cx, cy)
        break
    if chosen is None:
        raise SystemExit('NO LABEL SLOT: %s' % e['br'])
    placed.append((chosen[0], chosen[1], lw, lh))
    e['label_pos'] = (chosen[0] + lw / 2, chosen[1] + lh / 2)
    # drawio 偏移（相对折线长度中点）
    acc = 0.0
    for i in range(len(pts) - 1):
        L = seg_len(pts[i], pts[i + 1])
        if acc + L >= total / 2:
            t = (total / 2 - acc) / L if L else 0
            mdx = pts[i][0] + (pts[i + 1][0] - pts[i][0]) * t
            mdy = pts[i][1] + (pts[i + 1][1] - pts[i][1]) * t
            break
        acc += L
    e['label_off'] = (e['label_pos'][0] - mdx, e['label_pos'][1] - mdy)

# ---------------- 生成 drawio ----------------
def esc(s):
    return html.escape(s, quote=True)

def gen_drawio():
    cells = ['  <mxCell id="0" />', '  <mxCell id="1" parent="0" />']
    for tbl, x, y, dom in ENTS:
        cols = attr_lines(tbl)
        h = ent_h(len(cols))
        fill, stroke = DOMAIN_FILL[dom]
        value = '<b>{}</b>{}'.format(tbl, ''.join('<br>{}'.format(esc(c)) for c in cols))
        style = ('rounded=0;whiteSpace=wrap;html=1;align=left;verticalAlign=top;spacingLeft=8;'
                 'spacingTop=4;fontSize=12;fillColor={};strokeColor={};').format(fill, stroke)
        cells.append('  <mxCell id="E_{}" value="{}" style="{}" vertex="1" parent="1">'
                     .format(tbl, esc(value), style))
        cells.append('    <mxGeometry x="{}" y="{}" width="{}" height="{}" as="geometry" />'
                     .format(x, y, BOX_W, h))
        cells.append('  </mxCell>')
    for e in EDGES:
        pts = e['pts']
        sx, sy = POS[e['parent']][0], POS[e['parent']][1]
        tx, ty = POS[e['child']][0], POS[e['child']][1]
        sw, sh = BOX_W, ent_h(len(MODEL[e['parent']]['order']))
        tw, th = BOX_W, ent_h(len(MODEL[e['child']]['order']))
        ex, ey = (pts[0][0] - sx) / sw, (pts[0][1] - sy) / sh
        nx, ny = (pts[-1][0] - tx) / tw, (pts[-1][1] - ty) / th
        style = ('html=1;edgeStyle=none;endArrow={};startArrow={};endFill=0;startFill=0;fontSize=10.5;'
                 'labelBackgroundColor=#ffffff;exitX={:.4f};exitY={:.4f};entryX={:.4f};entryY={:.4f};'
                 .format(e['end'], e['start'], ex, ey, nx, ny))
        if e['dashed']:
            style += 'dashed=1;'
        inner = ''.join('<mxPoint x="{}" y="{}" />'.format(p[0], p[1]) for p in pts[1:-1])
        geom = ('    <mxGeometry x="{:.1f}" y="{:.1f}" relative="1" as="geometry">'
                '<Array as="points">{}</Array></mxGeometry>'
                .format(e['label_off'][0], e['label_off'][1], inner))
        cells.append('  <mxCell id="{}" value="{}" style="{}" edge="1" parent="1" source="E_{}" target="E_{}">'
                     .format(e['fk'], esc(e['label']), style, e['parent'], e['child']))
        cells.append(geom)
        cells.append('  </mxCell>')
    cells.append('  <mxCell id="title" value="{}" style="text;html=1;align=left;verticalAlign=top;fontSize=14;fontStyle=1;" vertex="1" parent="1">'.format(esc(TITLE)))
    cells.append('    <mxGeometry x="60" y="1780" width="2400" height="26" as="geometry" />')
    cells.append('  </mxCell>')
    cells.append('  <mxCell id="legend" value="{}" style="text;html=1;align=left;verticalAlign=top;fontSize=11;" vertex="1" parent="1">'.format(esc('<br>'.join(LEGEND))))
    cells.append('    <mxGeometry x="60" y="1812" width="2400" height="100" as="geometry" />')
    cells.append('  </mxCell>')
    body = '\n'.join(cells)
    return ('<mxGraphModel dx="1600" dy="1000" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" '
            'arrows="1" fold="1" page="1" pageScale="1" pageWidth="{}" pageHeight="{}" math="0" shadow="0">\n'
            '<root>\n{}\n</root>\n</mxGraphModel>\n').format(CANVAS_W, CANVAS_H, body)

# ---------------- 生成 svg ----------------
def svg_marker(parts, px, py, dx, dy, kind):
    L = max(1e-6, math.hypot(dx, dy))
    ux, uy = dx / L, dy / L
    qx, qy = px - ux * 16, py - uy * 16
    perp = (-uy, ux)
    def line(x1, y1, x2, y2, w=1.2):
        parts.append('<line x1="{:.1f}" y1="{:.1f}" x2="{:.1f}" y2="{:.1f}" stroke="#333" stroke-width="{}"/>'
                     .format(x1, y1, x2, y2, w))
    if kind in ('ERone', 'ERzeroToOne'):
        line(px + perp[0] * 8, py + perp[1] * 8, px - perp[0] * 8, py - perp[1] * 8)
    if kind in ('ERzeroToOne', 'ERzeroToMany'):
        cx, cy = px - ux * (22 if 'Many' in kind else 11), py - uy * (22 if 'Many' in kind else 11)
        parts.append('<circle cx="{:.1f}" cy="{:.1f}" r="4.5" fill="#fff" stroke="#333" stroke-width="1.2"/>'
                     .format(cx, cy))
    if kind == 'ERoneToMany':
        line(qx + perp[0] * 8, qy + perp[1] * 8, qx - perp[0] * 8, qy - perp[1] * 8)
    if kind in ('ERoneToMany', 'ERzeroToMany'):
        for s in (-1, 0, 1):
            line(qx, qy, px + perp[0] * 8 * s, py + perp[1] * 8 * s)

def gen_svg():
    parts = ['<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}" viewBox="0 0 {} {}" '
             'font-family="Segoe UI, Microsoft YaHei, sans-serif">'.format(CANVAS_W, CANVAS_H, CANVAS_W, CANVAS_H),
             '<rect x="0" y="0" width="{}" height="{}" fill="#ffffff"/>'.format(CANVAS_W, CANVAS_H)]
    for e in EDGES:
        pts = e['pts']
        dash = ' stroke-dasharray="6,4"' if e['dashed'] else ''
        for i in range(len(pts) - 1):
            parts.append('<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="#333" stroke-width="1.2"{} />'
                         .format(pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1], dash))
        svg_marker(parts, pts[0][0], pts[0][1], pts[0][0] - pts[1][0], pts[0][1] - pts[1][1], e['start'])
        svg_marker(parts, pts[-1][0], pts[-1][1], pts[-1][0] - pts[-2][0], pts[-1][1] - pts[-2][1], e['end'])
    for tbl, x, y, dom in ENTS:
        cols = attr_lines(tbl)
        h = ent_h(len(cols))
        fill, stroke = DOMAIN_FILL[dom]
        parts.append('<rect x="{}" y="{}" width="{}" height="{}" fill="{}" stroke="{}" stroke-width="1.5"/>'
                     .format(x, y, BOX_W, h, fill, stroke))
        parts.append('<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="{}" stroke-width="1"/>'
                     .format(x, y + HEAD_H, x + BOX_W, y + HEAD_H, stroke))
        parts.append('<text x="{}" y="{}" font-size="13" font-weight="bold" fill="#1a1a1a">{}</text>'
                     .format(x + 8, y + 17, esc(tbl)))
        for i, c in enumerate(cols):
            parts.append('<text x="{}" y="{}" font-size="11.5" fill="#333">{}</text>'
                         .format(x + 10, y + HEAD_H + 15 + i * ROW_H, esc(c)))
    for e in EDGES:
        mx, my = e['label_pos']
        lw = label_w(e['label'])
        parts.append('<rect x="{:.1f}" y="{:.1f}" width="{:.1f}" height="16" fill="#ffffff" opacity="0.92"/>'
                     .format(mx - lw / 2, my - 8, lw))
        parts.append('<text x="{:.1f}" y="{:.1f}" font-size="10.5" fill="#444" text-anchor="middle">{}</text>'
                     .format(mx, my + 4, esc(e['label'])))
    parts.append('<text x="60" y="1793" font-size="14" font-weight="bold" fill="#1a1a1a">{}</text>'.format(esc(TITLE)))
    for i, l in enumerate(LEGEND):
        parts.append('<text x="60" y="{}" font-size="11" fill="#444">{}</text>'.format(1822 + i * 18, esc(l)))
    parts.append('</svg>')
    return '\n'.join(parts) + '\n'

TITLE = ('KFC_DB 第二阶段数据模型总图（逻辑 ER，v0.1）— 25 个实体 / 35 条物理外键；'
         '源：sql/01–03 建表 + 03/05 唯一约束（2026-10-27 生成）')
LEGEND = [
    '端点符号：| 恰好 1    o| 零或 1    |< 一或多    o< 零或多 —— 某端符号 = 对端每条记录对应本端多少条（legend.md §2）',
    '联系标签 = business-rule-mapping.md 的 BR 编号；端点只表达 DDL 结构基数（OI-09 于 2026-10-24 冻结）',
    '结构不保证的业务附加（均为过程保证，详见 business-rule-mapping.md）：BR-11 成功订单 ≥1 明细；BR-13 仅组件有父项；'
    'BR-15/16/17 支付成功/外送完成/支付后恰 1 行；BR-25 开放建议至多 1 条；BR-30 单次审批 1 单；BR-32 业务恰 1 条',
    '颜色按域：蓝 = A 主数据（10 表）、绿 = B 订单履约（5 表）、黄 = C 库存与权限（10 表）；虚线 = 同一对实体间的第二条外键',
    '实体名 = 表名、属性名 = 列名；PK/UK/FK/PKFK 标记同 legend.md §1；UK* = 过滤唯一索引（仅在过滤条件内唯一，不压父端最大基数）',
]

drawio = gen_drawio()
svg = gen_svg()
for path, content in [(ROOT + r'\docs\er\stage2-model.drawio', drawio),
                      (ROOT + r'\docs\er\stage2-model.svg', svg)]:
    data = content.replace('\n', '\r\n').encode('utf-8')
    with open(path, 'wb') as f:
        f.write(data)
    print('written:', path, '| bytes:', len(data))
print('entities:', len(ENTS), '| edges:', len(EDGES))
for e in EDGES:
    print('  %-6s %-46s %-22s -> %-22s %s -> %s%s' % (
        e['br'], e['fk'], e['parent'], e['child'], e['start'], e['end'], ' (dashed)' if e['dashed'] else ''))
