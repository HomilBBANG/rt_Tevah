#!/usr/bin/env python3
"""tools/sheets/content.xlsx → res://data/*.json 변환 + 데이터 검사.

사용법:  python tools/xlsx_to_json.py [xlsx 경로]
오류가 하나라도 있으면 JSON을 쓰지 않고 종료 코드 1로 끝난다.
이름이 '_'로 시작하는 시트와, 스키마에 없는 열(메모 등)은 무시한다.
"""
import json
import re
import sys
from collections import deque
from pathlib import Path

from openpyxl import load_workbook

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_XLSX = ROOT / "tools" / "sheets" / "content.xlsx"
OUT_DIR = ROOT / "data"

STATS = {"hp", "sanity", "time"}
SHOW_MODES = {"", "hide", "gray"}
REQUIRED_CONFIG = ["inventory_slots", "hp_start", "hp_max", "sanity_start", "sanity_max", "time_start", "time_max"]

# 시트 → (ID 열, 열 목록, 숫자 열 {이름: (타입, 기본값)})
SCHEMA = {
    "Episodes": ("episode_id", ["episode_id", "title", "protagonist_id", "start_node", "unlock_condition",
                                "timeout_node", "death_ending", "madness_ending"], {}),
    "Nodes": ("node_id", ["node_id", "episode_id", "speaker_id", "text", "next_node", "on_enter"], {}),
    "Choices": ("choice_id", ["choice_id", "node_id", "text", "condition", "show_mode", "cost", "effects",
                              "next_node"], {}),
    "Items": ("item_id", ["item_id", "name", "type", "description", "use_effects", "stack_max"],
              {"stack_max": (int, 1)}),
    "Loot": ("loot_id", ["loot_id", "spot_id", "item_id", "amount", "chance", "time_cost"],
             {"amount": (int, 1), "chance": (float, 100.0), "time_cost": (int, 0)}),
    "Characters": ("char_id", ["char_id", "name", "traits"], {}),
    "Endings": ("ending_id", ["ending_id", "episode_id", "world_flags_set"], {}),
    "Config": ("key", ["key", "value"], {"value": (float, None)}),
}

ID_RE = re.compile(r"^[A-Za-z0-9_]+$")


class Report:
    def __init__(self):
        self.errors = []

    def err(self, where, msg):
        self.errors.append(f"[{where}] {msg}")


# ---------------------------------------------------------------- 조건·효과 문법
# 런타임 파서(core/expr.gd)와 같은 문법. 한쪽을 바꾸면 다른 쪽도 맞춰야 한다.
ATOM_RE = re.compile(r"(has|flag|wflag|stat|trait):([A-Za-z0-9_]+)(?:(>=|<=|==|>|<)(-?\d+(?:\.\d+)?))?")


class ExprError(Exception):
    pass


def parse_condition(text):
    """조건식을 검사하고 참조 목록 [(kind, id), ...]을 돌려준다. 문법 오류면 ExprError."""
    tokens = []
    i = 0
    while i < len(text):
        c = text[i]
        if c.isspace():
            i += 1
        elif c in "&|!()":
            tokens.append(c)
            i += 1
        else:
            m = ATOM_RE.match(text, i)
            if not m:
                raise ExprError(f"해석할 수 없는 부분: '{text[i:]}'")
            kind, ident, op, _num = m.groups()
            if kind == "stat":
                if ident not in STATS:
                    raise ExprError(f"알 수 없는 스탯 '{ident}' (가능: {', '.join(sorted(STATS))})")
                if not op:
                    raise ExprError(f"'{m.group(0)}': stat 조건에는 비교식이 필요 (예: stat:hp>=10)")
            elif kind in ("flag", "wflag", "trait") and op:
                raise ExprError(f"'{m.group(0)}': {kind} 조건에는 비교식을 쓸 수 없음")
            tokens.append((kind, ident))
            i = m.end()
    if not tokens:
        return []

    refs = []
    pos = 0

    def peek():
        return tokens[pos] if pos < len(tokens) else None

    def parse_or():
        parse_and()
        while peek() == "|":
            advance()
            parse_and()

    def parse_and():
        parse_unary()
        while peek() == "&":
            advance()
            parse_unary()

    def parse_unary():
        t = peek()
        if t == "!":
            advance()
            parse_unary()
        elif t == "(":
            advance()
            parse_or()
            if peek() != ")":
                raise ExprError("닫는 괄호 ')' 가 없음")
            advance()
        elif isinstance(t, tuple):
            refs.append(t)
            advance()
        else:
            raise ExprError(f"조건이 와야 할 자리에 '{t or '끝'}'")

    def advance():
        nonlocal pos
        pos += 1

    parse_or()
    if pos != len(tokens):
        raise ExprError(f"남는 토큰 '{tokens[pos]}'")
    return refs


EFFECT_RES = [
    ("item", re.compile(r"^item:([+-])([A-Za-z0-9_]+)(?:\*(\d+))?$")),
    ("stat", re.compile(r"^stat:([A-Za-z0-9_]+)([+\-=])(\d+)$")),
    ("simple", re.compile(r"^(setflag|clearflag|setwflag|loot|goto):([A-Za-z0-9_]+)$")),
]


def parse_effects(text):
    """효과 목록을 검사하고 [(kind, id), ...] 참조 목록을 돌려준다. 문법 오류면 ExprError."""
    refs = []
    for raw in text.split(";"):
        e = raw.strip()
        if not e:
            continue
        for kind, rx in EFFECT_RES:
            m = rx.match(e)
            if not m:
                continue
            if kind == "item":
                if m.group(3) is not None and int(m.group(3)) < 1:
                    raise ExprError(f"'{e}': 수량은 1 이상")
                refs.append(("item", m.group(2)))
            elif kind == "stat":
                if m.group(1) not in STATS:
                    raise ExprError(f"'{e}': 알 수 없는 스탯 '{m.group(1)}'")
            else:
                refs.append((m.group(1), m.group(2)))
            break
        else:
            raise ExprError(f"효과 문법 오류: '{e}'")
    return refs


def split_list(text):
    return [s.strip() for s in re.split(r"[,;]", text) if s.strip()]


# ---------------------------------------------------------------- 읽기
def cell_str(v):
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def read_sheets(path, rep):
    wb = load_workbook(path, data_only=True, read_only=True)
    data = {}
    for sheet, (id_col, cols, numeric) in SCHEMA.items():
        if sheet not in wb.sheetnames:
            rep.err(sheet, "시트가 없음")
            data[sheet] = []
            continue
        rows = list(wb[sheet].iter_rows(values_only=True))
        if not rows:
            rep.err(sheet, "헤더 행이 없음")
            data[sheet] = []
            continue
        header = [cell_str(h) for h in rows[0]]
        missing = [c for c in cols if c not in header]
        if missing:
            rep.err(sheet, f"열 없음: {', '.join(missing)}")
            data[sheet] = []
            continue
        idx = {c: header.index(c) for c in cols}
        out = []
        for rn, row in enumerate(rows[1:], start=2):
            vals = {c: (row[idx[c]] if idx[c] < len(row) else None) for c in cols}
            if all(cell_str(v) == "" for v in vals.values()):
                continue
            rec = {"_row": rn}
            for c in cols:
                if c in numeric:
                    typ, default = numeric[c]
                    s = cell_str(vals[c])
                    if s == "":
                        if default is None:
                            rep.err(f"{sheet} {rn}행", f"{c} 값이 비어 있음")
                        rec[c] = default
                    else:
                        try:
                            rec[c] = typ(float(s)) if typ is int else float(s)
                            if typ is int and float(s) != int(float(s)):
                                raise ValueError
                        except ValueError:
                            rep.err(f"{sheet} {rn}행", f"{c} 는 숫자여야 함: '{s}'")
                            rec[c] = default
                else:
                    rec[c] = cell_str(vals[c])
            rid = rec[id_col]
            if rid == "":
                rep.err(f"{sheet} {rn}행", f"{id_col} 가 비어 있음")
                continue
            if sheet != "Config" and not ID_RE.match(rid):
                rep.err(f"{sheet} {rn}행", f"ID '{rid}' 에는 영문·숫자·_ 만 쓸 수 있음")
            out.append(rec)
        data[sheet] = out
    return data


# ---------------------------------------------------------------- 검사
def validate(d, rep):
    def index(sheet):
        id_col = SCHEMA[sheet][0]
        seen = {}
        for r in d[sheet]:
            rid = r[id_col]
            if rid in seen:
                rep.err(f"{sheet} {r['_row']}행", f"ID 중복 '{rid}' ({seen[rid]['_row']}행과 겹침)")
            else:
                seen[rid] = r
        return seen

    eps, nodes, choices = index("Episodes"), index("Nodes"), index("Choices")
    items, loots, chars, endings = index("Items"), index("Loot"), index("Characters"), index("Endings")
    config = index("Config")
    spots = {r["spot_id"] for r in d["Loot"] if r["spot_id"]}
    choices_by_node = {}
    for c in d["Choices"]:
        choices_by_node.setdefault(c["node_id"], []).append(c)

    def check_refs(where, refs, episode):
        for kind, rid in refs:
            if kind == "item" and rid not in items:
                rep.err(where, f"없는 item_id '{rid}'")
            elif kind == "has" and rid not in items:
                rep.err(where, f"없는 item_id '{rid}'")
            elif kind == "loot" and rid not in spots:
                rep.err(where, f"없는 spot_id '{rid}' (Loot 시트)")
            elif kind == "goto":
                check_target(where, rid, episode, allow_end=False)

    def check_target(where, target, episode, allow_end=True):
        if target.startswith("END:"):
            eid = target[4:]
            if not allow_end:
                rep.err(where, f"goto 에는 END: 를 쓸 수 없음 ('{target}'), next_node 를 쓸 것")
            elif eid not in endings:
                rep.err(where, f"없는 ending_id '{eid}'")
            elif episode and endings[eid]["episode_id"] != episode:
                rep.err(where, f"엔딩 '{eid}' 는 다른 에피소드({endings[eid]['episode_id']}) 소속")
        elif target not in nodes:
            rep.err(where, f"없는 node_id '{target}'")
        elif episode and nodes[target]["episode_id"] != episode:
            rep.err(where, f"노드 '{target}' 는 다른 에피소드({nodes[target]['episode_id']}) 소속")

    def check_cond(where, text):
        if not text:
            return
        try:
            for kind, rid in parse_condition(text):
                if kind == "has" and rid not in items:
                    rep.err(where, f"조건의 없는 item_id '{rid}'")
        except ExprError as e:
            rep.err(where, f"조건 문법 오류: {e}")

    def check_effects(where, text, episode):
        if not text:
            return []
        try:
            refs = parse_effects(text)
        except ExprError as e:
            rep.err(where, str(e))
            return []
        check_refs(where, refs, episode)
        return [rid for kind, rid in refs if kind == "goto"]

    # Config
    for key in REQUIRED_CONFIG:
        if key not in config:
            rep.err("Config", f"키 없음: {key}")

    # Characters
    for c in d["Characters"]:
        for t in split_list(c["traits"]):
            if not ID_RE.match(t):
                rep.err(f"Characters {c['_row']}행", f"능력 이름 '{t}' 에는 영문·숫자·_ 만")

    # Items
    for it in d["Items"]:
        w = f"Items {it['_row']}행 ({it['item_id']})"
        if it["stack_max"] is not None and it["stack_max"] < 1:
            rep.err(w, "stack_max 는 1 이상")
        check_effects(w, it["use_effects"], None)

    # Loot
    for lo in d["Loot"]:
        w = f"Loot {lo['_row']}행 ({lo['loot_id']})"
        if not lo["spot_id"]:
            rep.err(w, "spot_id 가 비어 있음")
        if lo["item_id"] not in items:
            rep.err(w, f"없는 item_id '{lo['item_id']}'")
        if lo["amount"] is not None and lo["amount"] < 1:
            rep.err(w, "amount 는 1 이상")
        if lo["chance"] is not None and not (0 <= lo["chance"] <= 100):
            rep.err(w, "chance 는 0~100 (%)")

    # Endings
    for en in d["Endings"]:
        w = f"Endings {en['_row']}행 ({en['ending_id']})"
        if en["episode_id"] not in eps:
            rep.err(w, f"없는 episode_id '{en['episode_id']}'")
        for f in split_list(en["world_flags_set"]):
            if not ID_RE.match(f):
                rep.err(w, f"플래그 이름 '{f}' 에는 영문·숫자·_ 만")

    # Episodes
    for ep in d["Episodes"]:
        eid = ep["episode_id"]
        w = f"Episodes {ep['_row']}행 ({eid})"
        if ep["protagonist_id"] not in chars:
            rep.err(w, f"없는 char_id '{ep['protagonist_id']}'")
        for col in ("start_node", "timeout_node"):
            if not ep[col]:
                rep.err(w, f"{col} 가 비어 있음")
            else:
                check_target(f"{w} {col}", ep[col], eid, allow_end=False)
        for col in ("death_ending", "madness_ending"):
            if not ep[col]:
                rep.err(w, f"{col} 가 비어 있음")
            else:
                check_target(f"{w} {col}", "END:" + ep[col], eid)
        check_cond(w, ep["unlock_condition"])

    # Nodes / Choices
    edges = {}  # node_id -> set(node_id)
    for n in d["Nodes"]:
        nid = n["node_id"]
        w = f"Nodes {n['_row']}행 ({nid})"
        ep = n["episode_id"]
        if ep not in eps:
            rep.err(w, f"없는 episode_id '{ep}'")
        if n["speaker_id"] and n["speaker_id"] not in chars:
            rep.err(w, f"없는 speaker_id '{n['speaker_id']}'")
        out = set(check_effects(w + " on_enter", n["on_enter"], ep))
        if n["next_node"]:
            check_target(w + " next_node", n["next_node"], ep)
            if not n["next_node"].startswith("END:"):
                out.add(n["next_node"])
        elif nid not in choices_by_node and not out:
            rep.err(w, "출구 없음 (선택지·next_node·END 모두 없음)")
        edges[nid] = out

    for c in d["Choices"]:
        w = f"Choices {c['_row']}행 ({c['choice_id']})"
        node = nodes.get(c["node_id"])
        if node is None:
            rep.err(w, f"없는 node_id '{c['node_id']}'")
            continue
        ep = node["episode_id"]
        if c["show_mode"] not in SHOW_MODES:
            rep.err(w, f"show_mode 는 hide 또는 gray: '{c['show_mode']}'")
        check_cond(w, c["condition"])
        gotos = check_effects(w, c["effects"], ep)
        if c["next_node"]:
            check_target(w + " next_node", c["next_node"], ep)
            if not c["next_node"].startswith("END:"):
                edges[c["node_id"]].add(c["next_node"])
        elif not gotos:
            rep.err(w, "출구 없음 (next_node 도 goto 효과도 없음)")
        edges[c["node_id"]].update(gotos)

    # 아이템 use_effects 의 goto 는 어느 노드에서든 쓸 수 있으므로 도달 가능 경로로 본다.
    item_gotos = set()
    for it in d["Items"]:
        try:
            item_gotos.update(rid for k, rid in parse_effects(it["use_effects"]) if k == "goto")
        except ExprError:
            pass

    # 도달성: 에피소드 시작 노드 + 시간 초과 노드에서 BFS
    reached = set()
    for ep in d["Episodes"]:
        q = deque(x for x in (ep["start_node"], ep["timeout_node"]) if x in nodes)
        q.extend(g for g in item_gotos if g in nodes and nodes[g]["episode_id"] == ep["episode_id"])
        while q:
            nid = q.popleft()
            if nid in reached:
                continue
            reached.add(nid)
            q.extend(x for x in edges.get(nid, ()) if x in nodes)
    for n in d["Nodes"]:
        if n["node_id"] not in reached and n["episode_id"] in eps:
            rep.err(f"Nodes {n['_row']}행 ({n['node_id']})", "시작 노드에서 도달할 수 없음")


# ---------------------------------------------------------------- 출력
def export(d):
    def clean(rows):
        return [{k: v for k, v in r.items() if k != "_row"} for r in rows]

    out = {
        "episodes": clean(d["Episodes"]),
        "nodes": clean(d["Nodes"]),
        "choices": clean(d["Choices"]),
        "items": clean(d["Items"]),
        "loot": clean(d["Loot"]),
        "characters": [dict(r, traits=split_list(r["traits"])) for r in clean(d["Characters"])],
        "endings": [dict(r, world_flags_set=split_list(r["world_flags_set"])) for r in clean(d["Endings"])],
        "config": {r["key"]: (int(r["value"]) if float(r["value"]).is_integer() else r["value"])
                   for r in d["Config"]},
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, obj in out.items():
        (OUT_DIR / f"{name}.json").write_text(json.dumps(obj, ensure_ascii=False, indent=1) + "\n",
                                              encoding="utf-8")
    return out


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_XLSX
    if not path.exists():
        print(f"파일 없음: {path}")
        return 1
    rep = Report()
    try:
        data = read_sheets(path, rep)
    except PermissionError:
        print(f"파일을 열 수 없음(다른 프로그램이 잠금?): {path}")
        return 1
    validate(data, rep)
    if rep.errors:
        print(f"오류 {len(rep.errors)}개 — JSON을 쓰지 않았습니다.")
        for e in rep.errors:
            print("  " + e)
        return 1
    out = export(data)
    print("변환 완료 → " + str(OUT_DIR))
    for k, v in out.items():
        print(f"  {k}.json: {len(v)}개")
    return 0


if __name__ == "__main__":
    sys.exit(main())
