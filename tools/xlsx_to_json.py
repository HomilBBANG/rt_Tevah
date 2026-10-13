#!/usr/bin/env python3
"""tools/sheets/content.xlsx (+ tools/maps/*.txt, tools/dialogues/*.json) → res://data/*.json 변환 + 데이터 검사. Python 3.9+.

대화(노드·선택지)는 Godot 의 '대화' 탭(addons/dialogue_editor)이 만드는 tools/dialogues/*.json 이 원본이고,
엑셀 Nodes·Choices 시트와 합쳐서 검사·출력한다.

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
MAPS_DIR = ROOT / "tools" / "maps"
DIALOGUES_DIR = ROOT / "tools" / "dialogues"
OUT_DIR = ROOT / "data"

STATS = {"hp", "sanity", "time"}
SHOW_MODES = {"", "hide", "gray"}
CHOICE_TYPES = {"", "normal", "item", "dice"}
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
    "Config": ("key", ["key", "value"], {}),   # 값은 숫자 또는 문자열(예: protagonist_id)
    "Abilities": ("ability_id", ["ability_id", "name"], {}),
    # ---- 전투 (기획서 §7–9)
    "PlayerParts": ("part_id", ["part_id", "name", "key", "hp", "vital"], {"hp": (int, None)}),
    "Enemies": ("enemy_id", ["enemy_id", "name"], {}),
    "EnemyParts": ("part_id", ["enemy_id", "part_id", "name", "hp", "hit_chance", "vital"],
                   {"hp": (int, None), "hit_chance": (float, None)}),
    "EnemyAttacks": ("attack_id", ["attack_id", "enemy_id", "name", "part", "pattern", "targets", "windup",
                                   "damage", "weight"],
                     {"windup": (float, None), "damage": (int, None), "weight": (int, 1)}),
    # ---- 탐험 필드. 맵 모양은 tools/maps/<map_id>.txt, 맵 위 물체는 이 시트
    # ---- 생존·베이스캠프 (기획서 §4, §5, §12)
    "Survival": ("param_id", ["param_id", "name", "start", "max", "decay_per_hour", "warn"],
                 {"start": (float, None), "max": (float, None), "decay_per_hour": (float, 0.0), "warn": (float, 0.0)}),
    "CampActions": ("action_id", ["action_id", "name", "minutes", "condition", "effects", "kind"],
                    {"minutes": (int, 0)}),
    # ---- 부활 (기획서 §11): 사망 순간 위에서부터 condition 이 참인 첫 행으로 부활 → 모두 유지한 채 베이스캠프에서 깨어남
    "Revivals": ("revive_id", ["revive_id", "name", "condition", "effects", "text"], {}),
}

# 없어도 되는 시트 (없으면 빈 시트로 본다)
OPTIONAL_SHEETS = {"Abilities", "PlayerParts", "Enemies", "EnemyParts", "EnemyAttacks",
                   "Survival", "CampActions", "Revivals"}
FIELD_TYPES = {"enemy", "investigate", "npc", "camp", "exit"}
CAMP_KINDS = {"", "sleep"}   # sleep: 1시간 단위로 골라 자고, 자고 나면 저장 (effects 는 1시간마다)
PATROL_DIRS = {"": (0, 0), "up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}
MAP_TILES = {"#", "."}   # 벽 / 바닥
# ID 중복 검사를 여러 열 조합으로 하는 시트
DUP_KEYS = {"EnemyParts": ("enemy_id", "part_id")}
DODGE_KEYS = {"W", "A", "S", "D"}
ATTACK_PATTERNS = {"normal", "quick", "combo", "feint"}
TRUE_WORDS = {"y", "yes", "true", "1", "o", "v"}

# 없어도 되는 열 (시트에 없으면 빈 값으로 본다)
OPTIONAL = {
    "Characters": ["name_color",    # 대화 이름표 색 (#RRGGBB). 비우면 기본색
                   "abilities"],    # 능력치 기본값 "stat_a=3, stat_b=1" (없는 능력치는 0)
    "Items": ["dice_bonus"],        # 소지 시 판정 보정 "stat_a+2, all+1"
    # 선택지 종류: normal(기본) / item / dice
    # dice: check=능력치, dc=목표값, mod=상황 보정, 실패 시 fail_effects·fail_next
    "Choices": ["type", "check", "dc", "mod", "fail_effects", "fail_next"],
}

ID_RE = re.compile(r"^[A-Za-z0-9_]+$")
EXIT = "EXIT"   # 필드 대화 끝 → 필드로 복귀
COLOR_RE = re.compile(r"^#?[0-9A-Fa-f]{6}$")
INT_RE = re.compile(r"^-?\d+$")
ABIL_VALUE_RE = re.compile(r"^([A-Za-z0-9_]+)\s*=\s*(-?\d+)$")
BONUS_RE = re.compile(r"^([A-Za-z0-9_]+)\s*([+-]\d+)$")


class Report:
    def __init__(self):
        self.errors = []

    def err(self, where, msg):
        self.errors.append(f"[{where}] {msg}")


# ---------------------------------------------------------------- 조건·효과 문법
# 런타임 파서(core/expr.gd)와 같은 문법. 한쪽을 바꾸면 다른 쪽도 맞춰야 한다.
ATOM_RE = re.compile(r"(has|flag|wflag|stat|trait|abil|surv):([A-Za-z0-9_]+)(?:(>=|<=|==|>|<)(-?\d+(?:\.\d+)?))?")


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
            elif kind == "surv" and not op:
                raise ExprError(f"'{m.group(0)}': surv 조건에는 비교식이 필요 (예: surv:hunger<30)")
            elif kind == "abil" and not op:
                raise ExprError(f"'{m.group(0)}': abil 조건에는 비교식이 필요 (예: abil:stat_a>=3)")
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
    ("abil", re.compile(r"^abil:([A-Za-z0-9_]+)([+\-=])(\d+)$")),
    ("surv", re.compile(r"^surv:([A-Za-z0-9_]+)([+\-=])(\d+)$")),
    ("simple", re.compile(r"^(setflag|clearflag|setwflag|loot|goto):([A-Za-z0-9_]+)$")),
    ("save", re.compile(r"^save$")),   # 회차 저장 (베이스캠프 안에서만 동작)
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
            elif kind in ("abil", "surv"):
                refs.append((kind, m.group(1)))
            elif kind == "save":
                pass
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
            if sheet not in OPTIONAL_SHEETS:
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
        opt = OPTIONAL.get(sheet, [])
        idx = {c: header.index(c) for c in cols + opt if c in header}
        out = []
        for rn, row in enumerate(rows[1:], start=2):
            vals = {c: (row[idx[c]] if c in idx and idx[c] < len(row) else None) for c in cols + opt}
            if all(cell_str(v) == "" for v in vals.values()):
                continue
            rec = {"_row": rn}
            for c in cols + opt:
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
            rid = tuple(r[c] for c in DUP_KEYS[sheet]) if sheet in DUP_KEYS else r[id_col]
            if rid in seen:
                rep.err(loc(sheet, r), f"ID 중복 '{rid}' ({loc(sheet, seen[rid])} 과 겹침)")
            else:
                seen[rid] = r
        return seen

    eps, nodes, choices = index("Episodes"), index("Nodes"), index("Choices")
    items, loots, chars, endings = index("Items"), index("Loot"), index("Characters"), index("Endings")
    config, abils = index("Config"), index("Abilities")
    survs = index("Survival")
    pparts, enemies, eparts, eattacks = index("PlayerParts"), index("Enemies"), index("EnemyParts"), \
        index("EnemyAttacks")
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
            elif kind == "abil" and rid not in abils:
                rep.err(where, f"없는 ability_id '{rid}' (Abilities 시트)")
            elif kind == "surv" and rid not in survs:
                rep.err(where, f"없는 생존 파라미터 '{rid}' (Survival 시트)")
            elif kind == "loot" and rid not in spots:
                rep.err(where, f"없는 spot_id '{rid}' (Loot 시트)")
            elif kind == "goto":
                check_target(where, rid, episode, allow_end=False)

    def check_target(where, target, episode, allow_end=True):
        if target == EXIT:
            if episode != "" or not allow_end:
                rep.err(where, "EXIT 는 필드 대화(episode_id 가 빈 노드)의 next_node·fail_next 에서만")
            return
        if target.startswith("END:"):
            eid = target[4:]
            if episode == "":
                rep.err(where, f"필드 대화에서는 END: 대신 EXIT 로 대화를 끝낸다 ('{target}')")
            elif not allow_end:
                rep.err(where, f"goto 에는 END: 를 쓸 수 없음 ('{target}'), next_node 를 쓸 것")
            elif eid not in endings:
                rep.err(where, f"없는 ending_id '{eid}'")
            elif episode is not None and endings[eid]["episode_id"] != episode:
                rep.err(where, f"엔딩 '{eid}' 는 다른 에피소드({endings[eid]['episode_id']}) 소속")
        elif target not in nodes:
            rep.err(where, f"없는 node_id '{target}'")
        elif episode is not None and nodes[target]["episode_id"] != episode:
            rep.err(where, f"노드 '{target}' 는 {_scope(nodes[target]['episode_id'])} 소속 (여기는 {_scope(episode)})")

    def check_cond(where, text):
        if not text:
            return
        try:
            for kind, rid in parse_condition(text):
                if kind == "has" and rid not in items:
                    rep.err(where, f"조건의 없는 item_id '{rid}'")
                elif kind == "abil" and rid not in abils:
                    rep.err(where, f"조건의 없는 ability_id '{rid}'")
                elif kind == "surv" and rid not in survs:
                    rep.err(where, f"조건의 없는 생존 파라미터 '{rid}'")
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
        elif not is_number(config[key]["value"]):
            rep.err("Config", f"{key} 는 숫자여야 함: '{config[key]['value']}'")
    for key, r in config.items():
        if r["value"] == "":
            rep.err(f"Config {r['_row']}행", f"{key} 값이 비어 있음")
    if "protagonist_id" in config and config["protagonist_id"]["value"] not in chars:
        rep.err("Config", f"protagonist_id 는 Characters 의 char_id: '{config['protagonist_id']['value']}'")

    # Characters
    for c in d["Characters"]:
        if c["name_color"] and not COLOR_RE.match(c["name_color"]):
            rep.err(f"Characters {c['_row']}행", f"name_color 는 #RRGGBB 형식: '{c['name_color']}'")
        for t in split_list(c["traits"]):
            if not ID_RE.match(t):
                rep.err(f"Characters {c['_row']}행", f"능력 이름 '{t}' 에는 영문·숫자·_ 만")
        for a in split_list(c["abilities"]):
            m = ABIL_VALUE_RE.match(a)
            if not m:
                rep.err(f"Characters {c['_row']}행", f"abilities 는 '능력치=숫자' 형식: '{a}'")
            elif m.group(1) not in abils:
                rep.err(f"Characters {c['_row']}행", f"없는 ability_id '{m.group(1)}'")

    # Items
    for it in d["Items"]:
        w = f"Items {it['_row']}행 ({it['item_id']})"
        if it["stack_max"] is not None and it["stack_max"] < 1:
            rep.err(w, "stack_max 는 1 이상")
        check_effects(w, it["use_effects"], None)
        for b in split_list(it["dice_bonus"]):
            m = BONUS_RE.match(b)
            if not m:
                rep.err(w, f"dice_bonus 는 '능력치+숫자' 또는 'all+숫자' 형식: '{b}'")
            elif m.group(1) != "all" and m.group(1) not in abils:
                rep.err(w, f"dice_bonus 의 없는 ability_id '{m.group(1)}'")

    # 전투
    validate_combat(d, rep, pparts, enemies, eparts)

    # 생존·베이스캠프
    for sv in d["Survival"]:
        w = f"Survival {sv['_row']}행 ({sv['param_id']})"
        if sv["max"] is not None and sv["max"] <= 0:
            rep.err(w, "max 는 0보다 커야 함")
        if None not in (sv["start"], sv["max"]) and not (0 <= sv["start"] <= sv["max"]):
            rep.err(w, "start 는 0~max")
    for ca in d["CampActions"]:
        w = f"CampActions {ca['_row']}행 ({ca['action_id']})"
        if ca["kind"] not in CAMP_KINDS:
            rep.err(w, f"kind 는 비우거나 sleep: '{ca['kind']}'")
        if ca["kind"] == "sleep" and ca["minutes"] != 60:
            rep.err(w, "sleep 행동의 minutes 는 60 (1시간 단위로 잔다)")
        if ca["minutes"] is not None and ca["minutes"] < 0:
            rep.err(w, "minutes 는 0 이상")
        check_cond(w, ca["condition"])
        if check_effects(w, ca["effects"], None):
            rep.err(w, "베이스캠프 행동에는 goto 를 쓸 수 없음")
    for key in ("start_map", "basecamp_map"):
        if key in config and config[key]["value"] not in d["_maps"]:
            rep.err("Config", f"{key} 는 tools/maps 의 맵 이름: '{config[key]['value']}'")
    for rv in d["Revivals"]:
        w = f"Revivals {rv['_row']}행 ({rv['revive_id']})"
        if not rv["condition"]:
            rep.err(w, "condition 이 비어 있음 (비우면 항상 부활해 죽음이 없어진다)")
        check_cond(w, rv["condition"])
        if check_effects(w, rv["effects"], None):
            rep.err(w, "부활 효과에는 goto 를 쓸 수 없음")

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
        w = f"{loc('Nodes', n)} ({nid})"
        ep = n["episode_id"]
        if ep != "" and ep not in eps:
            rep.err(w, f"없는 episode_id '{ep}'")
        if n["speaker_id"] and n["speaker_id"] not in chars:
            rep.err(w, f"없는 speaker_id '{n['speaker_id']}'")
        out = set(check_effects(w + " on_enter", n["on_enter"], ep))
        if n["next_node"]:
            check_target(w + " next_node", n["next_node"], ep)
            if not n["next_node"].startswith("END:"):
                out.add(n["next_node"])
        elif nid not in choices_by_node and not out:
            rep.err(w, "출구 없음 (선택지·next_node·END/EXIT 모두 없음)")
        edges[nid] = out

    for c in d["Choices"]:
        w = f"{loc('Choices', c)} ({c['choice_id']})"
        node = nodes.get(c["node_id"])
        if node is None:
            rep.err(w, f"없는 node_id '{c['node_id']}'")
            continue
        ep = node["episode_id"]
        if c["show_mode"] not in SHOW_MODES:
            rep.err(w, f"show_mode 는 hide 또는 gray: '{c['show_mode']}'")
        check_cond(w, c["condition"])
        gotos = check_effects(w, c["effects"], ep)
        ctype = c["type"]
        if ctype not in CHOICE_TYPES:
            rep.err(w, f"type 은 normal / item / dice: '{ctype}'")
        if ctype == "item" and "has:" not in c["condition"]:
            rep.err(w, "item 선택지는 condition 에 has:아이템 이 필요")
        if c["mod"] and not INT_RE.match(c["mod"]):
            rep.err(w, f"mod 는 정수: '{c['mod']}'")
        if ctype == "dice":
            if c["check"] not in abils:
                rep.err(w, f"dice 선택지의 check 는 Abilities 의 ability_id: '{c['check']}'")
            if not INT_RE.match(c["dc"]):
                rep.err(w, f"dice 선택지의 dc(목표값)는 정수: '{c['dc']}'")
            fail_gotos = check_effects(w + " fail_effects", c["fail_effects"], ep)
            if c["fail_next"]:
                check_target(w + " fail_next", c["fail_next"], ep)
                if not c["fail_next"].startswith("END:"):
                    edges[c["node_id"]].add(c["fail_next"])
            elif not fail_gotos:
                rep.err(w, "실패 출구 없음 (fail_next 도 fail_effects 의 goto 도 없음)")
            edges[c["node_id"]].update(fail_gotos)
        else:
            for col in ("check", "dc", "mod", "fail_effects", "fail_next"):
                if c[col]:
                    rep.err(w, f"{col} 은 dice 선택지에서만 쓸 수 있음 (type='{ctype or 'normal'}')")
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

    # 도달성: 에피소드 시작 노드 + 시간 초과 노드, 필드 대화는 FieldObjects 의 npc 시작 노드에서 BFS
    reached = set()
    roots = [[ep["start_node"], ep["timeout_node"]] +
             [g for g in item_gotos if g in nodes and nodes[g]["episode_id"] == ep["episode_id"]]
             for ep in d["Episodes"]]
    roots.append([o["ref"] for o in d["FieldObjects"] if o.get("type") == "npc"])
    for root in roots:
        q = deque(x for x in root if x in nodes)
        while q:
            nid = q.popleft()
            if nid in reached:
                continue
            reached.add(nid)
            q.extend(x for x in edges.get(nid, ()) if x in nodes)
    for n in d["Nodes"]:
        if n["node_id"] not in reached and (n["episode_id"] in eps or n["episode_id"] == ""):
            rep.err(f"{loc('Nodes', n)} ({n['node_id']})",
                    "시작 노드에서 도달할 수 없음" if n["episode_id"] else "어떤 NPC(FieldObjects)에서도 도달할 수 없는 필드 대화")


def _scope(episode):
    return "필드 대화" if episode == "" else f"에피소드 {episode}"


def is_number(text):
    try:
        float(text)
        return True
    except ValueError:
        return False


def config_value(text):
    if not is_number(text):
        return text
    v = float(text)
    return int(v) if v.is_integer() else v


def is_true(text):
    return str(text).strip().lower() in TRUE_WORDS


def parse_strikes(pattern, targets):
    """공격 대상 → [{telegraph, target}]. combo: 'head,torso' / feint: 'torso>head' (전조 → 실제)."""
    if pattern == "feint":
        a, _, b = targets.partition(">")
        return [{"telegraph": a.strip(), "target": b.strip()}]
    return [{"telegraph": t, "target": t} for t in split_list(targets)]


def validate_combat(d, rep, pparts, enemies, eparts):
    if d["PlayerParts"]:
        if not any(is_true(p["vital"]) for p in d["PlayerParts"]):
            rep.err("PlayerParts", "vital(파괴 시 사망) 부위가 하나 이상 필요")
    for p in d["PlayerParts"]:
        w = f"PlayerParts {p['_row']}행 ({p['part_id']})"
        if p["key"].upper() not in DODGE_KEYS:
            rep.err(w, f"key 는 W/A/S/D: '{p['key']}'")
        if p["hp"] is not None and p["hp"] < 1:
            rep.err(w, "hp 는 1 이상")
    for p in d["EnemyParts"]:
        w = f"EnemyParts {p['_row']}행 ({p['enemy_id']}.{p['part_id']})"
        if p["enemy_id"] not in enemies:
            rep.err(w, f"없는 enemy_id '{p['enemy_id']}'")
        if p["hp"] is not None and p["hp"] < 1:
            rep.err(w, "hp 는 1 이상")
        if p["hit_chance"] is not None and not (0 <= p["hit_chance"] <= 100):
            rep.err(w, "hit_chance 는 0~100 (%)")
    for e in d["Enemies"]:
        own = [p for p in d["EnemyParts"] if p["enemy_id"] == e["enemy_id"]]
        if not any(is_true(p["vital"]) for p in own):
            rep.err(f"Enemies {e['_row']}행 ({e['enemy_id']})", "vital(파괴 시 사망) 부위가 하나 이상 필요")
        if not any(a["enemy_id"] == e["enemy_id"] for a in d["EnemyAttacks"]):
            rep.err(f"Enemies {e['_row']}행 ({e['enemy_id']})", "공격(EnemyAttacks)이 하나도 없음")
    for a in d["EnemyAttacks"]:
        w = f"EnemyAttacks {a['_row']}행 ({a['attack_id']})"
        if a["enemy_id"] not in enemies:
            rep.err(w, f"없는 enemy_id '{a['enemy_id']}'")
        if a["part"] and (a["enemy_id"], a["part"]) not in eparts:
            rep.err(w, f"part '{a['part']}' 는 {a['enemy_id']} 의 EnemyParts 에 없음")
        if a["pattern"] not in ATTACK_PATTERNS:
            rep.err(w, f"pattern 은 normal / quick / combo / feint: '{a['pattern']}'")
            continue
        if a["pattern"] == "feint" and ">" not in a["targets"]:
            rep.err(w, "feint 의 targets 는 '전조부위>실제부위' 형식 (예: torso>head)")
            continue
        strikes = parse_strikes(a["pattern"], a["targets"])
        if not strikes:
            rep.err(w, "targets 가 비어 있음")
        if a["pattern"] in ("normal", "quick") and len(strikes) > 1:
            rep.err(w, "여러 부위를 연속으로 치려면 pattern 을 combo 로")
        for t in dict.fromkeys(x for st in strikes for x in (st["telegraph"], st["target"])):
            if t not in pparts:
                rep.err(w, f"targets 의 없는 PlayerParts part_id '{t}'")
        if a["windup"] is not None and a["windup"] <= 0:
            rep.err(w, "windup(전조 시간, 초)은 0보다 커야 함")


def loc(sheet, r):
    """오류 위치: 엑셀 행이면 '시트 N행', 대화 파일이면 '대화 파일.json'"""
    return f"대화 {r['_row']}" if isinstance(r["_row"], str) else f"{sheet} {r['_row']}행"


def read_dialogues(d, rep):
    """tools/dialogues/*.json (대화 에디터 파일) 의 노드·선택지를 엑셀 Nodes·Choices 뒤에 붙인다."""
    if not DIALOGUES_DIR.exists():
        return
    node_cols = SCHEMA["Nodes"][1]
    choice_cols = SCHEMA["Choices"][1] + OPTIONAL.get("Choices", [])
    for f in sorted(DIALOGUES_DIR.glob("*.json")):
        try:
            dlg = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, OSError) as e:
            rep.err(f"대화 {f.name}", f"파일을 읽을 수 없음: {e}")
            continue
        episode = str(dlg.get("episode_id", "") or "")
        for n in dlg.get("nodes", []):
            rec = {c: _dlg_str(n.get(c, "")) for c in node_cols}
            rec["episode_id"] = episode
            rec["_row"] = f"{f.name}"
            d["Nodes"].append(rec)
        for c in dlg.get("choices", []):
            rec = {k: _dlg_str(c.get(k, "")) for k in choice_cols}
            if rec["type"] != "dice":
                rec["dc"] = rec["mod"] = ""
            elif rec["mod"] == "0":
                rec["mod"] = ""
            rec["_row"] = f"{f.name}"
            d["Choices"].append(rec)


def _dlg_str(v):
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def read_maps(rep):
    """tools/maps/<map_id>.json (맵 에디터 파일) → {map_id: {...}}

    { map_id, tiles: ["#..#", ...], start: [x, y] (도착 위치 P), run_start: [x, y] 또는 null (회차 시작 S),
      objects: [{object_id, type, x, y, ref, name, text, patrol_dir, patrol_len, condition, schedule}] }
    """
    maps = {}
    if not MAPS_DIR.exists():
        return maps
    for f in sorted(MAPS_DIR.glob("*.json")):
        try:
            m = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, OSError) as e:
            rep.err(f"맵 {f.name}", f"파일을 읽을 수 없음: {e}")
            continue
        m["file"] = f.name
        m["tiles"] = [str(r) for r in m.get("tiles", [])]
        m["objects"] = [{k: _dlg_str(v) if k not in ("x", "y", "patrol_len") else v for k, v in o.items()}
                        for o in m.get("objects", [])]
        maps[f.stem] = m
    for f in sorted(MAPS_DIR.glob("*.txt")):
        rep.err(f"맵 {f.name}", ".txt 맵은 더 이상 읽지 않음 — Godot '맵' 탭(맵 에디터)의 .json 으로 옮길 것")
    return maps


def field_objects(maps):
    """맵 파일들의 물체를 한 목록으로 (map_id 포함). 대화 도달성 검사 등에 쓴다."""
    out = []
    for mid, m in maps.items():
        for o in m["objects"]:
            out.append(dict(o, map_id=mid, _row=m["file"]))
    return out


def validate_field(d, maps, rep, enemies):
    spots = {r["spot_id"] for r in d["Loot"] if r["spot_id"]}
    nodes = {n["node_id"]: n for n in d["Nodes"]}
    seen = {}
    for mid, m in maps.items():
        wm = f"맵 {m['file']}"
        if m.get("map_id", mid) != mid:
            rep.err(wm, f"map_id '{m.get('map_id')}' 가 파일 이름과 다름")
        tiles = m["tiles"]
        if not tiles:
            rep.err(wm, "tiles 가 비어 있음")
            continue
        width = max(len(r) for r in tiles)
        for y, row in enumerate(tiles):
            bad = set(row) - MAP_TILES
            if bad:
                rep.err(wm, f"{y + 1}행에 알 수 없는 칸 {sorted(bad)} (# 벽 / . 바닥)")

        def floor(x, y):
            return 0 <= y < len(tiles) and 0 <= x < len(tiles[y]) and tiles[y][x] == "."

        for key, label in (("start", "도착 위치 P"), ("run_start", "회차 시작 S")):
            pos = m.get(key)
            if pos is None:
                if key == "start":
                    rep.err(wm, "도착 위치 P 가 없음")
                continue
            if not (isinstance(pos, list) and len(pos) == 2 and floor(int(pos[0]), int(pos[1]))):
                rep.err(wm, f"{label} 위치가 바닥이 아님: {pos}")
        occupied = {}
        for o in m["objects"]:
            oid = o.get("object_id", "")
            w = f"{wm} 물체 {oid or '(ID 없음)'}"
            if not ID_RE.match(oid):
                rep.err(w, "object_id 는 영문·숫자·_")
            elif oid in seen:
                rep.err(w, f"object_id 중복 (맵 {seen[oid]} 과 겹침)")
            else:
                seen[oid] = m["file"]
            x, y = int(o.get("x", -1)), int(o.get("y", -1))
            if not floor(x, y):
                rep.err(w, f"위치 ({x}, {y}) 가 바닥이 아님")
            elif (x, y) in occupied:
                rep.err(w, f"위치 ({x}, {y}) 에 이미 {occupied[(x, y)]} 가 있음")
            occupied[(x, y)] = oid
            t = o.get("type", "")
            ref = o.get("ref", "")
            if t not in FIELD_TYPES:
                rep.err(w, f"type 은 enemy / investigate / npc / camp / exit: '{t}'")
            elif t == "enemy" and ref not in enemies:
                rep.err(w, f"적 종류(ref)는 Enemies 의 enemy_id: '{ref}'")
            elif t == "npc" and (ref not in nodes or nodes[ref]["episode_id"] != ""):
                rep.err(w, f"NPC 의 대화(ref)는 필드 대화 시작 노드: '{ref}'")
            elif t == "exit" and ref not in maps:
                rep.err(w, f"출구의 ref 는 이동할 맵 이름: '{ref}'")
            elif t == "investigate" and ref and ref not in spots:
                rep.err(w, f"조사의 ref 는 Loot 의 spot_id (없으면 비움): '{ref}'")
            pdir, plen = o.get("patrol_dir", ""), int(o.get("patrol_len", 0) or 0)
            if pdir not in PATROL_DIRS:
                rep.err(w, f"patrol_dir 은 up/down/left/right: '{pdir}'")
            elif pdir and t != "enemy":
                rep.err(w, "순찰은 적만")
            elif pdir:
                dx, dy = PATROL_DIRS[pdir]
                for i in range(1, plen + 1):
                    if not floor(x + dx * i, y + dy * i):
                        rep.err(w, f"순찰 경로 {i}칸째 ({x + dx * i}, {y + dy * i}) 가 벽")
                        break
            if o.get("schedule"):
                if t != "npc":
                    rep.err(w, "schedule(루틴) 은 NPC 만")
                for rng in split_list(o["schedule"]):
                    if parse_time_range(rng) is None:
                        rep.err(w, f"schedule 은 '시:분-시:분' 을 쉼표로 (예: 06:00-12:00, 22:00-02:00): '{rng}'")
            if o.get("condition"):
                try:
                    parse_condition(o["condition"])
                except ExprError as e:
                    rep.err(w, f"condition 문법 오류: {e}")


TIME_RANGE_RE = re.compile(r"^(\d{1,2}):(\d{2})\s*-\s*(\d{1,2}):(\d{2})$")


def parse_time_range(text):
    """'06:00-12:00' → [360, 720] (하루 중 분). 끝이 시작보다 작으면 자정을 넘는 범위. 형식 오류면 None."""
    m = TIME_RANGE_RE.match(text.strip())
    if not m:
        return None
    h1, m1, h2, m2 = (int(g) for g in m.groups())
    if not (0 <= h1 <= 24 and 0 <= h2 <= 24 and m1 < 60 and m2 < 60) or h1 * 60 + m1 > 1440 or h2 * 60 + m2 > 1440:
        return None
    start, end = h1 * 60 + m1, h2 * 60 + m2
    return None if start == end else [start, end]


def export_maps(d, maps):
    out = []
    for mid, m in maps.items():
        width = max(len(r) for r in m["tiles"])
        tiles = [r.ljust(width, "#") for r in m["tiles"]]
        objects = []
        for o in m["objects"]:
            e = {k: o.get(k, "") for k in ("object_id", "type", "ref", "name", "text", "condition")}
            e.update(map_id=mid, x=int(o["x"]), y=int(o["y"]), patrol_dir=o.get("patrol_dir", ""),
                     patrol_len=int(o.get("patrol_len", 0) or 0),
                     schedule=[parse_time_range(r) for r in split_list(o.get("schedule", ""))])
            objects.append(e)
        start = m.get("start") or [0, 0]
        out.append({"map_id": mid, "width": width, "height": len(tiles), "tiles": tiles, "start": start,
                    "run_start": m.get("run_start") or start, "objects": objects})
    return out


# ---------------------------------------------------------------- 출력
def export(d, maps):
    def clean(rows):
        return [{k: v for k, v in r.items() if k != "_row"} for r in rows]

    def abil_values(text):
        return {m.group(1): int(m.group(2)) for m in (ABIL_VALUE_RE.match(a) for a in split_list(text))}

    def bonuses(text):
        return [{"ability": m.group(1), "value": int(m.group(2))}
                for m in (BONUS_RE.match(b) for b in split_list(text))]

    def choice(r):
        return dict(r, type=r["type"] or "normal", dc=int(r["dc"]) if r["dc"] else 0,
                    mod=int(r["mod"]) if r["mod"] else 0)

    out = {
        "episodes": clean(d["Episodes"]),
        "nodes": clean(d["Nodes"]),
        "choices": [choice(r) for r in clean(d["Choices"])],
        "items": [dict(r, dice_bonus=bonuses(r["dice_bonus"])) for r in clean(d["Items"])],
        "loot": clean(d["Loot"]),
        "characters": [dict(r, traits=split_list(r["traits"]), abilities=abil_values(r["abilities"]))
                       for r in clean(d["Characters"])],
        "abilities": clean(d["Abilities"]),
        "player_parts": [dict(r, key=r["key"].upper(), vital=is_true(r["vital"])) for r in clean(d["PlayerParts"])],
        "enemies": [dict(e,
                         parts=[dict(p, vital=is_true(p["vital"])) for p in clean(d["EnemyParts"])
                                if p["enemy_id"] == e["enemy_id"]],
                         attacks=[dict(a, strikes=parse_strikes(a["pattern"], a["targets"]))
                                  for a in clean(d["EnemyAttacks"]) if a["enemy_id"] == e["enemy_id"]])
                    for e in clean(d["Enemies"])],
        "maps": export_maps(d, maps),
        "survival": clean(d["Survival"]),
        "camp_actions": clean(d["CampActions"]),
        "revivals": clean(d["Revivals"]),
        "endings": [dict(r, world_flags_set=split_list(r["world_flags_set"])) for r in clean(d["Endings"])],
        "config": {r["key"]: config_value(r["value"]) for r in d["Config"]},
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, obj in out.items():
        # Path.write_text(newline=) 는 Python 3.10+ 라서 open() 사용 (맥 기본 Python 3.9 지원)
        with open(OUT_DIR / f"{name}.json", "w", encoding="utf-8", newline="\n") as fp:
            fp.write(json.dumps(obj, ensure_ascii=False, indent=1) + "\n")
    return out


def main():
    """사용법: python tools/xlsx_to_json.py [xlsx 경로] [--log 결과파일]
    --log: 출력을 UTF-8 파일로도 남긴다 (대화 에디터가 읽음 — 윈도우 콘솔 인코딩과 무관하게)."""
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    args = sys.argv[1:]
    log_path = None
    if "--log" in args:
        i = args.index("--log")
        log_path = args[i + 1] if i + 1 < len(args) else None
        del args[i:i + 2]
    lines = []

    def say(text):
        print(text)
        lines.append(text)

    try:
        return _run(Path(args[0]) if args else DEFAULT_XLSX, say)
    finally:
        if log_path:
            with open(log_path, "w", encoding="utf-8", newline="\n") as fp:
                fp.write("\n".join(lines) + "\n")


def _run(path, say):
    if not path.exists():
        say(f"파일 없음: {path}")
        return 1
    rep = Report()
    try:
        data = read_sheets(path, rep)
    except PermissionError:
        say(f"파일을 열 수 없음(다른 프로그램이 잠금?): {path}")
        return 1
    read_dialogues(data, rep)
    maps = read_maps(rep)
    data["_maps"] = maps
    data["FieldObjects"] = field_objects(maps)
    validate(data, rep)
    validate_field(data, maps, rep, {e["enemy_id"] for e in data["Enemies"]})
    if rep.errors:
        say(f"오류 {len(rep.errors)}개 — JSON을 쓰지 않았습니다.")
        for e in rep.errors:
            say("  " + e)
        return 1
    out = export(data, maps)
    say("변환 완료 → " + str(OUT_DIR))
    for k, v in out.items():
        say(f"  {k}.json: {len(v)}개")
    return 0


if __name__ == "__main__":
    sys.exit(main())
