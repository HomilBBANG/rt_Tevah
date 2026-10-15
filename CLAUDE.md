# 테바 — 생존 호러 RPG (Godot 4.7)

## 현재 방향 (2026-10-13 변경)
- 기획서: `docs/survival_horror_rpg_tevah_v0.3.md` 가 기준 (v0.2 이후 확정 결정·구현 반영, [확정]/[임시]/[미정] 표기). 숫자·규칙이 기획서에 없으면 임의로 정하지 말고 데이터(엑셀)로 조정 가능하게 두고 TODO 로 남긴다.
- **텍스트 어드벤처 → 탑뷰 모험으로 전환.** 아래 1단계에서 만든 엑셀 기반 노드·선택지·대화 시스템은 **스토리 전개와 인물 간 대화**에 그대로 쓴다 (대화 중 선택지 포함).
- **주사위(d20)는 대화 선택지에서만** 쓴다. 전투 회피는 플레이어 숙련(방향+타이밍 입력)으로 판정한다.
- **기준 해상도 1920x1080** (stretch canvas_items / expand). UI 픽셀 값(글자 크기·여백 등)은 이 해상도 기준으로 쓴다. 기본 글자 크기는 `ui/theme.tres` (27). 탐험 맵 한 칸 80px (Config `field_tile`).
- 진행 순서는 기획서 §17.2: 전투 프로토타입 → 탐험 프로토타입 → **생존·베이스캠프(진행 중)** → 생존·베이스캠프 → 로그라이크 → 콘텐츠.
- 1단계의 에피소드 진행(노드마다 자동 저장)은 대화 테스트용으로만 남아 있다. 실제 게임 루프는 탐험 회차(베이스캠프 저장, §11·§13).

---

# (1단계) 텍스트 대화 시스템 — 엑셀 기반 노드·선택지

## 목표
Godot 4.7(GDScript)로 **그림 없이 텍스트만으로 도는 짧은 테스트 에피소드 1편**을 만든다.
확인할 것은 하나다: **엑셀만 고쳐서 분기·선택지·아이템을 추가할 수 있는가.**

세계관과 실제 에피소드 내용은 기획자가 직접 쓴다. 테스트 데이터는 구조 검증용 더미로만 만들고, 스토리를 지어내지 않는다.

## 이번 단계 범위
포함: 엑셀→JSON 변환, 데이터 로더, 스토리 진행기, 조건·효과 해석기, 게임 상태(스탯·인벤토리·플래그), 세이브/로드, 최소 UI(텍스트 박스, 선택지 버튼, 스탯 표시, 인벤토리 목록, 에피소드 선택).
제외: 아트, 사운드, 연출(흔들림·타이핑 효과는 선택), 조합, 로그·단서 노트 화면, 설정 화면.

## 폴더 구조
```
res://
  data/          # 변환된 JSON (직접 수정 금지)
  autoload/      # data_loader.gd, story_runner.gd, game_state.gd, save_manager.gd
  scenes/        # title, episode_select, main_play, inventory
  ui/            # 재사용 컴포넌트
tools/
  xlsx_to_json.py
  sheets/content.xlsx  # 에피소드 대화·능력치 이름·Config·생존·거점·부활
  sheets/player.xlsx   # Player, PlayerParts, EquipSlots, Traits(특성)
  sheets/status.xlsx   # StatusEffects (상태이상)
  sheets/npc.xlsx      # Npcs, NpcParts, NpcAttacks
  sheets/item.xlsx     # Items, Loot
```

## 아키텍처
- **DataLoader** (autoload): `res://data/*.json`을 읽어 ID로 조회. 
- **GameState** (autoload): 체력(hp), 정신력(sanity), 시간(time), 인벤토리, 에피소드 플래그, 월드 플래그.
- **StoryRunner** (autoload): 현재 노드 진행, 선택지 조건 판정, 효과 적용, 시그널 발신.
- **SaveManager** (autoload): `user://`에 월드 상태 파일 1개 + 에피소드 진행 파일 분리 저장.
- UI 씬은 로직을 갖지 않는다. StoryRunner·GameState 시그널을 받아 그리고, 선택 입력만 돌려준다.

## 엑셀 시트 (tools/sheets/*.xlsx — 파일별 시트는 변환기 SHEET_FILES)
| 시트 | 열 |
| --- | --- |
| Episodes | episode_id, title, protagonist_id, start_node, unlock_condition |
| Nodes | node_id, episode_id, speaker_id, text, next_node, on_enter |
| Choices | choice_id, node_id, text, condition, show_mode, cost, effects, next_node |
| Items | item_id, name, type, description, use_effects, stack_max |
| Loot | loot_id, spot_id, item_id, amount, chance, time_cost |
| Player | player_id, name, name_color, traits, walk_speed, run_speed, 능력치 6개 (주인공) |
| Npcs | npc_id, name, name_color, traits, image, flee_chance, walk_speed, run_speed, 능력치 6개 (모든 NPC·적) |
| Endings | ending_id, episode_id, world_flags_set |

- 노드에 선택지가 없으면 `next_node`로 진행. `next_node`가 `END:<ending_id>`면 엔딩.
- `show_mode`: `hide`(조건 미충족 시 숨김) / `gray`(회색 표시). 기본값 `gray`.
- `cost`는 선택 전 표시용, 실제 차감은 `effects`에 적는다.

## 조건·효과 문법
조건 (`&` = AND, `|` = OR, `!` = NOT):
- `has:knife`, `has:bandage>=2`
- `flag:door_open` (에피소드 플래그), `wflag:ep1_clear` (월드 플래그)
- `stat:sanity>=30` (비교: `> >= < <= ==`)
- `trait:medic` (현재 주인공 능력)

효과 (`;`로 구분):
- `item:+bandage`, `item:-bandage`, `item:+bandage*2`
- `stat:hp-10`, `stat:time-30`
- `setflag:x`, `clearflag:x`, `setwflag:x`
- `loot:spot_id` (Loot 시트에서 확률 굴림)
- `goto:node_id`

파서는 문법 오류 시 크래시하지 말고 에러를 로그에 남긴 뒤 조건을 false로 처리한다.

## 스탯 규칙 (임시값, 데이터로 조정 가능하게)
- hp 0 → 사망 엔딩, sanity 0 → 광기 엔딩, time 0 → 에피소드에 지정된 시간 초과 노드로 이동.
- 인벤토리 칸 수는 설정값(기본 8). 가득 차면 획득 시 버릴 아이템을 고르게 한다.

## 변환 스크립트 (tools/xlsx_to_json.py)
- openpyxl 사용. 시트별 JSON 출력.
- 검사 후 오류 목록 출력, 오류 있으면 종료 코드 1:
  - 존재하지 않는 node_id / item_id / char_id 참조
  - 시작 노드에서 도달할 수 없는 노드
  - 출구(선택지·next_node·END) 없는 노드
  - 조건·효과 문법 오류
  - ID 중복

## 테스트 데이터
더미 에피소드 2편(`ep_test1`, `ep_test2`). 스토리 없이 "노드 A", "선택지 1" 같은 문구로만.
반드시 들어가야 할 케이스: 일반 선택지, 아이템 필요 조건부(hide와 gray 각각), 대가형, 탐색(loot), 인벤토리 초과, hp 0 사망, 월드 플래그로 `ep_test2` 해금.

## 완료 기준 (관문 1)
1. `python tools/xlsx_to_json.py` → 오류 없이 JSON 생성.
2. 게임 실행 → `ep_test1` 처음부터 엔딩까지 진행 가능, 위 케이스가 모두 동작.
3. `ep_test1` 클리어 후 에피소드 선택에서 `ep_test2`가 해금됨.
4. 엑셀에 선택지 1줄·노드 1개를 추가하고 변환만 다시 돌리면, **코드 수정 없이** 게임에 반영됨.
5. 저장 후 재시작해도 진행·인벤토리·월드 플래그 유지.

## 작업 방식
- 작은 단계로 나눠 커밋: 변환 스크립트 → DataLoader → GameState → 조건·효과 파서(단위 테스트 포함) → StoryRunner → UI → 세이브.
- 조건·효과 파서는 GDScript 테스트 씬이나 GUT로 케이스별 검증.
- 기획상 모호한 부분은 임의로 정하지 말고 질문하거나 TODO로 남긴다.

## 주사위 판정 (추가)
로그라이크·주사위 중심 구조로 확장 중. 이번 범위는 **대화 선택지 3종 + d20 판정 + 보정**까지. 로그라이크 구조(런·영구 성장)는 기획이 정리되면 다음 단계.

- 선택지 `type`: `normal`(주사위 없음) / `item`(주사위 없음, condition 의 `has:` 충족 시 반드시 성공) / `dice` / `combat`(필드 대화 전용, 아래 탐험 참고)
- `dice` 판정: **d20 + 보정치 ≥ dc** 이면 성공. 성공 확률 = `(21 − (dc − 보정치)) / 20` 을 선택지에 표시.
  - 성공 → `effects`·`next_node`, 실패 → `fail_effects`·`fail_next`
- 보정치 = 능력치 + 소지 아이템 `dice_bonus` + 선택지 `mod`(상황 보정)
  - 능력치 6개 (확정): strength 근력 / endurance 지구력 / intelligence 지능 / health 건강 / mental 정신력 / divinity 신성력(스킬용). `Abilities` 시트는 이름만, 값은 `Player`·`Npcs` 시트의 같은 이름 열
  - 육성: 효과 `abil:stat_a+1` (에피소드 안에서 유지), 조건 `abil:stat_a>=3`
  - 아이템: `Items.dice_bonus` (`stat_a+2` 또는 `all+1`), 소지 중이면 개수와 무관하게 1번 적용
- 추가 열·시트는 모두 선택(없어도 변환됨). 변환기가 check/dc/실패 출구 누락과 없는 ability_id 를 오류로 잡는다.
- 주사위 1 = 대실패(무조건 실패), 20 = 대성공(무조건 성공). 그래서 표시 확률은 5%~95%.
- 영구 능력치 강화는 없음(확정). 미정(TODO): 에피소드 간 인계.

## 전투 프로토타입 (진행 중, 기획서 §7–9)
범위: 부위 선택 공격, 적 공격 전조, WASD 방향+타이밍 회피, 부위 파괴·사지 절단. 아트 없이 도형·텍스트 placeholder.
- 전투 로직은 `core/combat/` (UI 없이 테스트 가능), 화면은 `scenes/combat.tscn`. 타이틀의 "전투 테스트"로 진입.
- 데이터: 엑셀 `PlayerParts`(hp, attack), `Npcs`(flee_chance, image), `NpcParts`(hp, attack, hit_chance), `NpcAttacks` 시트 + Config 의 `combat_*` 키.
  - **플레이어·NPC 시트 분리** (2026-10-14): NPC 와도 싸울 수 있어서 적은 따로 없고 `Npcs` 에 모두 둔다. `NpcParts`·`NpcAttacks` 가 있는 NPC = 싸울 수 있음 (변환 결과 `data/enemies.json`, enemy_id = npc_id). 대화 화자 = Player + Npcs (`data/characters.json`).
  - 부위별 공격력(`attack`)은 값만 저장 — TODO(기획): 피해 공식. 지금 플레이어 피해는 Config `combat_player_damage`, NPC 피해는 `NpcAttacks.damage`.
  - 이동 속도(칸/초): 플레이어 `walk_speed`, Shift(패드 L1, 액션 `run`) 누르는 동안 `run_speed`. 맵의 적은 순찰 = walk, 추격 = run.
  - **몬스터 속성** (2026-10-15): Npcs `kind` = monster / npc (비우면 npc). 몬스터는 맵에 '적'으로 놓아 마주치면 전투부터. 맵의 적이 몬스터가 아니면 변환 경고, 맵 탭 적 목록은 몬스터 먼저.
  - **전투 중 대화**: 행동 버튼 공격 / 특수 / **대화** / 아이템 / 도주. 대화 = 상대(NPC든 몬스터든)의 NPC 대화를 전투 화면 위에 띄움 (`DataLoader.npc_dialogue[npc_id]` = 그 대화의 ▶ 시작 카드, `main_play.over_combat` 은 초상화·인벤토리 숨김). 대사는 시작 카드의 길 조건 **`combat:any`** (또는 `combat:npc_id`, 지금 싸우는 상대 — `GameState.combat_enemy`)로 나눠 쓴다. 효과 **`endcombat:win`**(상대가 물러남 = 승리) / **`endcombat:flee`**(빠져나옴 = 도주). 전투 중 대화의 전투 선택지 = 대화를 끝내고 하던 전투로. 대화가 없는 상대는 '말이 통하지 않는다'(턴 안 씀). 그냥 끝나면 Config `combat_talk_uses_turn`(1 = 적 차례, TODO 기획). 대화 중 시작한 전투에서 말을 걸어도 `StoryRunner.save_state/restore_state` 로 원래 대화로 돌아가고, 숨긴 대화 화면은 StoryRunner 신호를 받지 않는다(`main_play._link`). 더미 `tools/dialogues/monster_test.json` (enemy_test), 테스트 `tests/combat_talk_smoke`.
  - 행동 버튼: 공격 / **특수** / 아이템 / 도주. (대화 추가 2026-10-15) 특수 = 스킬·무기 던지기 등 — TODO(기획): 데이터가 없어 지금은 '없다' 안내만. 신성력은 스킬용(아직 안 쓰임).
  - 텍스트 창 배경 불투명도 70%.
- 회피 키: 머리 W / 왼팔·왼다리 A / 몸통 S / 오른팔·오른다리 D. 판정 완벽·일반·실패(기획서 §8.3).
- **화면 배치** (사용자 시안): 왼쪽 위 적 이름(밑줄) / 가운데 적 그림(Enemies.image, 비우면 실루엣 `ui/enemy_figure.gd`) / 왼쪽 아래 '내 상태' 사람 모양(`body_diagram.figure`) / 가운데 아래 텍스트 창(시스템 메시지 + 공격할 부위 같은 세부 선택지) / 그 오른쪽 행동 버튼 **공격·아이템·도주** (방어 버튼은 시안에 없어 뺐다, 규칙 코드는 남아 있음).
- 아이템: 인벤토리를 열어 소모품 사용 (`StoryRunner.use_item_in_combat`, 효과가 전투 중 몸 상태에 바로 적용). Config `combat_item_uses_turn`(1 = 턴 씀). TODO(기획): 장비 착용 — 장비 시스템 없음.
- 도주: 주사위 1~100 이 적의 도주 성공률(Enemies `flee_chance` %, 비우면 Config `combat_flee_chance`) 이하면 성공.
- 공격 패턴: normal / quick / combo(여러 부위 연속) / feint(전조가 도중에 바뀜).
- 임시로 정한 것(TODO, 기획서 §18 미확정): 턴 순서(플레이어→적), 부위 HP·명중률·피해량, 회피 판정 시간, 방어·도주 효과, 절단 시 행동 제약, 스태미나 없음.

## 탐험 프로토타입 (진행 중, 기획서 §6, §17.2 2단계)
범위: 탑뷰 이동·벽 충돌·카메라, 순찰·시야·추격하는 적, 접촉 시 전투(필드 위에 겹쳐 띄움) → 승리/도주/사망 처리, 조사 지점(텍스트 + Loot 굴림).
- 화면 `scenes/field/field.tscn` (타이틀 "탐험 테스트"). 플레이어 신체 상태(부상·절단)는 한 회차 동안 전투 사이에 이어진다.
- 맵: **`tools/maps/<map_id>.json`** (Godot '맵' 탭 = addons/map_editor 로 편집). tiles(`#` 벽 `.` 바닥), start(P 도착), run_start(S 회차 시작), objects(x,y 좌표). 아트가 들어오면 TileMap 으로 옮길 것.
- 맵 위 물체(맵 파일 objects): enemy(ref=enemy_id, patrol_dir·patrol_len 왕복) / investigate(text, ref=Loot spot_id) / npc / camp / exit. 조정값 Config `field_*`. 맵 에디터 '테스트 플레이'는 user://playtest_saves/ 만 쓴다.
- **맵 에디터 편집 기능** (2026-10-14, addons/map_editor): 실행 취소·다시 실행(스냅샷, Ctrl+Z/Y), □ 사각형 칠하기(또는 Shift), 선택 도구로 영역 선택·Shift 다중 선택·함께 옮기기, 복사·붙여넣기(Ctrl+C/V, 새 object_id), 여러 개 묶음 편집, 연결 표시(→ 맵·도착 P / ← 들어오는 곳, 잘못되면 빨간 ⚠), 문 더블클릭 = 이어진 맵 열기, 왼쪽 칸(모든 맵 검색 · 맵 목록 · 표시 필터 — 숨긴 종류는 고를 수 없음). 캔버스 단축키는 캔버스를 누른 뒤. 테스트 tests/map_editor_smoke.
  - 화면 정리(2026-10-14): 위 줄 = 맵·파일·편집 ▾ 메뉴·변환/테스트·❓ 사용법(창으로 열림), 도구 줄은 묶음별(칠하기·위치·물체·이동). 변환 결과 칸은 실패할 때만 열림. 왼쪽 칸은 접는 구역(맵 목록은 이름만, 이어진 맵은 마우스 설명). 캔버스의 시야 원·연결 글자는 고르거나 마우스를 올린 물체만, 이름표는 충분히 확대했을 때만 (잘못된 연결 ⚠ 는 항상).
  - 맵 테스트(map_editor_smoke, travel_smoke)는 **`tests/fixtures/maps/`** 복사본을 쓴다 → tools/maps 의 test_ 맵은 마음대로 고쳐도 된다.
- **맵 이동** (2026-10-14): 문(exit, E 로 열고 걸어 들어감) / 통로(passage, 밟으면 바로) / 이용(transit, 사다리 등 E) / 가장자리(맵 파일 `edges` {up/down/left/right: {ref, arrive}}, 그쪽 맨 끝 칸에 닿으면) / 효과 `move:map_id` · `move:map_id@arrive_id` (대화 중이면 대화가 끝난 뒤). 도착: **도착 P 는 한 종류**(type=arrive, 초록 P) 여러 개, ★ 기본 P(`default: true`)는 **베이스캠프만 필수**(부활·불러오기 자리), 다른 맵은 선택 — 기본 P 가 없는 맵은 들어오는 곳마다 P 를 이어 둬야 함(빠지면 변환 오류·에디터 ⚠, `move:맵` 도 @P 필요). 변환기 `start` = 기본 P → 첫 P → S. 더미 `test_arrive` = 기본 P 없는 맵 예시. 도착 P 의 `from` = 이어지는 곳 목록(이 맵으로 오는 문·통로·이용 object_id, 가장자리 "맵:방향") — 그곳으로 들어오면 그 P. 출발 쪽 `arrive` 로 골라도 됨(둘 다 정하면 변환 오류). 아무 데도 안 정하면 기본 P. 도착한 칸을 한 번 벗어나기 전에는 통로·가장자리가 다시 작동하지 않음. 더미 맵 `test_travel`, 베이스캠프 도착 지점 `bc_gate`(정문). 테스트 `tests/travel_smoke`.
- **그래픽 — 픽셀아트·조명·그림자** (2026-10-15, 기획 `tevah_pixelart_2d_lighting_map_editor_spec_v1.0` Phase 1~3 + 4 일부): **논리(벽 #·바닥 .·충돌·문·시야·AI)는 그대로, 보이는 모습만** 덧붙임.
  - 렌더러 `core/map_renderer.gd`(@tool) 하나를 필드와 맵 에디터가 같이 씀 (에디터는 맵 뒤 SubViewport). 층: 검은 바탕 → 바닥 → 바닥 장식 → 벽 외형 (TileMapLayer, 그림 16px(Config `tile_art_px`) × 5 = 80px, nearest). 칸 규칙·데이터 읽기 `core/visual_data.gd` (칠하지 않은 칸 = floor_default / wall_default, 없는 타일 이름도 기본 타일).
  - 데이터 `tools/sheets/graphics.xlsx`: `Tiles`(tile_key·name·layer floor/detail/wall·file(art/tiles/)·atlas_x·atlas_y·casts_shadow), `LightPresets`(색·energy·radius 칸·shadow), `DayNight`(profile_id·hour·ambient·sun_color·sun_energy — outdoor 는 시간대별, indoor·underground 는 한 줄 = 늘 같음, 값은 임시) → `data/graphics.json`. 더미 타일 `art/tiles/test_tiles.png`.
  - 맵 파일(추가 칸, 없어도 됨): `visual.layers {floor|detail|wall: {"x,y": tile_key}}`, `environment.profile`, 광원 = 물체 `type=light` (preset·color·energy·radius·shadow·enabled — 놓을 때 프리셋 값 복사, 선택·이동·복사·실행 취소를 물체처럼). 변환기 `validate_graphics`: 시트는 오류, 맵의 틀린 타일·프리셋·환경은 경고(맵은 열림).
  - 조명: CanvasModulate(환경광) + 실외 DirectionalLight2D(색·밝기만, 그림자 없음 — Godot 방향광 그림자는 끝없이 길어서) + PointLight2D(광원, 그림자 필터 없음). 그림자 = casts_shadow 벽 타일(가로로 합친 LightOccluder2D) + 문(닫히면 막음, `field.toggle_door` → `renderer.set_door_open`). 게임 시계 `clock_changed` 를 따라감 → 대화·전투·메뉴에 멈추고 잠(시간 점프)에 바로 갱신. 적 AI·시야는 빛과 무관.
  - **맵 에디터 저장은 무손실**: 맵·물체의 모든 칸을 그대로 쓰고 빈 기본값(빈 edges·빈 from·default=false)만 뺀다 (전에는 정해진 칸만 써서 이벤트 once·NPC face 가 빠졌음).
  - 에디터: 도구 '그래픽'(타일 붓·타일 지우개·광원), 왼쪽 '타일 팔레트'(층·찾기·그림), 맵 설정 '환경', 광원 세부, 위 줄 '시간 미리보기'(에디터만), 표시 필터(그래픽·조명·광원·광원 범위·그림자 차단·벽 판정). 테스트 `tests/graphics_smoke`(성능 측정 포함), `map_editor_smoke`.
  - **오브젝트 그림 + Y 정렬** (2026-10-15): graphics.xlsx `Props`(prop_id·name·file(art/props/)·foot_w·foot_h·solid·casts_shadow), 맵 물체 `type=prop`(ref = prop_id, 놓은 칸 = 차지하는 칸의 왼쪽 아래). 렌더러 `build_props(parent)` 가 Sprite2D(위치 = 발, 그림은 위로)를 Y 정렬 노드에 — 필드는 인물이 있는 `%World`(y_sort), 에디터는 렌더러 안. solid = 벽 충돌(WALL_LAYER → 이동·적 시야 막음, 컷신 길 찾기도), casts_shadow = 빛 막음. `VisualData.prop_cells/solid_cells`. 더미 그림 art/props/test_*.png.
  - **손전등**: item.xlsx Items `light` 열(= LightPresets preset_id) — 손(kind=hand) 칸에 들면 플레이어에 광원이 붙어 다님 (`field.held_light`, `_update_held_light` on equipment_changed). LightPresets `shape` point / cone(원뿔, 바라보는 쪽으로 회전). 더미 아이템 flashlight 손전등(테스트).
  - 맵 에디터 '그래픽 경고'(`graphics_warnings`): 없는 타일·오브젝트·프리셋·환경, 맵 밖 칸 → 맵 설정 칸 위 ⚠·열 때 상태 글자, 없는 타일 칸은 캔버스에 붉은 X. 끌어서 옮기기는 마우스 칸으로 바로 (원래 위치를 물체 키 사전 대신 목록에 저장).
  - 아직(기획 Phase 5·후속): 시간대별 야외 그림자 길이, 셰이더 픽셀 조명, 한 맵 안 실내/실외 영역 차광(지금은 맵 단위 환경), 타일 자동 연결, 인물 그림, 광원 깜빡임, 손전등 켜고 끄기·배터리.
- **문(exit)**: 처음엔 닫힘. 닫힌 문은 플레이어·적 모두 통과 못 하고 적의 시야도 가린다(DOOR_LAYER 8). E 로 열고 닫는다. 열린 문 칸으로 걸어 들어가면 그 맵(ref)으로 나간다.
- **빈 공간**: 맵 칸 `' '`(공백) = 검은색, 지나갈 수 없음. 맵 바깥도 검게 그린다. 맵 에디터 '빈 공간' 도구.
- 적 순찰 경로는 매 회차 같다 (외워서 피하기, §6). 도주하면 `field_flee_grace` 초 동안 다시 덤비지 않는다.
- 입력 액션은 `core/input_actions.gd` 한 곳에서 등록 (move_*, interact, dodge_*).
- **NPC 대화**: Nodes 에서 `episode_id` 를 비운 노드 = 필드 대화, 끝은 `next_node`(또는 `fail_next`)에 `EXIT`. 맵 물체 `type=npc`, `ref`=시작 노드. 말을 걸 때마다 시작 노드부터 (플래그·조건으로 분기). 대화 화면은 `scenes/main_play` 를 `embedded=true` 로 필드 위에 띄우고 `StoryRunner.start_dialogue()` (mode="field": 엔딩·스탯 규칙·자동 저장 없음).
- 탐험 중 주인공은 Config `protagonist_id` (능력치·능력·주사위 보정·대화 배치).
- **대화에서 전투**: 선택지 `type=combat`, `check`=enemy_id. 대화를 숨기고 전투(`StoryRunner.combat_requested` → 필드가 띄움 → `finish_combat`). 이기면 effects·next_node, 도주하면 fail_effects·fail_next 로 대화 계속, 지면 대화가 닫히고 필드 사망 처리(부활 규칙). 맵 위 적 물체와는 무관 (NPC 를 없애려면 플래그 + 물체 condition). 테스트는 `combat_override`.
- 임시·미구현(TODO): 사망 시 맵 처음부터(회차·부활 §11), 시간 흐름(§4), 생존 파라미터(§5, 필드 대화의 stat: 효과도 이때 연결), 맵 이동, 소지품 가득 참 처리(필드 조사), 조사 time_cost.

## 생존·베이스캠프 (진행 중, 기획서 §4, §5, §11–13)
- **회차 상태**는 GameState: `current_map`, `clock`(분), `survival`, `player_body`, `field_state`(맵별 처치한 적·조사한 곳), 소지품·플래그·능력치.
  - **새 회차** `SaveManager.begin_run()`: `run_count`+1, Config `start_map`(test_field) 의 **S(맵 한복판)** 에서 깨어남. 게임 첫 시작도 같다.
  - **사망** (§11): 엑셀 `Revivals` 에서 condition 이 참인 첫 행이 있으면 **부활** — effects 적용(아이템 소모 등), text 표시, `revive_run()`: 소지품·시간·생존·부상·플래그 모두 유지한 채 **베이스캠프 P** 에서 깨어남, 저장 유지. 맞는 행이 없으면 `end_run()`: **게임 처음부터**.
    - TODO(기획 확인): 부활 시 치명 부위(머리·몸통)만 최대 HP로 회복, 잘린 팔다리는 유지(§9 거래로만 복구).
    - 월드 `death_count`: 부활 포함 모든 사망 횟수 (초월적 존재의 반복 부활 인식용). 조건 `count:death>=1`, `count:run>=2` (run_count).
  - **대화 횟수** 조건 `count:talk` (2026-10-14): 지금 대화를 전에 몇 번 했나 — 첫 대화 = 0, 두 번째 = 1 … (`count:talk==0` 첫 대사 / `count:talk>=1` 반복 대사, 조건 분기 카드나 선택지 조건에). 대화 시작 노드(NPC 의 ref)마다 따로 셈 (`GameState.begin_talk`, `talk_counts`), 회차 저장에 들어가고 새 회차면 0. 에피소드 대화에서는 항상 0. 대화 에디터 미리보기는 Esc 로 다시 시작하면 횟수가 이어짐.
  - **사지 복구 거래** (§9, §10): 조건 `cut:left_arm` / `cut:any` (vital 아닌 부위가 잘렸나), 효과 `restore:left_arm` / `restore:all` (최대 HP로 복구). 대가는 같은 선택지 effects 에 함께 적어 즉시 지불 (`item:-relic;restore:left_arm`). 거래는 초월체 필드 대화의 선택지로 만든다. TODO(기획 §10): 존재별 거래 조건·대가 종류.
  - **영구 능력치 강화는 없다** (확정).
  - **저장 슬롯 여러 개** (Config `save_slots`=5, 파일 `user://saves/run_<n>.json`). 잠에서 깨거나 효과 `save`(고양이) 때 슬롯 선택 창(`ui/save_slot_picker.gd`)이 뜬다. 이미 쓴 슬롯은 두 번 눌러야 덮어씀, "저장하지 않기" 가능. 타이틀 '이어하기'도 슬롯을 골라 불러온다. 예전 `run.json` 은 슬롯 1로 자동 이동. 효과 save 는 `StoryRunner.save_slot_requested` 로 화면에 슬롯을 물어본다 (테스트는 `save_slot_override`).
  - **사망해도 저장 슬롯은 지우지 않는다** (기획 변경, 기획서 §13 '죽음 취소 불가'와 다름). 새 회차에서 저장하면 덮어쓴다. 그래서 타이틀 '이어하기'로 죽기 전 저장을 불러올 수 있다.
  - **저장은 베이스캠프에서만** (`SaveManager.can_save_run()`). 방법은 둘:
    - **잠**: CampActions `kind=sleep` (minutes=60, effects 는 1시간마다), ← → 로 1~`sleep_max_hours` 시간을 조절해(처음 `sleep_default_hours`) 자고 나면 저장. 고양이가 있어도 잠으로 저장된다. 별도 "저장" 버튼은 없다.
    - **고양이**(하나, §15.1)가 와 있으면 고양이에게도: 필드 대화의 효과 `save`.
  - NPC 의 하루 루틴은 맵 물체 `schedule` ("06:00-12:00, 20:00-23:00", 자정 넘김 "22:00-02:00" 가능). 그 시간대에만 나타나고, 시계가 흐르면(탐험·잠) 바로 나타나거나 사라진다. `condition` 과 함께 쓰면 둘 다 맞아야 있다.
  - 이어하기 = 마지막 베이스캠프 저장 (§13.2 미정이라 임시로 이 방식).
  - 월드(`world.json`): 월드 플래그 + `run_count` + `death_count` — 회차가 바뀌어도 유지 (초월적 존재의 부활 인식용).
- **시간**: 탐험 중 실시간 (Config `time_scale` = 실제 1초당 게임 분). 전투·대화·메뉴·메시지 중에는 멈춤. 베이스캠프 행동 `minutes`, 조사 Loot `time_cost` 만큼 흐름.
- **생존 파라미터**: 엑셀 `Survival` (start, max, decay_per_hour, warn). 100 = 좋음. 조건 `surv:hunger<30`, 효과 `surv:hunger+40`.
- **베이스캠프**: 맵 `tools/maps/basecamp.json`, 물체 `camp` = 거점 메뉴(엑셀 `CampActions`: minutes, condition, effects, kind=sleep), `exit` = 맵 이동(도착은 그 맵의 P).
- **소지품·장비** (2026-10-14): 소지품(I) = 격자 칸 (`scenes/inventory.gd`, 필드에서는 오른쪽에 붙음). 장비창(Q) = 왼쪽, [장비] 탭(엑셀 player.xlsx `EquipSlots`: slot_id·name·kind·col·row — 가방 / 머리 / 왼손·몸·오른손 / 왼다리·오른다리 배치) + [능력치] 탭(맨 위 내 상태, 아래 능력치 6개 육각형 `ui/ability_hexagon.gd`). 둘을 같이 열어 끌어다 놓기(`ui/item_cell.gd`)로 장착·벗기, 소지품 우클릭 = 장착, 장비 칸 우클릭 = 벗기.
  - item.xlsx Items: `weight`(개당 무게), `equip_slot`(장착 종류 = EquipSlots 의 kind: bag/head/hand/body/leg), `bag_slots`(장착 시 늘어나는 칸 — 가방). 칸 수 = Config `inventory_slots`(4, 가방 없을 때) + 장착한 bag_slots. 가방을 벗어 칸이 모자라면 못 벗음.
  - **손(kind=hand)에는 아무 아이템이나 1개씩 들 수 있고, 손에 든 것은 소지품 칸에 안 셈** (확정). 우클릭 장착은 맞는 빈 칸 → 없으면 첫 칸과 바꿔 끼기, 종류 없는 아이템은 손.
  - 무게 = 소지품 + 장비. Config `carry_heavy_weight` 이상이면 이동 속도 x`carry_heavy_speed_mult`, `carry_max_weight` 이상이면 못 움직임. TODO(기획): 기준값·근력과의 관계 미정 (지금 임시값).
  - 장착한 아이템도 `has:` 조건·판정 보정(dice_bonus)에 들어가고, `item:-x` 효과는 소지품에 없으면 장비에서 뺀다. GameState `equipment` 는 회차 저장에 들어감. 전투 중에는 장착 불가(소모품만).
  - 머리·몸·다리 칸에 들어갈 장비 아이템은 아직 없음 — TODO(기획).
- **상태이상** (2026-10-14): **status.xlsx** `StatusEffects` (status_id, name, description + scope part/whole, tick_mode, tick_amount, stack_rule, dispel, death_cause, state, note — 기획 `tevah_character_creation_status_effects_spec_v0.1` §6–8 의 확정 4종 bleeding·panic_disorder·fear·withdrawal + 후보 8종, 미정 수치는 빈칸). 실제 효과(틱 피해·사망 원인 등)는 아직 없음 TODO. 효과 `status:+id` 걸기 / `status:-id` 풀기, 조건 `status:id`. GameState `statuses`(회차 저장에 들어감, 새 회차에 비움). 장비창 능력치 탭 오른쪽 위에 빨간 이름, 마우스를 올리면 description. 더미: 출혈·매스꺼움·공황. TODO(기획): 실제 효과·지속 시간·부활 때 처리.
  - **특성** (2026-10-14, 같은 기획 §2–5): **player.xlsx `Traits`** (trait_id, name, polarity positive/negative, points 긍정=소비 음수·부정=획득 양수, category, description, conflicts, selectable 1/0, state 확정/일부 확정/후보, note). 40종 후보 (확정: 고지능자 -6, 골초 +2 / 이름·방향 확정: 반사신경, 용감함). 변환기가 부호·polarity·conflicts·selectable 검사, Player·Npcs traits 와 조건 trait: 에 없는 특성은 경고. `data/traits.json`, `DataLoader.traits`.
    - **캐릭터 생성** `scenes/character_creation.tscn`: 시작 포인트 Config `creation_start_points` = **5** (확정). 남은 P = 5 + 고른 points 합. 못 고르는 이유 표시(selectable 0 / conflicts 양쪽 / 포인트 부족), 남은 P < 0 이면 시작 불가, 최종 확인 창. 타이틀: 캐릭터가 없으면 '새 게임' → 생성, 있으면 '새 회차'(같은 캐릭터) + '새 게임 (캐릭터 다시 만들기)'(`SaveManager.new_game()` = 월드 기록·특성 지움, 저장 슬롯은 남김).
    - **가진 특성** `GameState.owned_traits` [{trait_id, from: creation/event}] — 월드 저장(죽어도 다음 회차에 남음, 생성 화면 다시 안 뜸) + 회차 저장에도. **저장 슬롯을 불러오면 그 저장의 특성으로 되돌림 (§5.4 안 B, 확정)**, 그 특성을 월드에도 기록. 특성 기록 없는 예전 저장은 지금 특성 그대로. 조건 `trait:id` = Player.traits + 가진 특성. 효과 `trait:+id` / `trait:-id` (사건·거래, 중복 없음, 바로 월드 저장). **상성**(Traits.conflicts, 용감함↔겁쟁이 등 13쌍): 생성 화면에서는 같이 못 고르고, 사건으로 반대 특성을 얻으면 가지고 있던 쪽이 사라지고 새 특성으로 바뀐다 (확정). 알림은 얻든 잃든 "{주인공 이름}이/가 영향 받았습니다." 만 (어떤 특성인지는 안 알림, `StoryRunner.with_subject` 가 이/가 고름).
    - 장비창 **세 번째 탭 '특성'**: 긍정 / 부정 나눠서, 얻은 곳(생성·사건), 마우스를 올리면 효과.
    - 아직 없음(TODO 기획): 특성의 실제 효과(판정 보정·회피·생존 수치 등), 거래 전용 처리, 사건 자동 획득 규칙(trait_event_rules). 테스트 `tests/test_traits`(헤드리스), `tests/creation_smoke`.
  - 능력치 탭 배치(사용자 시안): 왼쪽 몸 상태 / 오른쪽 위 상태이상 / 오른쪽 아래 능력치 육각형.
- 필드 소지품: I / Tab. 필드 조사·거점 행동·아이템 사용은 `StoryRunner.run_effects()` / `use_item()` (대화 밖, mode="field") 으로 같은 효과 엔진을 쓴다.
- 임시·미구현(TODO, 기획 미확정): 파라미터가 낮거나 0일 때의 효과·사망 여부(§5), 시간 배율·행동 시간(§4), 탐험 중 종료 처리(§13.2), 사망·부활 연출(§11).

## 대화 에디터 (addons/dialogue_editor)
- 대화(노드·선택지)의 원본은 **`tools/dialogues/<대화ID>.json`** (대화 하나 = 파일 하나). 변환기가 엑셀 Nodes·Choices 뒤에 합쳐 같은 규칙으로 검사한다. 엑셀 Nodes·Choices 도 계속 읽는다 (1단계 에피소드 테스트 대화는 엑셀에 있음).
  - 파일: `{ dialogue_id, episode_id("" = 필드 대화), nodes: [{node_id, speaker_id, text, next_node, on_enter, pos}], choices: [{choice_id, node_id, text, condition, show_mode, cost, effects, next_node, type, check, dc, mod, fail_effects, fail_next}] }` (combat 은 check=enemy_id, fail_*=도주)
- 왼쪽 대화 목록: 더블클릭(또는 오른쪽 클릭 메뉴) = 대화 이름(dialogue_id·파일 이름) 바꾸기 — 카드 ID 는 그대로라 연결 유지. 끌어 놓기·오른쪽 클릭 위로/아래로 = 순서, `tools/dialogues/_order.json` 에 저장(`_` 로 시작하는 파일은 대화 아님). 변환기도 이 순서로 읽어서 같은 시점의 자동 시작 컷신이 이 순서로 나온다.
- Godot 위쪽 **'대화' 탭** (EditorPlugin 메인 화면). 대사 카드(GraphNode)를 선으로 이어 next_node / 선택지 next_node / 판정 fail_next 를 정한다. 대화 끝(EXIT)·엔딩(END:id) 카드. 다른 파일·엑셀 노드로는 오른쪽 칸 '이동(직접 입력)'.
  - 연결선은 데이터(next_node 등)를 따른다: 연결/끊기 → 데이터 수정 → 다시 그림 (`_sync_connections`).
  - 버튼: 새 대화 / 대사 추가 / 엔딩 카드 / 저장 / 변환·검사(`tools/xlsx_to_json.py --log`, 결과는 UTF-8 로그 파일로 받음) / 미리보기(`addons/dialogue_editor/preview.tscn`, 고른 카드부터 실제 대화 화면, save 효과는 저장 안 함).
  - 맥은 `python3`, 윈도우는 `python` 으로 변환기를 실행.
- **기능 카드** (노드 `kind`, 엑셀 Nodes 에서도 선택 열): `effect` = on_enter 효과만 실행하고 next_node 로 (화면에 안 보임) / `branch` = `condition` 이 맞으면 next_node, 아니면 `fail_next`. 기본(빈 값·line) = 대사. 도구줄 '＋ 기능 카드' 또는 그래프 오른쪽 클릭.
- **직접 입력 대신 고르기**: 조건·효과 칸은 `addons/expr_rows.gd` (줄마다 종류·아이템·수치를 목록에서 고름, 괄호 식·goto 는 '직접 입력 보기'로만). 이동 칸은 갈 곳 목록. 목록 이름표는 `ToolCommon.load_lookups()` (data/*.json, 쓰이는 플래그 이름 포함). 맵 탭 물체의 '나타나는 조건'도 같은 부품. 문법을 바꾸면 expr_rows 의 EFFECTS·CONDS 도 맞출 것.
- 테스트: `tests/dialogue_editor_smoke.tscn` (에디터 화면을 게임 안에서 띄워 열기·연결·저장·새 대화·변환 확인).
- **v1.0 개편** (2026-10-14, 기획 `tevah_dialogue_editor_v1.0_spec.md` 1·2차): "대본을 쓰고 노드로 흐름을 설계". 화면 = 왼쪽(대화 목록·모든 대화 찾기·카드 팔레트 끌어 놓기) / 가운데 위 그래프(미니맵) · 아래 **대본 칸**(`script_panel.gd`, ⤢ 크게) / 오른쪽 세부(기본·조건·결과·고급 접기) / 아래 검사 결과(⛔ 오류·⚠ 경고, 누르면 그 카드·페이지).
  - **대본 블록 = 노드 하나에 페이지 여러 개.** 노드 선택 필드 `pages: [{page_id, display(narration/bubble/system/subtitle — subtitle = 자막: 상자 없이 화면 아래 글자, 화자 선택), speaker_id(bubble 필수·subtitle 선택), text, speed?, advance?("auto"), auto_wait?}]`. **pages 가 없으면 예전처럼 speaker_id·text 로 1페이지** (호환). 에디터는 기본값 1페이지(화자 있으면 말풍선·없으면 상황 묘사)면 예전 형식으로 저장 — 시스템·자막은 항상 pages, 아니면 pages + 예전 칸(첫 페이지)도 맞춰 씀. 대화 파일 선택 필드 `text_speed` = 그 대화의 기본 속도. 공용 규칙 `core/script_pages.gd` (런타임·에디터·테스트), 변환기 `check_pages` 가 같은 규칙으로 검사.
  - 본문: 빈 줄 = 문단, 줄바꿈 = 강제 줄바꿈, `{w=0.5}` = 0.5초 대기(⏸ 버튼으로 넣고 주황색 표시). 속도 기본/instant/slow/normal/fast/숫자(초당 글자) → Config `text_speed_default`·`text_speed_slow/normal/fast` (임시값, TODO 기획 §10.3).
  - 게임(`main_play`): 글자가 한 자씩, 출력 중 입력 1번 = 페이지 전체, 다음 입력 = 다음 페이지, 자동 넘김은 다 나오고 auto_wait 초 뒤. 선택지는 마지막 페이지가 다 나온 뒤. 미리보기는 고른 페이지부터(`start_page`). 대화 화면을 클릭으로 넘기는 테스트는 `DataLoader.config.text_speed_default = "instant"` 로 둔다.
  - 편집: 실행 취소·다시 실행(대화 전체 스냅샷 `_touch(key)`, 같은 key 의 연속 입력은 한 번으로), 복사·붙여넣기·복제(새 node·choice ID, 복사한 카드끼리의 연결만 새 ID 로), 연결점을 빈 곳에 놓으면 새 카드+연결, 카드 접기(노드 `fold`), 자동 정렬, F = 가운데로, 저장 안 함 표시(●)·다른 대화 열 때 확인. 없는 곳으로 가는 연결은 카드에 ⚠.
  - 변환기 경고(`Report.warn`, 변환은 됨): 빈 대사·빈 페이지. 테스트 `tests/test_script_pages`(헤드리스), 대화 에디터 테스트는 **`tests/fixtures/dialogues/`** 복사본을 씀.
  - **NPC 단위 대화 + ▶ 대화 시작 카드** (2026-10-14): 대화 파일 하나 = NPC 하나 (파일 `npc_id`, npc.xlsx Npcs). 노드 `kind=start` (파일마다 하나, 필드 대화 전용, 선택지·페이지 없음): `routes: [{condition, next_node}]` 를 위에서부터 보고 조건이 맞는 첫 길, 하나도 안 맞으면 `next_node`(그 외). 런타임 `StoryRunner._goto`. 맵 NPC 의 `ref` = 시작 카드 (cat_start / npc1_start / npc2_start). 시작 카드는 맵에 아직 안 놓여도 도달성 검사의 뿌리(안 쓰이면 경고). 에디터: 새 대화 = NPC 고르기 → 시작 카드 + 그 NPC 말풍선 첫 카드, 새 대본 블록도 그 NPC 말풍선으로, 목록에 NPC 이름, 맵 탭 '대화' 목록은 ▶ 시작 카드가 먼저. 1단계 에피소드 대화(episode_id)는 그대로 읽힌다.
  - **🎬 연출 카드 / 컷신** (2026-10-15): 노드 `kind=direct`, `steps: [{do, …}]` 를 차례로 (규칙 `core/direction.gd`, 변환기 `check_steps`). 화면 단계 image{file,fade}(art/cutscenes/ 의 직접 만든 그림, 화면 가득·대사 상자 아래) / image_off / fade{to black·white·clear, time} / shake{power,time} / wait{time} — `main_play` 가 처리(`cg`·`fade` 층, `directing` 중엔 넘김 없음). 필드 단계 walk{who player·NPC object_id, to [x,y], speed, wait}(AStarGrid2D 길 찾기) / camera{who 또는 to, time}(who=player 면 다시 따라감) / vanish{who} — `field._direct_step` (`StoryRunner.field_director`), 미리보기에서는 건너뜀. 연출 동안 대사 상자 숨김·필드 대화라 조작 불가, 대화가 끝나면 카메라 복귀. NPC 의 나타나는 조건은 플래그·소지품이 바뀌면 바로 다시 본다(컷신 중 등장). 위치 이동은 맵을 다시 불러오면 원래대로(계속 바꾸려면 플래그 + 조건). StoryRunner 는 `direction_requested` → 보이는 대화 화면 → `direction_finished()`, 받을 화면이 없으면 건너뜀(테스트 `direction_override`).
  - 연출 추가 (2026-10-15): **소리** sound{file,volume%}(audio/sfx/) / music{file,fade,volume}(audio/bgm/, 반복, 대화 뒤에도 계속) / music_off{fade} — autoload **`Sound`**(autoload/sound.gd, 파일 직접 읽기 지원, TODO 기획: 옵션 음량). **바라보는 방향** face{who,dir} + 걸으면 가는 쪽, NPC·플레이어 `facing`(원 위 선), 맵 NPC 물체 `face`(처음 방향). **건너뛰기**: 컷신(연출 카드를 돌린 대화)에서 오른쪽 위 '건너뛰기 ▶▶'·Esc → 단계는 `_instant`(바로 끝난 모습, 기다림·흔들기·효과음 생략, 배경음 변화는 적용), 대사는 저절로 넘기고 선택지·대화 끝에서 멈춤 (`main_play.skip`, field `_finish`). **자동 시작 컷신** (2026-10-16): 시작 카드(kind=start, **한 대화에 여러 개 가능**)의 '🎬 자동 시작' 토글 = 노드 `trigger {when, map, once}` — when: `logo`(켜자마자) / `before_title` / `after_title`(타이틀에서 새 게임·새 회차·이어하기를 누른 직후) / `new_game`(캐릭터 생성 직후, `GameState.opening_pending`) / `map_enter`(그 map 에 들어올 때 — 회차 시작·이동·불러오기). once: 로고·타이틀 전후는 '처음 켤 때만'(`user://…/seen_cutscenes.cfg`), 방 진입은 그 회차에 한 번(field_state done `cut:노드`). 같은 시점 여럿이면 차례로. `DataLoader.triggers`, `core/cutscene_triggers.gd`(take). 첫 화면은 **`scenes/boot.tscn`**(project main_scene) → 로고·타이틀 이전 → 타이틀. 필드 밖 컷신은 `scenes/cutscene_player`(검은 바탕 + 대화 화면, 필드 단계는 건너뜀). 필드는 `_cutscenes` 줄(새 게임 시작 후 → 방 진입 후). 예전 방식(대화 파일 `opening: true`, Config `opening_dialogue`)도 새 게임 시작 후로 계속 동작 — 에디터는 예전 체크를 카드의 자동 시작으로 옮기는 버튼. 더미 `tools/dialogues/opening.json` = 새 게임 시작 후. 새 대화 창에 'NPC 없음 (오프닝·이벤트 컷신)'. 더미 소리 audio/sfx/test_beep.wav, audio/bgm/test_loop.wav.
  - **이벤트 칸** (맵 물체 `type=event`, ref = 대화 노드, `once` = 한 번만 → field_state done): 밟으면 그 대화(컷신) 시작, 게임에서는 안 보임, 나타나는 조건은 밟을 때 확인. 맵 탭 '이벤트' 도구, 칸에 마우스를 올리면 좌표 표시. 더미 그림 `art/cutscenes/test_cg.png`, 테스트 `tests/cutscene_smoke`.
  - 아직 안 한 것(기획 3~5차): 굵게·색 강조, 효과음, 게임 옵션의 텍스트 속도 우선, 미리보기 테스트 상태 주입·d20 고정·실행 경로 표시, 템플릿, 시퀀스 호출·복귀 노드.
