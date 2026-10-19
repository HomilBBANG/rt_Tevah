#!/usr/bin/env python3
"""tools/sheets/*.xlsx (+ tools/maps/*.json, tools/dialogues/*.json) → res://data/*.json 변환 + 데이터 검사. Python 3.9+.

엑셀은 여러 파일로 나뉜다 (SHEET_FILES): player.xlsx (플레이어), npc.xlsx (NPC·적), item.xlsx (아이템·Loot),
content.xlsx (나머지: 에피소드 대화, 능력치 이름, Config, 생존, 거점, 부활 …).

대화(노드·선택지)는 Godot 의 '대화' 탭(addons/dialogue_editor)이 만드는 tools/dialogues/*.json 이 원본이고,
엑셀 Nodes·Choices 시트와 합쳐서 검사·출력한다.

사용법:  python tools/xlsx_to_json.py [엑셀 폴더 또는 content.xlsx 경로]
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
SHEETS_DIR = ROOT / "tools" / "sheets"
# 시트 → 엑셀 파일 (여기 없는 시트는 content.xlsx)
SHEET_FILES = {
    "Player": "player.xlsx", "PlayerParts": "player.xlsx", "EquipSlots": "player.xlsx", "Traits": "player.xlsx",
    "StatusEffects": "status.xlsx",
    "Tiles": "graphics.xlsx", "LightPresets": "graphics.xlsx", "DayNight": "graphics.xlsx", "Props": "graphics.xlsx",
    "Npcs": "npc.xlsx", "NpcParts": "npc.xlsx", "NpcAttacks": "npc.xlsx",
    "Items": "item.xlsx", "Loot": "item.xlsx",
}
CONTENT_FILE = "content.xlsx"
MAPS_DIR = ROOT / "tools" / "maps"
AI_DIR = ROOT / "tools" / "ai"   # 몬스터 AI 자산 (BT_·BB_·BTT_ — Godot '몬스터 AI' 탭이 만들고 그 탭의 Compile 이 자세히 검사)
DIALOGUES_DIR = ROOT / "tools" / "dialogues"
OUT_DIR = ROOT / "data"

STATS = {"hp", "sanity", "time"}
SHOW_MODES = {"", "hide", "gray"}
NODE_KINDS = {"", "line", "effect", "branch", "start", "direct"}
# 시작 카드의 자동 시작 (trigger.when): 로고 / 타이틀 이전 / 타이틀 이후 / 새 게임 시작 후 / 방 진입 후
TRIGGER_WHENS = {"logo", "before_title", "after_title", "new_game", "map_enter"}
# direct = 🎬 연출 카드: steps [{do, ...}] 를 차례로 (core/direction.gd 와 같은 규칙)
DIRECT_STEPS = {"image", "image_off", "fade", "shake", "wait", "sound", "music", "music_off", "walk", "camera", "vanish", "face"}
CUTSCENE_DIR = ROOT / "art" / "cutscenes"
AUDIO_DIRS = {"sound": ROOT / "audio" / "sfx", "music": ROOT / "audio" / "bgm"}
FACE_DIRS = {"up", "down", "left", "right"}
# start = 대화 시작 카드 (NPC 대화 파일마다 하나). routes 를 위에서부터 보고 조건이 맞는 첫 길로, 없으면 next_node(그 외).
# 대본 페이지 (core/script_pages.gd 와 같은 규칙). 노드의 pages 가 없으면 speaker_id·text 로 페이지 1개.
PAGE_DISPLAYS = {"narration", "bubble", "system", "subtitle"}   # subtitle = 자막 (상자 없이 화면 아래)
PAGE_SPEEDS = {"", "instant", "slow", "normal", "fast"}
PAUSE_RE = re.compile(r"\{w=(\d+(?:\.\d+)?)\}")
CHOICE_TYPES = {"", "normal", "item", "dice", "combat"}
REQUIRED_CONFIG = ["inventory_slots", "hp_start", "hp_max", "sanity_start", "sanity_max", "time_start", "time_max"]

# 능력치 6개 (Player·Npcs 의 열 이름 = Abilities 시트의 ability_id). 주사위 판정 check 와 abil: 조건·효과에 쓴다
ABILITY_COLS = ["strength", "endurance", "intelligence", "health", "mental", "divinity"]

# 시트 → (ID 열, 열 목록, 숫자 열 {이름: (타입, 기본값)})
SCHEMA = {
    "Episodes": ("episode_id", ["episode_id", "title", "protagonist_id", "start_node", "unlock_condition",
                                "timeout_node", "death_ending", "madness_ending"], {}),
    "Nodes": ("node_id", ["node_id", "episode_id", "speaker_id", "text", "next_node", "on_enter"], {}),
    "Choices": ("choice_id", ["choice_id", "node_id", "text", "condition", "show_mode", "cost", "effects",
                              "next_node"], {}),
    "Items": ("item_id", ["item_id", "name", "type", "description", "use_effects", "stack_max"],
              {"stack_max": (int, 1), "weight": (float, 0.0), "bag_slots": (int, 0)}),
    # 장비 칸 (장비창). kind = 들어가는 종류 (Items.equip_slot 과 같으면 장착, hand 는 아무 아이템이나),
    # col·row = 장비창 격자 위치
    "EquipSlots": ("slot_id", ["slot_id", "name", "kind", "col", "row"], {"col": (float, 0.0), "row": (float, 0.0)}),
    "Loot": ("loot_id", ["loot_id", "spot_id", "item_id", "amount", "chance", "time_cost"],
             {"amount": (int, 1), "chance": (float, 100.0), "time_cost": (int, 0)}),
    # ---- 등장인물: 플레이어(주인공)와 NPC(적 포함 — NPC 와도 싸울 수 있다). 능력치 6개는 주사위 판정에도 쓴다
    "Player": ("player_id", ["player_id", "name", "walk_speed", "run_speed"] + ABILITY_COLS,
               dict({"walk_speed": (float, None), "run_speed": (float, None)}, **{a: (int, 0) for a in ABILITY_COLS})),
    "Npcs": ("npc_id", ["npc_id", "name"],
             dict({"walk_speed": (float, 0.0), "run_speed": (float, 0.0)}, **{a: (int, 0) for a in ABILITY_COLS})),
    "Endings": ("ending_id", ["ending_id", "episode_id", "world_flags_set"], {}),
    "Config": ("key", ["key", "value"], {}),   # 값은 숫자 또는 문자열(예: protagonist_id)
    "Abilities": ("ability_id", ["ability_id", "name"], {}),
    # 상태이상: 효과 status:+id / status:-id, 조건 status:id. description = 장비창 능력치 탭에서 마우스를 올리면 뜨는 설명
    "StatusEffects": ("status_id", ["status_id", "name", "description"], {}),
    # 그래픽 (기획 tevah_pixelart_2d_lighting_map_editor_spec_v1.0): 픽셀아트 타일, 광원 프리셋, 시간대 환경광
    "Tiles": ("tile_key", ["tile_key", "name", "layer", "file"], {"atlas_x": (int, 0), "atlas_y": (int, 0), "frames": (int, 1), "fps": (float, 6.0),
                                                                  "face_rows": (int, 1), "h": (int, 1)}),
    "LightPresets": ("preset_id", ["preset_id", "name", "color", "energy", "radius"], {"energy": (float, None), "radius": (float, None)}),
    "DayNight": ("profile_id", ["profile_id", "hour", "ambient"], {"hour": (float, None), "sun_energy": (float, 0.0)}),
    # 오브젝트 그림 (나무·가구): 놓은 칸 = 왼쪽 아래, foot_w·foot_h 칸 차지. solid = 지나갈 수 없음(+적 시야 막음)
    "Props": ("prop_id", ["prop_id", "name", "file"], {"foot_w": (int, 1), "foot_h": (int, 1)}),
    # 특성 (캐릭터 생성·사건·거래). points: 긍정은 소비(음수), 부정은 획득(양수)
    "Traits": ("trait_id", ["trait_id", "name", "polarity", "points"], {"points": (int, 0)}),
    # ---- 전투 (기획서 §7–9)
    # attack = 부위별 공격력 (TODO 기획: 전투 피해 공식에 아직 안 쓰임 — 플레이어 피해는 Config combat_player_damage,
    #          NPC 피해는 NpcAttacks.damage)
    "PlayerParts": ("part_id", ["part_id", "name", "key", "hp", "attack", "vital"], {"hp": (int, None), "attack": (int, 0)}),
    "NpcParts": ("part_id", ["npc_id", "part_id", "name", "hp", "attack", "hit_chance", "vital"],
                 {"hp": (int, None), "attack": (int, 0), "hit_chance": (float, None)}),
    "NpcAttacks": ("attack_id", ["attack_id", "npc_id", "name", "part", "pattern", "targets", "windup",
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
    # ---- 사망 원인: 사망 화면에 text (비우면 "{name}(으)로 인해 사망했습니다."). {enemy} = 전투 상대 이름
    "DeathCauses": ("cause_id", ["cause_id", "name", "text"], {}),
}

# 없어도 되는 시트 (없으면 빈 시트로 본다)
OPTIONAL_SHEETS = {"PlayerParts", "NpcParts", "NpcAttacks", "EquipSlots", "StatusEffects", "Traits", "Tiles", "LightPresets", "DayNight", "Props",
                   "Survival", "CampActions", "Revivals", "DeathCauses"}
# 맵 물체: exit 문(E 로 열고 걸어 들어가면 이동) / passage 통로(밟으면 이동) / transit 이용(사다리 등, E 로 이동) /
#         arrive 도착 지점 (이동할 때 arrive 로 고르면 P 대신 여기 도착)
FIELD_TYPES = {"enemy", "investigate", "npc", "camp", "exit", "passage", "transit", "arrive", "event", "light", "prop", "window", "furniture", "respawn", "stairs"}   # prop = 오브젝트 그림, window = 창문 (벽 칸 위), furniture = 기타 가구 (흰 사각형)
FURNITURE_ROLES = {"", "investigate", "pickup", "use", "talk"}   # 장식 / 조사 / 줍기 / 사용 / 대화
PROPS_DIR = ROOT / "art" / "props"
LIGHT_SHAPES = {"", "point", "cone"}   # light = 광원 (그래픽만)
# 칠하지 않고 물체에 씀: door = 문(exit) 그림 (닫힘 key, 열림 key_open), marker = 조사 지점 반짝이, window = 창문 (커튼 key_curtain)
OBJECT_ART_LAYERS = {"door", "marker", "window", "camp", "lamp", "stairs"}   # stairs = 계단 물체 그림   # camp = 거점 그림, lamp = 벽걸이등
# 그래픽 층: 바닥 / 바닥 장식 / 벽 외형 / 지붕 (인물 위 — 집 안에 들어가면 사라짐) / 전경 가림 (인물 위, 늘 보임 — 충돌·시야·빛 차단 없음)
TILE_LAYERS = {"floor", "detail", "wall", "roof", "overhead"}
TILES_DIR = ROOT / "art" / "tiles"
LIGHT_NUMS = ("energy", "radius")   # event = 밟으면 대화(컷신)
TRAVEL_TYPES = {"exit", "passage", "transit", "stairs"}   # stairs = 계단 (밟으면 이동, 층 사이)
EDGE_DIRS = {"up", "down", "left", "right"}
CAMP_KINDS = {"", "sleep"}   # sleep: 1시간 단위로 골라 자고, 자고 나면 저장 (effects 는 1시간마다)
PATROL_DIRS = {"": (0, 0), "up": (0, -1), "down": (0, 1), "left": (-1, 0), "right": (1, 0)}
MAP_TILES = {"#", ".", " "}   # 벽 / 바닥 / 빈 공간(검은색, 지나갈 수 없음)
# ID 중복 검사를 여러 열 조합으로 하는 시트
DUP_KEYS = {"NpcParts": ("npc_id", "part_id"), "DayNight": ("profile_id", "hour")}
DODGE_KEYS = {"W", "A", "S", "D"}
ATTACK_PATTERNS = {"normal", "quick", "combo", "feint"}
TRUE_WORDS = {"y", "yes", "true", "1", "o", "v"}

# 없어도 되는 열 (시트에 없으면 빈 값으로 본다)
OPTIONAL = {
    "Player": ["name_color",        # 대화 이름표 색 (#RRGGBB). 비우면 기본색
               "traits"],           # 능력(trait:) 쉼표로 여러 개
    # walk_speed·run_speed: 필드 이동 속도(칸/초) — 순찰은 걷기, 추격은 달리기. 부위·공격(NpcParts·NpcAttacks)이 있으면 전투 가능
    # kind: monster(몬스터, 맵에서 마주치면 전투부터) / npc (비우면 npc)
    # battle_bt: 전투 BT (tools/ai 의 BT_, domain=battle) — 있으면 적 공격을 그 트리가 고름, 비우면 NpcAttacks weight
    "Npcs": ["kind", "name_color", "traits", "image", "flee_chance", "walk_speed", "run_speed", "battle_bt"] + ABILITY_COLS,
    "Items": ["dice_bonus",         # 소지 시 판정 보정 "strength+2, all+1"
              "weight",             # 무게 (개당). 들고 있는 무게가 Config carry_* 를 넘으면 느려지고, 최대면 못 움직임
              "equip_slot",         # 장착 종류 (EquipSlots 의 kind). 비워도 손(kind=hand)에는 들 수 있음
              "bag_slots",          # 장착하면 늘어나는 인벤토리 칸 수 (가방)
              "light"],             # 손에 들면 플레이어가 들고 다니는 빛 (graphics.xlsx LightPresets 의 preset_id, 예: 손전등)
    # 선택지 종류: normal(기본) / item / dice
    # dice: check=능력치, dc=목표값, mod=상황 보정, 실패 시 fail_effects·fail_next
    # combat: check=npc_id(싸울 수 있는 NPC), 이기면 effects·next_node, 도주하면 fail_effects·fail_next (필드 대화 전용)
    "Choices": ["type", "check", "dc", "mod", "fail_effects", "fail_next"],
    # 노드 종류(대화 에디터의 기능 카드): line(기본, 대사) / effect(on_enter 효과만 실행하고 next_node 로) /
    # branch(condition 이 맞으면 next_node, 아니면 fail_next). effect·branch 는 화면에 보이지 않는다
    "Nodes": ["kind", "condition", "fail_next"],
    # 특성: category 화면 분류, conflicts 같이 못 고르는 trait_id(쉼표), selectable 1 = 생성 화면에서 고름, state 기획 상태
    "Traits": ["category", "description", "conflicts", "selectable", "state", "note"],
    # 상태이상: scope part(부위)/whole(전체), tick_mode·tick_amount 시간마다 효과(미정이면 빈칸), death_cause 사망 원인
    # frames·fps: 애니메이션 (atlas_x 부터 오른쪽으로 frames 장, 초당 fps 장 — 조사 반짝이 등)
    # face·face_rows: 비스듬한 탑뷰 — 벽 타일 아래(남쪽) face_rows 칸 안에 바닥이 있으면 face(앞면) 타일로 그림
    # h: 그림 높이(칸) — 2칸 높이 문 등 (atlas_y 부터 아래로 h 칸)
    "Tiles": ["atlas_x", "atlas_y", "casts_shadow", "note", "frames", "fps", "face", "face_rows", "h"],
    "LightPresets": ["shadow", "shape", "note"],
    "Props": ["foot_w", "foot_h", "solid", "casts_shadow", "note"],
    "DayNight": ["sun_color", "sun_energy", "note"],
    "StatusEffects": ["scope", "tick_mode", "tick_amount", "stack_rule", "dispel", "death_cause", "state", "note"],
    # 생존: death_cause = 0 이 되면 그 원인(DeathCauses 의 cause_id)으로 사망. 비우면 0 이어도 죽지 않음
    "Survival": ["death_cause"],
    "DeathCauses": ["note"],
}
TRAIT_POLARITY = {"positive", "negative"}
STATUS_SCOPES = {"", "part", "whole"}
TICK_MODES = {"", "game_hour", "game_minute", "real_second", "combat_turn"}

ID_RE = re.compile(r"^[A-Za-z0-9_]+$")
EXIT = "EXIT"   # 필드 대화 끝 → 필드로 복귀
COLOR_RE = re.compile(r"^#?[0-9A-Fa-f]{6}$")
INT_RE = re.compile(r"^-?\d+$")
ABIL_VALUE_RE = re.compile(r"^([A-Za-z0-9_]+)\s*=\s*(-?\d+)$")
BONUS_RE = re.compile(r"^([A-Za-z0-9_]+)\s*([+-]\d+)$")


class Report:
    def __init__(self):
        self.errors = []
        self.warnings = []   # 변환은 하지만 확인해 볼 것 (빈 대사 등)

    def err(self, where, msg):
        self.errors.append(f"[{where}] {msg}")

    def warn(self, where, msg):
        self.warnings.append(f"[{where}] {msg}")


# ---------------------------------------------------------------- 조건·효과 문법
# 런타임 파서(core/expr.gd)와 같은 문법. 한쪽을 바꾸면 다른 쪽도 맞춰야 한다.
COUNTS = {"run", "death", "talk"}   # count: 조건 (월드 run_count·death_count, talk = 이 대화를 전에 한 횟수)
ATOM_RE = re.compile(r"(has|flag|wflag|stat|trait|abil|surv|cut|count|status|combat):([A-Za-z0-9_]+)(?:(>=|<=|==|>|<)(-?\d+(?:\.\d+)?))?")


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
            elif kind == "count":
                if ident not in COUNTS:
                    raise ExprError(f"알 수 없는 기록 '{ident}' (가능: {', '.join(sorted(COUNTS))})")
                if not op:
                    raise ExprError(f"'{m.group(0)}': count 조건에는 비교식이 필요 (예: count:death>=1)")
            elif kind == "surv" and not op:
                raise ExprError(f"'{m.group(0)}': surv 조건에는 비교식이 필요 (예: surv:hunger<30)")
            elif kind == "abil" and not op:
                raise ExprError(f"'{m.group(0)}': abil 조건에는 비교식이 필요 (예: abil:strength>=3)")
            elif kind in ("flag", "wflag", "trait", "cut", "status", "combat") and op:
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
    ("simple", re.compile(r"^(setflag|clearflag|setwflag|loot|goto|restore|endcombat|die):([A-Za-z0-9_]+)$")),   # die = 사망 (DeathCauses)
    ("save", re.compile(r"^save$")),   # 회차 저장 (베이스캠프 안에서만 동작)
    ("status", re.compile(r"^status:([+-])([A-Za-z0-9_]+)$")),   # 상태이상 걸기·풀기
    ("trait_fx", re.compile(r"^trait:([+-])([A-Za-z0-9_]+)$")),   # 특성 얻기·잃기 (사건·거래)
    ("move", re.compile(r"^move:([A-Za-z0-9_]+)(?:@([A-Za-z0-9_]+))?$")),   # 맵 이동 (도착 지점)
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
            elif kind == "status":
                refs.append(("status", m.group(2)))
            elif kind == "trait_fx":
                refs.append(("trait_fx", m.group(2)))
            elif kind == "move":
                refs.append(("move", (m.group(1), m.group(2) or "")))
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


def read_sheets(folder, rep):
    """SHEET_FILES 에 따라 시트마다 그 엑셀 파일에서 읽는다. 잠긴 파일은 PermissionError."""
    books = {}
    data = {}
    for sheet, (id_col, cols, numeric) in SCHEMA.items():
        fname = SHEET_FILES.get(sheet, CONTENT_FILE)
        if fname not in books:
            fpath = folder / fname
            books[fname] = load_workbook(fpath, data_only=True, read_only=True) if fpath.exists() else None
            if books[fname] is None:
                rep.err(fname, f"엑셀 파일이 없음: {fpath}")
        wb = books[fname]
        if wb is None:
            data[sheet] = []
            continue
        if sheet not in wb.sheetnames:
            if sheet not in OPTIONAL_SHEETS:
                rep.err(sheet, f"시트가 없음 ({fname})")
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
    items, loots, endings = index("Items"), index("Loot"), index("Endings")
    players, npcs = index("Player"), index("Npcs")
    chars = dict(npcs, **players)   # 대화 화자 = 플레이어 + NPC
    for pid in set(players) & set(npcs):
        rep.err(loc("Npcs", npcs[pid]), f"ID '{pid}' 가 Player 시트에도 있음 (플레이어·NPC ID 는 서로 달라야 함)")
    config, abils = index("Config"), index("Abilities")
    survs = index("Survival")
    causes = index("DeathCauses")
    stats_fx = index("StatusEffects")
    traits = index("Traits")
    for t in d["Traits"]:
        w = loc("Traits", t)
        if t["polarity"] not in TRAIT_POLARITY:
            rep.err(w, f"polarity 는 positive / negative: '{t['polarity']}'")
        elif t["polarity"] == "positive" and t["points"] > 0:
            rep.err(w, f"긍정 특성은 포인트를 소비 (음수): {t['points']}")
        elif t["polarity"] == "negative" and t["points"] < 0:
            rep.err(w, f"부정 특성은 포인트를 획득 (양수): {t['points']}")
        for other in split_list(t["conflicts"]):
            if other not in traits:
                rep.err(w, f"conflicts 에 없는 trait_id '{other}'")
            elif other == t["trait_id"]:
                rep.err(w, "conflicts 에 자기 자신")
        if t["selectable"] and t["selectable"].lower() not in TRUE_WORDS | {"0", "n", "no", "false", "x"}:
            rep.err(w, f"selectable 은 1 / 0: '{t['selectable']}'")
    for st in d["StatusEffects"]:
        w = loc("StatusEffects", st)
        if st["scope"] not in STATUS_SCOPES:
            rep.err(w, f"scope 는 part / whole: '{st['scope']}'")
        if st["tick_mode"] not in TICK_MODES:
            rep.err(w, f"tick_mode 는 {' / '.join(sorted(m for m in TICK_MODES if m))}: '{st['tick_mode']}'")
        if st["tick_amount"] and not _is_number(st["tick_amount"]):
            rep.err(w, f"tick_amount 는 숫자: '{st['tick_amount']}'")

    def check_trait(where, tid):
        # 예전 테스트 데이터의 이름(tester 등)이 있어 오류가 아니라 경고
        if traits and tid not in traits:
            rep.warn(where, f"Traits 시트(player.xlsx)에 없는 특성 '{tid}'")
    pparts, eparts, eattacks = index("PlayerParts"), index("NpcParts"), index("NpcAttacks")
    # 부위나 공격이 있는 NPC = 싸울 수 있는 NPC (맵의 적·대화 전투 선택지 대상)
    fighters = {r["npc_id"] for r in d["NpcParts"]} | {r["npc_id"] for r in d["NpcAttacks"]}
    enemies = {k: v for k, v in npcs.items() if k in fighters}
    d["_enemy_ids"] = set(enemies)
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
            elif kind == "restore":
                check_limb(where, rid, "all")
            elif kind == "status" and rid not in stats_fx:
                rep.err(where, f"없는 상태이상 '{rid}' (status.xlsx StatusEffects)")
            elif kind == "die" and rid not in causes:
                rep.err(where, f"없는 사망 원인 '{rid}' (content.xlsx DeathCauses)")
            elif kind == "endcombat" and rid not in ("win", "flee"):
                rep.err(where, f"endcombat 은 win(상대가 물러남) / flee(빠져나옴): '{rid}'")
            elif kind == "trait_fx" and rid not in traits:
                rep.err(where, f"없는 특성 '{rid}' (player.xlsx Traits)")
            elif kind == "move":
                err = travel_error(d.get("_maps", {}), rid[0], rid[1])
                if err:
                    rep.err(where, err)

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

    def check_limb(where, part_id, wildcard):
        """cut:/restore: 의 대상은 PlayerParts 의 vital 이 아닌 부위 (또는 any / all)"""
        if part_id == wildcard:
            return
        if part_id not in pparts:
            rep.err(where, f"없는 PlayerParts part_id '{part_id}' (팔다리 또는 '{wildcard}')")
        elif is_true(pparts[part_id]["vital"]):
            rep.err(where, f"'{part_id}' 는 치명 부위라 절단·복구 대상이 아님")

    def check_cond(where, text):
        if not text:
            return
        try:
            for kind, rid in parse_condition(text):
                if kind == "has" and rid not in items:
                    rep.err(where, f"조건의 없는 item_id '{rid}'")
                elif kind == "abil" and rid not in abils:
                    rep.err(where, f"조건의 없는 ability_id '{rid}'")
                elif kind == "cut":
                    check_limb(where, rid, "any")
                elif kind == "status" and rid not in stats_fx:
                    rep.err(where, f"조건의 없는 상태이상 '{rid}' (status.xlsx StatusEffects)")
                elif kind == "trait":
                    check_trait(where, rid)
                elif kind == "combat" and rid != "any" and rid not in enemies:
                    rep.err(where, f"조건 combat: 은 any 또는 싸울 수 있는 npc_id: '{rid}'")
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
    if "protagonist_id" in config and config["protagonist_id"]["value"] not in players:
        rep.err("Config", f"protagonist_id 는 Player 시트의 player_id: '{config['protagonist_id']['value']}'")

    # 능력치: Abilities 시트는 Player·Npcs 의 능력치 열과 같은 6개 (이름만 바꿀 수 있음)
    if set(abils) != set(ABILITY_COLS):
        rep.err("Abilities", f"ability_id 는 {', '.join(ABILITY_COLS)} 6개 (Player·Npcs 의 열 이름과 같아야 함)")
    # Player·Npcs
    for sheet in ("Player", "Npcs"):
        for c in d[sheet]:
            w = loc(sheet, c)
            if sheet == "Npcs" and c["kind"] not in ("", "npc", "monster"):
                rep.err(w, f"kind 는 monster / npc: '{c['kind']}'")
            if c["name_color"] and not COLOR_RE.match(c["name_color"]):
                rep.err(w, f"name_color 는 #RRGGBB 형식: '{c['name_color']}'")
            for t in split_list(c["traits"]):
                if not ID_RE.match(t):
                    rep.err(w, f"능력 이름 '{t}' 에는 영문·숫자·_ 만")
                else:
                    check_trait(w, t)
            if (c["walk_speed"] or 0) < 0 or (c["run_speed"] or 0) < 0:
                rep.err(w, "walk_speed·run_speed 는 0 이상 (칸/초)")
    for c in d["Player"]:
        if c["walk_speed"] is not None and c["walk_speed"] <= 0:
            rep.err(loc("Player", c), "walk_speed(걷기 속도)는 0보다 커야 함")

    # Items
    equip_slots = index("EquipSlots")
    equip_kinds = {r["kind"] for r in equip_slots.values() if r["kind"]}
    for r in equip_slots.values():
        if not r["kind"]:
            rep.err(loc("EquipSlots", r), "kind(들어가는 종류)가 비어 있음")
    for it in d["Items"]:
        w = f"Items {it['_row']}행 ({it['item_id']})"
        if it["stack_max"] is not None and it["stack_max"] < 1:
            rep.err(w, "stack_max 는 1 이상")
        if (it["weight"] or 0) < 0:
            rep.err(w, "weight 는 0 이상")
        if it["equip_slot"] and it["equip_slot"] not in equip_kinds:
            rep.err(w, f"equip_slot 은 EquipSlots 의 kind (player.xlsx): '{it['equip_slot']}' (가능: {', '.join(sorted(equip_kinds))})")
        if (it["bag_slots"] or 0) < 0:
            rep.err(w, "bag_slots 는 0 이상")
        if it["bag_slots"] and not it["equip_slot"]:
            rep.err(w, "bag_slots(늘어나는 칸)는 장착하는 아이템(equip_slot)에만")
        check_effects(w, it["use_effects"], None)
        for b in split_list(it["dice_bonus"]):
            m = BONUS_RE.match(b)
            if not m:
                rep.err(w, f"dice_bonus 는 '능력치+숫자' 또는 'all+숫자' 형식: '{b}'")
            elif m.group(1) != "all" and m.group(1) not in abils:
                rep.err(w, f"dice_bonus 의 없는 ability_id '{m.group(1)}'")

    # 전투
    validate_combat(d, rep, pparts, enemies, eparts)
    # 전투 BT: 있는 BT_·domain battle·트리의 UseAttack 공격이 그 NPC 의 것
    for e in d["Npcs"]:
        bid = e.get("battle_bt", "")
        if not bid:
            continue
        w = loc("Npcs", e)
        bt = d.get("_ai", {}).get(bid)
        if not bt or bt.get("asset_type") != "behavior_tree":
            rep.err(w, f"battle_bt 는 tools/ai 의 Behavior Tree (BT_): '{bid}'")
            continue
        if bt.get("domain", "field") != "battle":
            rep.err(w, f"battle_bt '{bid}' 의 domain 이 battle 이 아님 (몬스터 AI 탭 Root 에서 전투로)")
        if e["npc_id"] not in enemies:
            rep.err(w, "battle_bt 는 싸울 수 있는 NPC(NpcParts·NpcAttacks 가 있는)만")
            continue
        own = {a["attack_id"] for a in d["NpcAttacks"] if a["npc_id"] == e["npc_id"]}
        for n in bt.get("nodes", []):
            if n.get("task_type") == "UseAttack" and n.get("params", {}).get("attack_id") not in own:
                rep.err(w, f"battle_bt '{bid}' 의 {n.get('id')} 공격 '{n.get('params', {}).get('attack_id')}' 는 이 NPC 의 공격이 아님")

    # 생존·베이스캠프
    for sv in d["Survival"]:
        w = f"Survival {sv['_row']}행 ({sv['param_id']})"
        if sv["max"] is not None and sv["max"] <= 0:
            rep.err(w, "max 는 0보다 커야 함")
        if None not in (sv["start"], sv["max"]) and not (0 <= sv["start"] <= sv["max"]):
            rep.err(w, "start 는 0~max")
        if sv["death_cause"] and sv["death_cause"] not in causes:
            rep.err(w, f"death_cause 의 없는 사망 원인 '{sv['death_cause']}' (DeathCauses 시트)")
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
        if ep["protagonist_id"] not in players:
            rep.err(w, f"protagonist_id 는 Player 시트의 player_id: '{ep['protagonist_id']}'")
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
        elif nid not in choices_by_node and not out and n["kind"] != "start":   # 시작 카드는 아래에서 '그 외' 로 검사
            rep.err(w, "출구 없음 (선택지·next_node·END/EXIT 모두 없음)")
        check_pages(w, n, chars, rep)
        kind = n["kind"]
        if kind not in NODE_KINDS:
            rep.err(w, f"kind 는 line / effect / branch / start: '{kind}'")
        if kind == "direct":
            check_steps(w, n.get("steps") or [], d["FieldObjects"], rep)
            if not n["next_node"]:
                rep.err(w, "연출 카드에 '다음 →' 출구가 없음")
        elif n.get("steps"):
            rep.err(w, "steps 는 연출(kind=direct) 카드에서만")
        if kind in ("effect", "branch", "start", "direct") and nid in choices_by_node:
            rep.err(w, "효과·조건 분기·대화 시작 카드에는 선택지를 달 수 없음")
        routes = n.get("routes") or []
        trig = n.get("trigger") or {}
        if trig and kind != "start":
            rep.err(w, "자동 시작(trigger)은 대화 시작 카드에서만")
        elif trig:
            when = str(trig.get("when", ""))
            if when not in TRIGGER_WHENS:
                rep.err(w, f"자동 시작 시점은 {' / '.join(sorted(TRIGGER_WHENS))}: '{when}'")
            if when == "map_enter" and str(trig.get("map", "")) not in d.get("_maps", {}):
                rep.err(w, f"방 진입 자동 시작: 없는 맵 '{trig.get('map', '')}'")
        if kind == "start":
            if ep != "":
                rep.err(w, "대화 시작 카드는 NPC(필드) 대화에서만")
            if not n["next_node"]:
                rep.err(w, "대화 시작 카드에 '그 외 →' 출구가 없음")
            for i, r in enumerate(routes):
                rw = f"{w} 길 {i + 1}"
                if not isinstance(r, dict):
                    rep.err(rw, "길 형식이 아님")
                    continue
                cond = _dlg_str(r.get("condition", ""))
                target = _dlg_str(r.get("next_node", ""))
                if not cond:
                    rep.err(rw, "조건이 없음 (조건 없는 길은 '그 외 →' 로)")
                check_cond(rw, cond)
                if not target:
                    rep.err(rw, "갈 곳이 없음")
                else:
                    check_target(rw, target, ep)
                    out.add(target)
        elif routes:
            rep.err(w, "routes 는 대화 시작(kind=start) 카드에서만")
        if kind == "branch":
            if not n["condition"]:
                rep.err(w, "조건 분기 카드에 조건이 없음")
            check_cond(w, n["condition"])
            if not n["next_node"]:
                rep.err(w, "조건 분기의 '맞으면' 출구가 없음")
            if not n["fail_next"]:
                rep.err(w, "조건 분기의 '아니면' 출구가 없음")
            else:
                check_target(w + " fail_next", n["fail_next"], ep)
                if not n["fail_next"].startswith("END:"):
                    out.add(n["fail_next"])
        elif n["condition"] or n["fail_next"]:
            rep.err(w, "condition·fail_next 는 조건 분기(kind=branch) 카드에서만")
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
            rep.err(w, f"type 은 normal / item / dice / combat: '{ctype}'")
        if ctype == "item" and "has:" not in c["condition"]:
            rep.err(w, "item 선택지는 condition 에 has:아이템 이 필요")
        if c["mod"] and not INT_RE.match(c["mod"]):
            rep.err(w, f"mod 는 정수: '{c['mod']}'")
        if ctype == "dice":
            if c["check"] not in abils:
                rep.err(w, f"dice 선택지의 check 는 Abilities 의 ability_id: '{c['check']}'")
            if not INT_RE.match(c["dc"]):
                rep.err(w, f"dice 선택지의 dc(목표값)는 정수: '{c['dc']}'")
        elif ctype == "combat":
            if ep != "":
                rep.err(w, "combat 선택지는 필드 대화(episode_id 가 빈 노드)에서만")
            if c["check"] not in enemies:
                rep.err(w, f"combat 선택지의 check 는 싸울 수 있는 NPC(NpcParts·NpcAttacks 가 있는 npc_id): '{c['check']}'")
            for col in ("dc", "mod"):
                if c[col]:
                    rep.err(w, f"{col} 은 dice 선택지에서만 쓸 수 있음 (type='combat')")
        else:
            for col in ("check", "dc", "mod", "fail_effects", "fail_next"):
                if c[col]:
                    rep.err(w, f"{col} 은 dice·combat 선택지에서만 쓸 수 있음 (type='{ctype or 'normal'}')")
        if ctype in ("dice", "combat"):
            label = "실패" if ctype == "dice" else "도주"
            fail_gotos = check_effects(w + " fail_effects", c["fail_effects"], ep)
            if c["fail_next"]:
                check_target(w + " fail_next", c["fail_next"], ep)
                if not c["fail_next"].startswith("END:"):
                    edges[c["node_id"]].add(c["fail_next"])
            elif not fail_gotos:
                rep.err(w, f"{label} 출구 없음 (fail_next 도 fail_effects 의 goto 도 없음)")
            edges[c["node_id"]].update(fail_gotos)
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
    npc_refs = {o["ref"] for o in d["FieldObjects"] if o.get("type") in ("npc", "event")}
    roots.append(list(npc_refs))
    # 오프닝 컷신 (Config opening_dialogue): 새 게임에서 캐릭터 생성 직후 한 번
    opening = str(next((c["value"] for c in d["Config"] if c["key"] == "opening_dialogue"), "") or "")
    flagged = d.get("_openings", [])
    if len(flagged) > 1:
        rep.err("오프닝", "'게임 오프닝으로 쓰기'를 체크한 대화가 여럿: " + ", ".join(f for f, _ in flagged) + " (하나만)")
    if not opening and flagged:
        opening = flagged[0][1]
    d["_opening"] = opening
    if opening:
        if opening not in nodes or nodes[opening]["episode_id"] != "":
            rep.err("Config opening_dialogue", f"오프닝 대화는 필드 대화 노드: '{opening}'")
        roots.append([opening])
    # 대화 시작 카드는 맵에 아직 안 놓은 NPC 의 대화여도 검사가 통과하도록 뿌리로 (안 쓰이면 경고)
    roots.append([n["node_id"] for n in d["Nodes"] if n["kind"] == "start"])
    for n in d["Nodes"]:
        if n["kind"] == "start" and n["node_id"] not in npc_refs and n["node_id"] != opening and not n.get("trigger"):
            rep.warn(f"{loc('Nodes', n)} ({n['node_id']})", "어느 맵의 NPC 에도 연결되지 않은 대화 시작 카드")
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
    for p in d["NpcParts"]:
        w = f"NpcParts {p['_row']}행 ({p['npc_id']}.{p['part_id']})"
        if p["npc_id"] not in enemies:
            rep.err(w, f"Npcs 시트에 없는 npc_id '{p['npc_id']}'")
        if p["hp"] is not None and p["hp"] < 1:
            rep.err(w, "hp 는 1 이상")
        if p["hit_chance"] is not None and not (0 <= p["hit_chance"] <= 100):
            rep.err(w, "hit_chance 는 0~100 (%)")
    for e in enemies.values():
        w = f"Npcs {e['_row']}행 ({e['npc_id']})"
        if e["flee_chance"]:
            try:
                if not (0 <= float(e["flee_chance"]) <= 100):
                    raise ValueError
            except ValueError:
                rep.err(w, f"flee_chance 는 0~100 (%): '{e['flee_chance']}'")
        if e["image"]:
            if not e["image"].startswith("res://"):
                rep.err(w, f"image 는 res:// 경로: '{e['image']}'")
            elif not (ROOT / e["image"][len("res://"):]).is_file():
                rep.err(w, f"image 파일이 없음: '{e['image']}'")
        own = [p for p in d["NpcParts"] if p["npc_id"] == e["npc_id"]]
        if not any(is_true(p["vital"]) for p in own):
            rep.err(w, "싸울 수 있는 NPC: NpcParts 에 vital(파괴 시 사망) 부위가 하나 이상 필요")
        if not any(a["npc_id"] == e["npc_id"] for a in d["NpcAttacks"]):
            rep.err(w, "싸울 수 있는 NPC: 공격(NpcAttacks)이 하나도 없음")
    for a in d["NpcAttacks"]:
        w = f"NpcAttacks {a['_row']}행 ({a['attack_id']})"
        if a["npc_id"] not in enemies:
            rep.err(w, f"Npcs 시트에 없는 npc_id '{a['npc_id']}'")
        if a["part"] and (a["npc_id"], a["part"]) not in eparts:
            rep.err(w, f"part '{a['part']}' 는 {a['npc_id']} 의 NpcParts 에 없음")
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


def check_pages(w, n, chars, rep):
    """대본 페이지 검사. 오류: 표시 종류·화자·속도·넘김·{ } 표시. 경고: 빈 본문."""
    pages = n.get("pages") or []
    if n.get("kind") in ("effect", "branch", "start", "direct"):
        if pages:
            rep.err(w, "효과·조건 분기·대화 시작 카드에는 대본 페이지를 둘 수 없음")
        return
    if n.get("text_speed", "") not in PAGE_SPEEDS and not _is_pos_number(n.get("text_speed", "")):
        rep.err(w, f"대화 파일의 text_speed 가 이상함: '{n['text_speed']}'")
    if not pages:
        if isinstance(n["_row"], str) and not n["text"].strip():
            rep.warn(w, "대사가 비어 있음")
        return
    seen = set()
    for i, p in enumerate(pages):
        pw = f"{w} 페이지 {i + 1}"
        if not isinstance(p, dict):
            rep.err(pw, "페이지 형식이 아님")
            continue
        pid = str(p.get("page_id", "") or "")
        if pid and pid in seen:
            rep.err(pw, f"page_id 중복 '{pid}'")
        seen.add(pid)
        disp = str(p.get("display", "") or "")
        sp = str(p.get("speaker_id", "") or "")
        if disp not in PAGE_DISPLAYS:
            rep.err(pw, f"display 는 narration / bubble / system / subtitle: '{disp}'")
        elif disp == "bubble" and not sp:
            rep.err(pw, "말풍선 페이지에 화자(speaker_id)가 없음")
        if sp and sp not in chars:
            rep.err(pw, f"없는 speaker_id '{sp}'")
        speed = _dlg_str(p.get("speed", ""))
        if speed not in PAGE_SPEEDS and not _is_pos_number(speed):
            rep.err(pw, f"speed 는 instant / slow / normal / fast / 초당 글자 수: '{speed}'")
        adv = str(p.get("advance", "") or "input")
        if adv not in ("input", "auto"):
            rep.err(pw, f"advance 는 input / auto: '{adv}'")
        if adv == "auto" and _dlg_str(p.get("auto_wait", "1")) and not _is_number(_dlg_str(p.get("auto_wait", "1"))):
            rep.err(pw, f"auto_wait 는 초(숫자): '{p.get('auto_wait')}'")
        text = str(p.get("text", "") or "")
        rest = PAUSE_RE.sub("", text)
        if "{" in rest or "}" in rest:
            rep.err(pw, "알 수 없는 { } 표시 (대기는 {w=0.5} 꼴)")
        if not PAUSE_RE.sub("", text).strip():
            rep.warn(pw, "본문이 비어 있음")


def check_steps(w, steps, field_objs, rep):
    """연출 카드 단계 검사: 종류, 그림 파일, 숫자, 인물(player 또는 맵의 NPC object_id), 칸."""
    people = {o.get("object_id") for o in field_objs if o.get("type") == "npc"}
    if not steps:
        rep.warn(w, "연출 카드에 단계가 없음")
    for i, st in enumerate(steps):
        sw = f"{w} 연출 {i + 1}"
        if not isinstance(st, dict):
            rep.err(sw, "단계 형식이 아님")
            continue
        do = str(st.get("do", ""))
        if do not in DIRECT_STEPS:
            rep.err(sw, f"알 수 없는 연출 '{do}' (가능: {', '.join(sorted(DIRECT_STEPS))})")
            continue
        for k in ("fade", "time", "speed", "power", "volume"):
            if k in st and not (_is_number(st[k]) and float(st[k]) >= 0):
                rep.err(sw, f"{k} 는 0 이상 숫자: '{st[k]}'")
        if do == "image":
            f = str(st.get("file", ""))
            if not f:
                rep.err(sw, "그림 파일을 고르지 않음")
            elif not (CUTSCENE_DIR / f).exists():
                rep.err(sw, f"그림 파일이 없음: art/cutscenes/{f}")
        if do in AUDIO_DIRS:
            f = str(st.get("file", ""))
            folder = "sfx" if do == "sound" else "bgm"
            if not f:
                rep.err(sw, "소리 파일을 고르지 않음")
            elif not (AUDIO_DIRS[do] / f).exists():
                rep.err(sw, f"소리 파일이 없음: audio/{folder}/{f}")
        if do == "face" and str(st.get("dir", "down")) not in FACE_DIRS:
            rep.err(sw, f"바라보는 방향은 up / down / left / right: '{st.get('dir')}'")
        if do == "fade" and str(st.get("to", "black")) not in ("black", "white", "clear"):
            rep.err(sw, f"fade 의 to 는 black / white / clear: '{st.get('to')}'")
        if do in ("walk", "vanish", "face") or (do == "camera" and st.get("who")):
            who = str(st.get("who", ""))
            if do == "vanish" and who == "player":
                rep.err(sw, "플레이어는 숨길 수 없음")
            elif who != "player" and who not in people:
                rep.err(sw, f"인물(who)은 player 또는 맵의 NPC object_id: '{who}'")
        if do == "walk" or (do == "camera" and not st.get("who")):
            to = st.get("to")
            if not (isinstance(to, list) and len(to) == 2 and all(isinstance(v, (int, float)) and v >= 0 for v in to)):
                rep.err(sw, f"칸(to)은 [x, y]: '{to}'")


def _is_number(v):
    try:
        float(v)
        return True
    except (TypeError, ValueError):
        return False


def _is_pos_number(v):
    return _is_number(v) and float(v) > 0


def loc(sheet, r):
    """오류 위치: 엑셀 행이면 '시트 N행', 대화 파일이면 '대화 파일.json'"""
    return f"대화 {r['_row']}" if isinstance(r["_row"], str) else f"{sheet} {r['_row']}행"


def dialogue_files():
    """tools/dialogues/*.json 을 대화 에디터의 목록 순서(_order.json)대로 — 같은 시점의 자동 시작 컷신이 이 순서로 나온다.
    _ 로 시작하는 파일(_order.json 등)은 대화가 아님."""
    files = {f.stem: f for f in DIALOGUES_DIR.glob("*.json") if not f.name.startswith("_")}
    order = []
    op = DIALOGUES_DIR / "_order.json"
    if op.exists():
        try:
            order = [str(x) for x in json.loads(op.read_text(encoding="utf-8")) if str(x) in files]
        except (ValueError, OSError, TypeError):
            order = []
    return [files[n] for n in order] + [files[n] for n in sorted(files) if n not in order]


def read_dialogues(d, rep):
    """tools/dialogues/*.json (대화 에디터 파일) 의 노드·선택지를 엑셀 Nodes·Choices 뒤에 붙인다."""
    if not DIALOGUES_DIR.exists():
        return
    npc_ids = {r["npc_id"] for r in d.get("Npcs", [])}
    node_cols = SCHEMA["Nodes"][1] + OPTIONAL.get("Nodes", [])
    choice_cols = SCHEMA["Choices"][1] + OPTIONAL.get("Choices", [])
    for f in dialogue_files():
        try:
            dlg = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, OSError) as e:
            rep.err(f"대화 {f.name}", f"파일을 읽을 수 없음: {e}")
            continue
        episode = str(dlg.get("episode_id", "") or "")
        speed = _dlg_str(dlg.get("text_speed", ""))
        # NPC 단위 대화: 파일마다 npc_id (Npcs) 하나, 대화 시작 카드는 하나만
        npc = _dlg_str(dlg.get("npc_id", ""))
        if npc and npc not in npc_ids:
            rep.err(f"대화 {f.name}", f"없는 npc_id '{npc}' (npc.xlsx Npcs)")
        starts = [n.get("node_id") for n in dlg.get("nodes", []) if n.get("kind") == "start"]
        # 대화 에디터의 '게임 오프닝으로 쓰기' 체크 → 시작 카드(없으면 첫 카드)
        if dlg.get("opening") and dlg.get("nodes"):
            d.setdefault("_openings", []).append((f.name, starts[0] if starts else str(dlg["nodes"][0].get("node_id", ""))))
        if npc and not starts:
            rep.warn(f"대화 {f.name}", "NPC 대화에 대화 시작 카드가 없음")
        for n in dlg.get("nodes", []):
            rec = {c: _dlg_str(n.get(c, "")) for c in node_cols}
            rec["episode_id"] = episode
            rec["pages"] = n.get("pages") if isinstance(n.get("pages"), list) else []
            rec["routes"] = n.get("routes") if isinstance(n.get("routes"), list) else []
            rec["steps"] = n.get("steps") if isinstance(n.get("steps"), list) else []
            rec["trigger"] = n.get("trigger") if isinstance(n.get("trigger"), dict) else {}
            rec["text_speed"] = speed
            rec["npc_id"] = npc
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
        m["objects"] = [{k: _dlg_str(v) if k not in ("x", "y", "patrol_len", "from", "default", "once", "energy", "radius", "shadow", "enabled", "bb_overrides",
                                                                         "curtain", "solid", "w", "h", "top_rows", "wander_radius") else v for k, v in o.items()}
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


def arrive_from(o):
    f = o.get("from", [])
    return [s for s in (f if isinstance(f, list) else split_list(str(f))) if s]


def entrances_to(maps, mid):
    """mid 맵으로 들어오는 곳: {id: 설명} — 문·통로·이용 object_id, 가장자리 '맵:방향'"""
    out = {}
    for sm, m in maps.items():
        for o in m.get("objects", []):
            if o.get("type") in TRAVEL_TYPES and o.get("ref") == mid:
                out[o.get("object_id", "")] = o
        for d, e in (m.get("edges") or {}).items():
            if e and e.get("ref") == mid:
                out[f"{sm}:{d}"] = dict(e, type="edge")
    return out


def arrive_ids(m):
    return {o.get("object_id", "") for o in m.get("objects", []) if o.get("type") == "arrive"}


def map_has_default(m):
    """★ 기본 도착 P 가 있나 (예전 맵: 도착 P 물체가 하나도 없고 start 만 있으면 그게 기본)"""
    objs = m.get("objects", [])
    if any(o.get("type") == "arrive" and o.get("default") for o in objs):
        return True
    return not any(o.get("type") == "arrive" for o in objs) and bool(m.get("start"))


def travel_error(maps, ref, arrive):
    """맵 이동 대상 검사 (문·통로·이용·가장자리·move 효과). 맞으면 ''."""
    if ref not in maps:
        return f"이동할 맵이 없음: '{ref}'"
    if arrive and arrive not in arrive_ids(maps[ref]):
        return f"도착 지점 '{arrive}' 는 맵 {ref} 의 도착 지점(arrive)이 아님"
    return ""


def validate_graphics(d, maps, rep):
    """그래픽 시트와 맵의 그래픽(visual)·환경(environment)·광원(light 물체). 맵 그림이 틀려도 맵은 열리도록 대부분 경고."""
    tiles = {t["tile_key"]: t for t in d["Tiles"]}
    for t in d["Tiles"]:
        w = loc("Tiles", t)
        if t["layer"] not in TILE_LAYERS | OBJECT_ART_LAYERS:
            rep.err(w, f"layer 는 floor / detail / wall / roof / overhead (칠하기) 또는 door (문 그림) / marker (조사 반짝이) / window (창문) / camp (거점) / lamp (벽걸이등) / stairs (계단 물체): '{t['layer']}'")
        if t["layer"] == "window" and not t["tile_key"].endswith("_curtain") and t["tile_key"] + "_curtain" not in tiles:
            rep.warn(w, f"창문 '{t['tile_key']}' 의 커튼 그림 '{t['tile_key']}_curtain' 이 없음 (커튼을 쳐도 같은 그림)")
        if t["layer"] == "door" and not t["tile_key"].endswith("_open") and t["tile_key"] + "_open" not in tiles:
            rep.warn(w, f"문 '{t['tile_key']}' 의 열린 그림 '{t['tile_key']}_open' 이 없음 (열려도 같은 그림)")
        if t["frames"] is not None and t["frames"] < 1:
            rep.err(w, "frames 는 1 이상")
        if t.get("h") is not None and t["h"] < 1:
            rep.err(w, "h(그림 높이 칸)는 1 이상")
        if t["face"] and (t["face"] not in tiles or tiles[t["face"]]["layer"] != "wall" or t["layer"] != "wall"):
            rep.err(w, f"face 는 벽(wall) 타일의 앞면 = 있는 wall 타일: '{t['face']}'")
        if not (TILES_DIR / t["file"]).exists():
            rep.err(w, f"그림 파일이 없음: art/tiles/{t['file']}")
        if t["atlas_x"] < 0 or t["atlas_y"] < 0:
            rep.err(w, "atlas_x·atlas_y 는 0 이상")
    if d["Tiles"]:
        for need, layer in (("floor_default", "floor"), ("wall_default", "wall")):
            if need not in tiles:
                rep.err("Tiles", f"'{need}' 가 없음 (그래픽을 안 칠한 칸에 쓰임)")
            elif tiles[need]["layer"] != layer:
                rep.err("Tiles", f"'{need}' 의 layer 는 {layer}")
    presets = {r["preset_id"] for r in d["LightPresets"]}
    props = {r["prop_id"] for r in d["Props"]}
    for r in d["Props"]:
        w = loc("Props", r)
        if not (PROPS_DIR / r["file"]).exists():
            rep.err(w, f"그림 파일이 없음: art/props/{r['file']}")
        if r["foot_w"] < 1 or r["foot_h"] < 1:
            rep.err(w, "foot_w·foot_h 는 1 이상 (차지하는 칸)")
    for r in d["LightPresets"]:
        if r["shape"] not in LIGHT_SHAPES:
            rep.err(loc("LightPresets", r), f"shape 는 point / cone: '{r['shape']}'")
    for it in d["Items"]:
        if it["light"] and it["light"] not in presets:
            rep.err(loc("Items", it), f"light 에 없는 광원 프리셋 '{it['light']}' (graphics.xlsx LightPresets)")
    for r in d["LightPresets"]:
        w = loc("LightPresets", r)
        if not COLOR_RE.match(r["color"]):
            rep.err(w, f"color 는 #RRGGBB: '{r['color']}'")
        if r["energy"] is not None and r["energy"] < 0 or r["radius"] is not None and r["radius"] <= 0:
            rep.err(w, "energy 는 0 이상, radius 는 0보다 커야 함")
    profiles = {}
    for r in d["DayNight"]:
        w = loc("DayNight", r)
        profiles.setdefault(r["profile_id"], []).append(r)
        if r["hour"] is not None and not 0 <= r["hour"] <= 24:
            rep.err(w, "hour 는 0 ~ 24")
        for col in ("ambient", "sun_color"):
            if r[col] and not COLOR_RE.match(r[col]):
                rep.err(w, f"{col} 는 #RRGGBB: '{r[col]}'")
    if d["DayNight"] and "outdoor" not in profiles:
        rep.err("DayNight", "'outdoor' 프로필이 없음 (환경을 안 고른 맵의 기본)")
    d["_profiles"] = profiles
    for mid, m in maps.items():
        wm = f"맵 {m['file']}"
        env = (m.get("environment") or {}).get("profile", "")
        if env and profiles and env not in profiles:
            rep.warn(wm, f"없는 환경 프로필 '{env}' (graphics.xlsx DayNight) — outdoor 로 보임")
        layers = (m.get("visual") or {}).get("layers") or {}
        h = len(m["tiles"])
        wdt = max((len(r) for r in m["tiles"]), default=0)
        for layer, cells in layers.items():
            if layer not in TILE_LAYERS or not isinstance(cells, dict):
                rep.warn(wm, f"알 수 없는 그래픽 층 '{layer}'")
                continue
            bad = sorted({k for k in cells.values() if k not in tiles})
            wrong = sorted({k for k in cells.values() if k in tiles and tiles[k]["layer"] != layer})
            if layer == "overhead":   # 전경 가림: 없는 타일·다른 층 타일은 오류 (기획 §6.2 — 안 보이는 가림막이 생기지 않게)
                if bad and tiles:
                    rep.err(wm, f"전경 가림 층에 없는 타일 {', '.join(bad)}")
                if wrong:
                    rep.err(wm, f"전경 가림 층에 다른 층 타일 {', '.join(wrong)} (graphics.xlsx Tiles layer=overhead 만)")
                bad, wrong = [], []
            if bad and tiles:
                rep.warn(wm, f"그래픽 '{layer}' 층에 없는 타일 {', '.join(bad)} (기본 타일로 보임)")
            if wrong:
                rep.warn(wm, f"그래픽 '{layer}' 층에 다른 층 타일 {', '.join(wrong)}")
            if layer == "wall":   # 벽 그림이 칠해진 바닥 칸 = 벽처럼 보이는데 지나가짐 (맵 에디터 '칠한 그림대로 벽·바닥 맞추기')
                at_obj = {f"{int(o.get('x', -1))},{int(o.get('y', -1))}" for o in m.get("objects", [])}   # 문 칸 등 물체 칸은 빼고
                walk = [c for c in cells if _cell_in(c, wdt, h) and c not in at_obj
                        and m["tiles"][int(c.split(",")[1])][int(c.split(",")[0]):int(c.split(",")[0]) + 1] == "."]
                if walk:
                    rep.warn(wm, f"벽 그림이 칠해진 바닥 칸 {len(walk)}개 (예: {walk[0]}) — 벽처럼 보이지만 지나갈 수 있음. 맵 에디터 편집 ▾ › 칠한 그림대로 벽·바닥 맞추기")
            out = [c for c in cells if not _cell_in(c, wdt, h)]
            if out:
                rep.warn(wm, f"그래픽 '{layer}' 층에 맵 밖 칸 {len(out)}개 (무시됨)")
        for o in m["objects"]:
            if o.get("type") == "prop":
                if props and o.get("ref", "") not in props:
                    rep.warn(f"{wm} 오브젝트 {o.get('object_id', '')}", f"없는 오브젝트 그림 '{o.get('ref', '')}' (graphics.xlsx Props)")
                continue
            if o.get("type") != "light":
                continue
            w = f"{wm} 광원 {o.get('object_id', '')}"
            if o.get("preset") and presets and o["preset"] not in presets:
                rep.warn(w, f"없는 광원 프리셋 '{o['preset']}' (값은 광원에 저장된 것 사용)")
            if o.get("color") and not COLOR_RE.match(str(o["color"])):
                rep.err(w, f"color 는 #RRGGBB: '{o['color']}'")
            for k in LIGHT_NUMS:
                if k in o and not (_is_number(o[k]) and float(o[k]) >= 0):
                    rep.err(w, f"{k} 는 0 이상 숫자: '{o[k]}'")


def _cell_in(key, w, h):
    try:
        x, y = (int(v) for v in str(key).split(","))
    except ValueError:
        return False
    return 0 <= x < w and 0 <= y < h


def validate_field(d, maps, rep, enemies):
    spots = {r["spot_id"] for r in d["Loot"] if r["spot_id"]}
    items = {r["item_id"] for r in d["Items"]}
    basecamp = next((str(r["value"]) for r in d["Config"] if r["key"] == "basecamp_map"), "")
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
                rep.err(wm, f"{y + 1}행에 알 수 없는 칸 {sorted(bad)} (# 벽 / . 바닥 / 공백 빈 공간)")

        def floor(x, y):
            return 0 <= y < len(tiles) and 0 <= x < len(tiles[y]) and tiles[y][x] == "."

        # 도착 P 는 모두 arrive 물체. ★ 기본(default) P 는 베이스캠프만 필수, 다른 맵은 선택.
        # start (게임이 '기본 자리'로 읽음) = 기본 P → 없으면 첫 도착 P → 없으면 회차 시작 S (예전 맵의 start 도 읽음)
        arrives = [o for o in m["objects"] if o.get("type") == "arrive"]
        defaults = [o for o in arrives if o.get("default")]
        has_default = map_has_default(m)
        if len(defaults) > 1:
            rep.err(wm, f"기본 도착 P 가 {len(defaults)}개 — 하나만 ({', '.join(o.get('object_id', '') for o in defaults)})")
        respawns = [o for o in m["objects"] if o.get("type") == "respawn"]   # 부활 R: 베이스캠프에서 부활·불러오기 때 깨어나는 자리
        if len(respawns) > 1:
            rep.err(wm, f"부활 R 이 {len(respawns)}개 — 하나만")
        if respawns and mid != basecamp:
            rep.warn(wm, f"부활 R 은 베이스캠프 맵({basecamp})에서만 쓰임")
        if mid == basecamp and not respawns:
            rep.warn(wm, "베이스캠프에 부활 R 이 없음 — 부활·불러오기 때 첫 도착 P 에서 깨어남")
        if defaults:
            m["start"] = [int(defaults[0]["x"]), int(defaults[0]["y"])]
        elif arrives:
            m["start"] = [int(arrives[0]["x"]), int(arrives[0]["y"])]
        elif not m.get("start"):
            if m.get("run_start"):
                m["start"] = m["run_start"]
            else:   # P 없는 맵 (이어지는 가장자리로만 들어옴): 못 들어갈 때를 위해 첫 바닥 칸을 기본 자리로
                first = next(([x, y] for y, r in enumerate(m["tiles"]) for x, c in enumerate(r) if c == "."), None)
                if first is None:
                    rep.err(wm, "바닥 칸이 하나도 없음")
                else:
                    m["start"] = first
                    if not any((e or {}).get("seamless") for e in entrances_to(maps, mid).values()):
                        rep.warn(wm, f"도착 P 가 없음 — 이 맵으로 들어오면 첫 바닥 칸 {first} 에 섬 (P 를 두거나 이어지는 가장자리로)")
        for key, label in (("start", "도착 P"), ("run_start", "회차 시작 S")):
            pos = m.get(key)
            if pos is None:
                continue
            if not (isinstance(pos, list) and len(pos) == 2 and floor(int(pos[0]), int(pos[1]))):
                rep.err(wm, f"{label} 위치가 바닥이 아님: {pos}")
        for edir, e in (m.get("edges") or {}).items():
            if edir not in EDGE_DIRS:
                rep.err(wm, f"가장자리 방향은 up/down/left/right: '{edir}'")
            elif e and e.get("ref"):
                err = travel_error(maps, e["ref"], e.get("arrive", ""))
                if err:
                    rep.err(f"{wm} 가장자리 {edir}", err)
                elif e.get("seamless"):
                    if e.get("arrive"):
                        rep.warn(f"{wm} 가장자리 {edir}", "이어지는 맵이면 도착 P(arrive)는 쓰지 않음 (들어갈 자리가 없을 때만)")
                    dt = maps[e["ref"]]["tiles"]
                    rows = {"down": dt[:9], "up": dt[-9:]}.get(edir)
                    cols = {"right": [r[:9] for r in dt], "left": [r[-9:] for r in dt]}.get(edir)
                    if not any("." in r for r in (rows if rows is not None else cols)):
                        rep.warn(f"{wm} 가장자리 {edir}", f"이어지는 맵 {e['ref']} 의 반대쪽 가장자리(9칸 안)에 바닥이 없음 — 도착 P 로 감")
        # 도착 P 의 '이어지는 곳': 이 맵으로 들어오는 곳이어야 하고, 한 곳은 한 도착 P 에만
        ents = entrances_to(maps, mid)
        claimed = {}
        for o in m["objects"]:
            if o.get("type") != "arrive":
                if arrive_from(o):
                    rep.err(f"{wm} 물체 {o.get('object_id', '')}", "이어지는 곳(from)은 도착 P(arrive)에만")
                continue
            for src in arrive_from(o):
                w = f"{wm} 도착 P {o.get('object_id', '')}"
                if src not in ents:
                    rep.err(w, f"이어지는 곳 '{src}' 는 이 맵({mid})으로 들어오는 문·통로·이용·가장자리가 아님")
                elif src in claimed:
                    rep.err(w, f"'{src}' 는 이미 도착 P {claimed[src]} 에 이어져 있음 (한 곳은 한 도착 P 에만)")
                else:
                    claimed[src] = o.get("object_id", "")
                    other = ents[src].get("arrive", "")
                    if other and other != o.get("object_id", ""):
                        rep.err(w, f"'{src}' 는 출발 쪽에서 도착 지점 '{other}' 를 따로 골랐음 (한쪽에서만 정할 것)")
        # 기본 P 는 어느 맵에도 필요 없음 (2026-10-18): 이어진 P 가 없는 입구로 들어오면 기본 P → 없으면 첫 P (start)
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
            if o.get("type") == "event":   # 이벤트 영역: 놓은 칸 = 왼쪽 위, w × h 칸이 맵 안 (안에 다른 물체가 있어도 됨)
                ew, eh = int(o.get("w", 1) or 1), int(o.get("h", 1) or 1)
                if ew < 1 or eh < 1:
                    rep.err(w, f"이벤트 크기 w·h 는 1 이상: {ew}×{eh}")
                elif x + ew > width or y + eh > len(tiles):
                    rep.err(w, f"이벤트 영역 {ew}×{eh} 가 맵 밖으로 나감")
            if o.get("type") == "furniture":   # 기타 가구: 놓은 칸 = 왼쪽 위, w × h 칸이 모두 바닥이고 비어 있어야
                fw, fh = int(o.get("w", 1) or 1), int(o.get("h", 1) or 1)
                if fw < 1 or fh < 1:
                    rep.err(w, f"가구 크기 w·h 는 1 이상: {fw}×{fh}")
                for cy in range(y, y + max(fh, 1)):
                    for cx in range(x, x + max(fw, 1)):
                        if (cx, cy) != (x, y) and not floor(cx, cy):
                            rep.err(w, f"가구가 차지하는 칸 ({cx}, {cy}) 가 바닥이 아님")
                        elif (cx, cy) != (x, y) and (cx, cy) in occupied:
                            rep.err(w, f"가구가 차지하는 칸 ({cx}, {cy}) 에 이미 {occupied[(cx, cy)]} 가 있음")
                        else:
                            occupied[(cx, cy)] = oid
                if not 0 <= int(o.get("top_rows", 0) or 0) < max(fh, 1):
                    rep.err(w, f"가구 top_rows(뒤로 지나가는 윗줄)는 0 ~ 높이-1: {o.get('top_rows')}")
                role = o.get("role", "")
                if role not in FURNITURE_ROLES:
                    rep.err(w, f"가구 역할(role)은 비움(장식) / investigate / pickup / use / talk: '{role}'")
                elif role == "investigate" and o.get("ref") and o["ref"] not in spots:
                    rep.err(w, f"조사 가구의 ref 는 Loot 의 spot_id (없으면 비움): '{o['ref']}'")
                elif role == "talk" and (o.get("ref") not in nodes or nodes[o["ref"]]["episode_id"] != ""):
                    rep.err(w, f"대화 가구의 ref 는 필드 대화 노드: '{o.get('ref')}'")
                elif role in ("pickup", "use") and not o.get("effects"):
                    rep.warn(w, f"{'줍기' if role == 'pickup' else '사용'} 가구에 효과(effects)가 없음")
                if o.get("color") and not COLOR_RE.match(str(o["color"])):
                    rep.err(w, f"가구 색(color)은 #RRGGBB: '{o['color']}'")
                if o.get("effects"):
                    try:
                        for kind, rid in parse_effects(o["effects"]):
                            if kind == "item" and rid not in items:
                                rep.err(w, f"가구 효과의 없는 아이템 '{rid}'")
                    except ExprError as e:
                        rep.err(w, f"가구 효과(effects) 문법 오류: {e}")
                if o.get("use_condition"):
                    try:
                        parse_condition(o["use_condition"])
                    except ExprError as e:
                        rep.err(w, f"가구 사용 조건 문법 오류: {e}")
            if o.get("type") == "window":   # 창문: w × h 칸이 모두 벽, 옆에 바닥이 있거나 뒷벽(아래로 벽만 이어지다 바닥)
                ww, wh = max(1, int(o.get("w", 1) or 1)), max(1, int(o.get("h", 1) or 1))
                wall = lambda cx, cy: 0 <= cy < len(m["tiles"]) and 0 <= cx < len(m["tiles"][cy]) and m["tiles"][cy][cx] == "#"
                bad = [(cx, cy) for cy in range(y, y + wh) for cx in range(x, x + ww) if not wall(cx, cy)]
                if bad:
                    rep.err(w, f"창문 칸 {bad[0]} 가 벽이 아님")
                elif not window_reaches_floor(floor, wall, x, y, ww, wh):
                    rep.err(w, f"창문 ({x}, {y}) 옆에 바닥이 없고 뒷벽도 아님 (빛이 들어갈 곳)")
                if o.get("inside") and o["inside"] not in maps:
                    rep.err(w, f"창문의 안쪽 맵(inside)이 없는 맵: '{o['inside']}'")
                for cy in range(y, y + wh):
                    for cx in range(x, x + ww):
                        if (cx, cy) != (x, y):
                            if (cx, cy) in occupied:
                                rep.err(w, f"창문 칸 ({cx}, {cy}) 에 이미 {occupied[(cx, cy)]} 가 있음")
                            occupied[(cx, cy)] = oid
            elif o.get("type") == "light" and 0 <= y < len(m["tiles"]) and 0 <= x < len(m["tiles"][y]) and m["tiles"][y][x] == "#":
                wall1 = lambda cx, cy: 0 <= cy < len(m["tiles"]) and 0 <= cx < len(m["tiles"][cy]) and m["tiles"][cy][cx] == "#"
                if not window_reaches_floor(floor, wall1, x, y, 1, 1):   # 벽걸이등: 옆이나 아래(뒷벽)에 비출 바닥이 있어야
                    rep.err(w, f"벽에 건 광원 ({x}, {y}) 옆에 바닥이 없고 뒷벽도 아님 (빛이 나갈 곳)")
                elif (x, y) in occupied and occupied[(x, y)] != oid:
                    rep.err(w, f"위치 ({x}, {y}) 에 이미 {occupied[(x, y)]} 가 있음")
            elif not floor(x, y):
                rep.err(w, f"위치 ({x}, {y}) 가 바닥이 아님")
            elif (x, y) in occupied and occupied[(x, y)] != oid:
                rep.err(w, f"위치 ({x}, {y}) 에 이미 {occupied[(x, y)]} 가 있음")
            occupied[(x, y)] = oid
            t = o.get("type", "")
            ref = o.get("ref", "")
            if t not in FIELD_TYPES:
                rep.err(w, f"type 은 {' / '.join(sorted(FIELD_TYPES))}: '{t}'")
            elif t == "enemy" and ref not in enemies:
                rep.err(w, f"적 종류(ref)는 싸울 수 있는 NPC(NpcParts·NpcAttacks 가 있는 npc_id): '{ref}'")
            elif t == "enemy" and o.get("follow", "") not in ("", "off"):
                rep.err(w, f"follow(다른 맵까지 따라오기)는 비움(켬) / off: '{o.get('follow')}'")
            elif t == "enemy" and o.get("touch_battle", "") not in ("", "on", "off"):
                rep.err(w, f"touch_battle(닿으면 바로 전투)는 비움 / on / off: '{o.get('touch_battle')}'")
            elif t == "enemy" and (o.get("bt") or o.get("bb_overrides")) and check_enemy_bt(o, d.get("_ai", {}), w, rep):
                pass
            elif t == "enemy" and any(n["npc_id"] == ref and n["kind"] != "monster" for n in d["Npcs"]):
                rep.warn(w, f"맵의 적 '{ref}' 가 몬스터(Npcs kind=monster)가 아님 — 마주치면 바로 전투")
            elif t == "enemy" and not all(n["walk_speed"] > 0 and n["run_speed"] > 0
                                          for n in d["Npcs"] if n["npc_id"] == ref):
                rep.err(w, f"맵의 적 '{ref}' 는 Npcs 의 walk_speed(순찰)·run_speed(추격)가 0보다 커야 함")
            elif t == "npc" and o.get("wander", "") not in ("", "radius", "route"):
                rep.err(w, f"NPC 움직임(wander)은 비움(제자리) / radius / route: '{o.get('wander')}'")
            elif t == "npc" and o.get("wander") == "radius" and int(o.get("wander_radius", 3) or 0) < 1:
                rep.err(w, "돌아다니는 반경(wander_radius)은 1칸 이상")
            elif t == "npc" and o.get("wander") == "route" and route_error(o.get("route", ""), floor):
                rep.err(w, route_error(o.get("route", ""), floor))
            elif t == "npc" and o.get("face", "") not in ("",) + tuple(FACE_DIRS):
                rep.err(w, f"NPC 의 바라보는 방향(face)은 up / down / left / right: '{o.get('face')}'")
            elif t in ("npc", "event") and (ref not in nodes or nodes[ref]["episode_id"] != ""):
                rep.err(w, f"{'NPC' if t == 'npc' else '이벤트 칸'} 의 대화(ref)는 필드 대화 노드: '{ref}'")
            elif t in TRAVEL_TYPES and travel_error(maps, ref, o.get("arrive", "")):
                rep.err(w, travel_error(maps, ref, o.get("arrive", "")))
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


def parse_route(text):
    """'5,6; 9,6; 9,10' → [[5, 6], [9, 6], [9, 10]] (형식 오류면 None)"""
    if isinstance(text, list):
        return text
    pts = []
    for part in str(text or "").replace(chr(10), ";").split(";"):
        part = part.strip()
        if not part:
            continue
        xy = [v.strip() for v in part.split(",")]
        if len(xy) != 2 or not all(v.lstrip("-").isdigit() for v in xy):
            return None
        pts.append([int(xy[0]), int(xy[1])])
    return pts


def route_error(text, floor):
    pts = parse_route(text)
    if pts is None:
        return f"길(route)은 'x,y; x,y; ...' (칸 좌표): '{text}'"
    if len(pts) < 2:
        return "정해진 길은 칸 2개 이상"
    bad = [p for p in pts if not floor(p[0], p[1])]
    if bad:
        return f"길의 칸 {bad[0]} 이 바닥이 아님"
    return ""


def schedule_minutes(sched):
    """[[시작분, 끝분], ...] → 그 시간대의 분 집합 (비면 하루 종일)"""
    if not sched:
        return set(range(1440))
    out = set()
    for a, b in sched:
        out.update(range(a, b) if a < b else list(range(a, 1440)) + list(range(0, b)))
    return out


def warn_npc_overlap(maps, rep):
    """같은 대화(ref)를 쓰는 NPC 가 같은 조건·겹치는 시간대에 두 곳 이상 → 경고 (고양이처럼 하나뿐인 NPC 가 동시에 둘)"""
    by_ref = {}
    for mid, m in maps.items():
        for o in m.get("objects", []):
            if o.get("type") == "npc" and o.get("ref"):
                rngs = [parse_time_range(r) for r in split_list(o.get("schedule", ""))]
                if any(r is None for r in rngs):
                    continue
                by_ref.setdefault(o["ref"], []).append((mid, o, schedule_minutes(rngs)))
    for ref, items in by_ref.items():
        for i in range(len(items)):
            for j in range(i + 1, len(items)):
                (ma, a, sa), (mb, b, sb) = items[i], items[j]
                if (a.get("condition") or "") != (b.get("condition") or ""):
                    continue   # 조건이 다르면 동시에 안 나올 수 있음
                both = sa & sb
                if both:
                    t = min(both)
                    rep.warn(f"맵 {ma} 물체 {a.get('object_id')}",
                             f"같은 대화 '{ref}' 의 NPC 가 {mb} 의 {b.get('object_id')} 와 같은 시간({t // 60:02d}:{t % 60:02d} 등)에 함께 나옴 — 시간대가 겹치지 않게")


WINDOW_SCAN = 12   # core/visual_data.gd 와 같게


def window_reaches_floor(floor, wall, x, y, w, h):
    """창문 빛이 들어갈 바닥: 사각형 바로 옆(상하좌우), 없으면 뒷벽 — 가운데 열 아래로 벽만 이어지다 바닥 (VisualData.window_light 와 같은 규칙)"""
    if any(floor(cx, y + h) or floor(cx, y - 1) for cx in range(x, x + w)):
        return True
    if any(floor(x - 1, cy) or floor(x + w, cy) for cy in range(y, y + h)):
        return True
    cx = x + w // 2
    for cy in range(y + h, y + h + WINDOW_SCAN):
        if floor(cx, cy):
            return True
        if not wall(cx, cy):
            return False
    return False


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


def read_ai(rep):
    """tools/ai/*.json → {id: 자산}. 트리 규칙 검사는 Godot 몬스터 AI 탭의 Compile 이 한다 (여기선 읽기·맵 참조만)."""
    out = {}
    if not AI_DIR.exists():
        return out
    for f in sorted(AI_DIR.glob("*.json")):
        if f.name.startswith("_"):
            continue
        try:
            a = json.loads(f.read_text(encoding="utf-8"))
        except (ValueError, OSError) as e:
            rep.err(f"AI {f.name}", f"JSON 을 읽을 수 없음: {e}")
            continue
        if not isinstance(a, dict) or not a.get("id"):
            rep.err(f"AI {f.name}", "id 가 없음")
            continue
        out[a["id"]] = a
    return out


def check_enemy_bt(o, ai, w, rep):
    """맵의 적 물체 bt(BT_ 자산)·bb_overrides(개체별 Blackboard 시작값) 검사"""
    bt_id = o.get("bt", "")
    over = o.get("bb_overrides") or {}
    if not bt_id:
        if over:
            rep.err(w, "bb_overrides 는 bt 를 정한 적만")
        return
    bt = ai.get(bt_id)
    if not bt or bt.get("asset_type") != "behavior_tree":
        rep.err(w, f"bt 는 tools/ai 의 Behavior Tree (BT_): '{bt_id}'")
        return
    bb = ai.get(bt.get("blackboard_id", ""), {})
    keys = {k.get("name"): k for k in bb.get("keys", [])}
    if not isinstance(over, dict):
        rep.err(w, "bb_overrides 는 {키: 값}")
        return
    for k in over:
        if k not in keys:
            rep.err(w, f"bb_overrides 의 키 '{k}' 가 {bt.get('blackboard_id')} 에 없음")
        elif not keys[k].get("instance_override"):
            rep.err(w, f"bb_overrides 의 키 '{k}' 는 개체별 override 가 꺼져 있음 (Blackboard 탭에서 켜기)")


def export_maps(d, maps):
    out = []
    for mid, m in maps.items():
        width = max(len(r) for r in m["tiles"])
        tiles = [r.ljust(width, " ") for r in m["tiles"]]   # 짧은 줄의 나머지는 빈 공간
        objects = []
        for o in m["objects"]:
            e = {k: o.get(k, "") for k in ("object_id", "type", "ref", "name", "text", "condition", "arrive", "face", "look", "dir")}   # dir = 계단 up/down   # look = 문 그림 (Tiles layer=door)
            e["from"] = arrive_from(o)   # 도착 P: 이어지는 곳 (object_id / "맵:방향")
            e["default"] = bool(o.get("default"))   # 기본 도착 P
            e["once"] = bool(o.get("once"))         # 이벤트 칸: 한 번만
            if o.get("type") == "event":            # 이벤트: 밟는 영역 (놓은 칸 = 왼쪽 위)
                e.update(w=max(1, int(o.get("w", 1) or 1)), h=max(1, int(o.get("h", 1) or 1)))
            if o.get("type") == "enemy":            # 몬스터 AI: Behavior Tree 와 개체별 Blackboard 시작값 (비우면 예전 AI)
                e.update(bt=o.get("bt", ""), bb_overrides=o.get("bb_overrides") or {},
                         touch_battle=o.get("touch_battle", ""), follow=o.get("follow", ""))   # follow off = 다른 맵까지 안 따라옴   # 닿으면 바로 전투: "" = BT 설정(없으면 켬) / on / off
            if o.get("type") == "furniture":        # 기타 가구 (흰 사각형): 크기·표시 메모·색·막힘·사용 조건·역할
                e.update(w=max(1, int(o.get("w", 1) or 1)), h=max(1, int(o.get("h", 1) or 1)), label=o.get("label", ""),
                         color=o.get("color", "") or "#FFFFFF", solid=o.get("solid", True) is not False,
                         use_condition=o.get("use_condition", ""), use_fail_text=o.get("use_fail_text", ""),
                         role=o.get("role", ""), effects=o.get("effects", ""),
                         top_rows=max(0, int(o.get("top_rows", 0) or 0)))   # 위쪽 몇 줄은 뒤로 지나감
            if o.get("type") == "npc":              # 돌아다니기: radius (놓은 자리 둘레) / route (정해진 칸들 차례로)
                e.update(wander=o.get("wander", ""), wander_radius=int(o.get("wander_radius", 3) or 3),
                         route=parse_route(o.get("route", "")) or [])
            if o.get("type") == "window":           # 창문: 처음에 커튼을 쳐 두었나, 크기
                e.update(curtain=bool(o.get("curtain")), w=max(1, int(o.get("w", 1) or 1)), h=max(1, int(o.get("h", 1) or 1)),
                         inside=o.get("inside", ""))   # 바깥 창문의 안쪽 맵 (비우면 가장 가까운 문의 맵) — 그 맵에 켜진 광원이 있으면 불 켜진 창
            if o.get("type") == "light":            # 광원: 놓을 때 프리셋에서 복사한 값 (광원마다 고칠 수 있음)
                e.update(preset=o.get("preset", ""), color=o.get("color", "") or "#FFFFFF",
                         energy=float(o.get("energy", 1.0)), radius=float(o.get("radius", 4.0)),
                         shadow=bool(o.get("shadow", True)), enabled=bool(o.get("enabled", True)))
            e.update(map_id=mid, x=int(o["x"]), y=int(o["y"]), patrol_dir=o.get("patrol_dir", ""),
                     patrol_len=int(o.get("patrol_len", 0) or 0),
                     schedule=[parse_time_range(r) for r in split_list(o.get("schedule", ""))])
            objects.append(e)
        start = m.get("start") or [0, 0]
        # seamless = 이어지는 맵 (도착 P 대신 반대쪽 가장자리의 같은 자리로), offset = 가장자리를 따라 어긋난 칸 수
        edges = {k: {"ref": v.get("ref", ""), "arrive": v.get("arrive", ""), "seamless": bool(v.get("seamless")),
                     "offset": int(v.get("offset", 0) or 0)}
                 for k, v in (m.get("edges") or {}).items() if v and v.get("ref")}
        out.append({"map_id": mid, "width": width, "height": len(tiles), "tiles": tiles, "start": start,
                    "run_start": m.get("run_start") or start, "objects": objects, "edges": edges,
                    "visual": {"layers": {k: v for k, v in ((m.get("visual") or {}).get("layers") or {}).items() if k in TILE_LAYERS},
                               # 칠하지 않은 칸의 그림 (맵마다, 비우면 floor_default / wall_default)
                               "default_floor": (m.get("visual") or {}).get("default_floor", ""),
                               "default_wall": (m.get("visual") or {}).get("default_wall", "")},
                    "environment": {"profile": (m.get("environment") or {}).get("profile", "") or "outdoor"}})
    return out


# ---------------------------------------------------------------- 출력
def export(d, maps):
    def clean(rows):
        return [{k: v for k, v in r.items() if k != "_row"} for r in rows]

    def character(r, id_col, is_player):
        return {"char_id": r[id_col], "name": r["name"], "name_color": r["name_color"], "traits": split_list(r["traits"]),
                "abilities": {a: r[a] for a in ABILITY_COLS}, "walk_speed": r["walk_speed"], "run_speed": r["run_speed"],
                "is_player": is_player, "kind": "player" if is_player else (r["kind"] or "npc")}

    def bonuses(text):
        return [{"ability": m.group(1), "value": int(m.group(2))}
                for m in (BONUS_RE.match(b) for b in split_list(text))]

    def choice(r):
        return dict(r, type=r["type"] or "normal", dc=int(r["dc"]) if r["dc"] else 0,
                    mod=int(r["mod"]) if r["mod"] else 0)

    out = {
        "episodes": clean(d["Episodes"]),
        "nodes": [dict(n, pages=n.get("pages") or [], routes=[{"condition": _dlg_str(r.get("condition", "")), "next_node": _dlg_str(r.get("next_node", ""))}
                                                         for r in (n.get("routes") or []) if isinstance(r, dict)],
                       text_speed=n.get("text_speed", ""), npc_id=n.get("npc_id", ""), steps=n.get("steps") or [],
                       trigger={"when": str(n["trigger"].get("when", "")), "map": str(n["trigger"].get("map", "")),
                                "once": bool(n["trigger"].get("once", False))} if n.get("trigger") else {})
                  for n in clean(d["Nodes"])],
        "choices": [choice(r) for r in clean(d["Choices"])],
        "items": [dict(r, dice_bonus=bonuses(r["dice_bonus"])) for r in clean(d["Items"])],
        "loot": clean(d["Loot"]),
        # 대화 화자·주인공 능력치: 플레이어 + NPC (char_id = player_id / npc_id)
        "characters": [character(r, "player_id", True) for r in clean(d["Player"])]
                      + [character(r, "npc_id", False) for r in clean(d["Npcs"])],
        "abilities": clean(d["Abilities"]),
        "equip_slots": clean(d["EquipSlots"]),
        "status_effects": [dict(r, scope=r["scope"] or "whole", tick_amount=float(r["tick_amount"]) if r["tick_amount"] else None)
                           for r in clean(d["StatusEffects"])],
        # 그래픽: 타일(tile_key → 그림·칸), 광원 프리셋, 시간대 환경광 {profile: [[시, 환경색, 햇빛색, 햇빛 세기], ...]}
        "graphics": {
            "tiles": [dict(t, casts_shadow=is_true(t["casts_shadow"])) for t in clean(d["Tiles"])],
            "light_presets": [dict(r, shadow=is_true(r["shadow"]) if r["shadow"] else True, shape=r["shape"] or "point")
                              for r in clean(d["LightPresets"])],
            "props": [dict(r, solid=is_true(r["solid"]), casts_shadow=is_true(r["casts_shadow"])) for r in clean(d["Props"])],
            "day_night": {pid: [[r["hour"], r["ambient"], r["sun_color"] or "#000000", r["sun_energy"] or 0.0]
                                for r in sorted(rows, key=lambda r: r["hour"])]
                          for pid, rows in d.get("_profiles", {}).items()},
            "tile_art_px": int(next((r["value"] for r in d["Config"] if r["key"] == "tile_art_px"), 16) or 16),
            # 창문 햇빛 (Config — 에디터 렌더러도 읽게 여기 같이)
            "window_light_energy": float(next((r["value"] for r in d["Config"] if r["key"] == "window_light_energy"), 1.2) or 0),
            "window_light_radius": float(next((r["value"] for r in d["Config"] if r["key"] == "window_light_radius"), 6) or 6),
        },
        "traits": [dict(r, conflicts=split_list(r["conflicts"]), selectable=is_true(r["selectable"]) if r["selectable"] else True)
                   for r in clean(d["Traits"])],
        "player_parts": [dict(r, key=r["key"].upper(), vital=is_true(r["vital"])) for r in clean(d["PlayerParts"])],
        # 싸울 수 있는 NPC (부위·공격이 있는 것). enemy_id = npc_id
        "enemies": [{"enemy_id": e["npc_id"], "name": e["name"], "image": e["image"], "kind": e["kind"] or "npc",
                     "flee_chance": float(e["flee_chance"]) if e["flee_chance"] else None,
                     "walk_speed": e["walk_speed"], "run_speed": e["run_speed"], "battle_bt": e["battle_bt"],
                     "abilities": {a: e[a] for a in ABILITY_COLS},
                     "parts": [dict(p, vital=is_true(p["vital"])) for p in clean(d["NpcParts"])
                               if p["npc_id"] == e["npc_id"]],
                     "attacks": [dict(a, strikes=parse_strikes(a["pattern"], a["targets"]))
                                 for a in clean(d["NpcAttacks"]) if a["npc_id"] == e["npc_id"]]}
                    for e in clean(d["Npcs"]) if e["npc_id"] in d["_enemy_ids"]],
        "maps": export_maps(d, maps),
        "survival": clean(d["Survival"]),
        "camp_actions": clean(d["CampActions"]),
        "revivals": clean(d["Revivals"]),
        "ai": {"schema_version": 2, "assets": [d.get("_ai", {})[k] for k in sorted(d.get("_ai", {}))]},
        "death_causes": clean(d["DeathCauses"]),
        "endings": [dict(r, world_flags_set=split_list(r["world_flags_set"])) for r in clean(d["Endings"])],
        "config": dict({r["key"]: config_value(r["value"]) for r in d["Config"]}, opening_dialogue=d.get("_opening", "")),
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
        target = Path(args[0]) if args else SHEETS_DIR
        return _run(target.parent if target.suffix == ".xlsx" else target, say)
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
    except PermissionError as e:
        say(f"파일을 열 수 없음(엑셀에서 열려 있나요?): {e.filename or path}")
        return 1
    read_dialogues(data, rep)
    maps = read_maps(rep)
    data["_maps"] = maps
    data["_ai"] = read_ai(rep)
    data["FieldObjects"] = field_objects(maps)
    validate(data, rep)
    validate_field(data, maps, rep, data.get("_enemy_ids", set()))
    warn_npc_overlap(maps, rep)
    validate_graphics(data, maps, rep)
    if rep.errors:
        say(f"오류 {len(rep.errors)}개 — JSON을 쓰지 않았습니다.")
        for e in rep.errors:
            say("  " + e)
        _say_warnings(rep, say)
        return 1
    out = export(data, maps)
    say("변환 완료 → " + str(OUT_DIR))
    for k, v in out.items():
        say(f"  {k}.json: {len(v)}개")
    _say_warnings(rep, say)
    return 0


def _say_warnings(rep, say):
    if rep.warnings:
        say(f"경고 {len(rep.warnings)}개 (변환은 됨):")
        for w in rep.warnings:
            say("  경고 " + w)


if __name__ == "__main__":
    sys.exit(main())
