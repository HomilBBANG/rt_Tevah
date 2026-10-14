# 테바 — 생존 호러 RPG (Godot 4.7)

## 현재 방향 (2026-10-13 변경)
- 기획서: `docs/survival_horror_rpg_tevah_v0.2.md` 가 기준. 숫자·규칙이 기획서에 없으면 임의로 정하지 말고 데이터(엑셀)로 조정 가능하게 두고 TODO 로 남긴다.
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
  sheets/player.xlsx   # Player, PlayerParts
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
  - 행동 버튼: 공격 / **특수** / 아이템 / 도주. 특수 = 스킬·무기 던지기 등 — TODO(기획): 데이터가 없어 지금은 '없다' 안내만. 신성력은 스킬용(아직 안 쓰임).
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
- 필드 소지품: I / Tab. 필드 조사·거점 행동·아이템 사용은 `StoryRunner.run_effects()` / `use_item()` (대화 밖, mode="field") 으로 같은 효과 엔진을 쓴다.
- 임시·미구현(TODO, 기획 미확정): 파라미터가 낮거나 0일 때의 효과·사망 여부(§5), 시간 배율·행동 시간(§4), 탐험 중 종료 처리(§13.2), 사망·부활 연출(§11).

## 대화 에디터 (addons/dialogue_editor)
- 대화(노드·선택지)의 원본은 **`tools/dialogues/<대화ID>.json`** (대화 하나 = 파일 하나). 변환기가 엑셀 Nodes·Choices 뒤에 합쳐 같은 규칙으로 검사한다. 엑셀 Nodes·Choices 도 계속 읽는다 (1단계 에피소드 테스트 대화는 엑셀에 있음).
  - 파일: `{ dialogue_id, episode_id("" = 필드 대화), nodes: [{node_id, speaker_id, text, next_node, on_enter, pos}], choices: [{choice_id, node_id, text, condition, show_mode, cost, effects, next_node, type, check, dc, mod, fail_effects, fail_next}] }` (combat 은 check=enemy_id, fail_*=도주)
- Godot 위쪽 **'대화' 탭** (EditorPlugin 메인 화면). 대사 카드(GraphNode)를 선으로 이어 next_node / 선택지 next_node / 판정 fail_next 를 정한다. 대화 끝(EXIT)·엔딩(END:id) 카드. 다른 파일·엑셀 노드로는 오른쪽 칸 '이동(직접 입력)'.
  - 연결선은 데이터(next_node 등)를 따른다: 연결/끊기 → 데이터 수정 → 다시 그림 (`_sync_connections`).
  - 버튼: 새 대화 / 대사 추가 / 엔딩 카드 / 저장 / 변환·검사(`tools/xlsx_to_json.py --log`, 결과는 UTF-8 로그 파일로 받음) / 미리보기(`addons/dialogue_editor/preview.tscn`, 고른 카드부터 실제 대화 화면, save 효과는 저장 안 함).
  - 맥은 `python3`, 윈도우는 `python` 으로 변환기를 실행.
- **기능 카드** (노드 `kind`, 엑셀 Nodes 에서도 선택 열): `effect` = on_enter 효과만 실행하고 next_node 로 (화면에 안 보임) / `branch` = `condition` 이 맞으면 next_node, 아니면 `fail_next`. 기본(빈 값·line) = 대사. 도구줄 '＋ 기능 카드' 또는 그래프 오른쪽 클릭.
- **직접 입력 대신 고르기**: 조건·효과 칸은 `addons/expr_rows.gd` (줄마다 종류·아이템·수치를 목록에서 고름, 괄호 식·goto 는 '직접 입력 보기'로만). 이동 칸은 갈 곳 목록. 목록 이름표는 `ToolCommon.load_lookups()` (data/*.json, 쓰이는 플래그 이름 포함). 맵 탭 물체의 '나타나는 조건'도 같은 부품. 문법을 바꾸면 expr_rows 의 EFFECTS·CONDS 도 맞출 것.
- 테스트: `tests/dialogue_editor_smoke.tscn` (에디터 화면을 게임 안에서 띄워 열기·연결·저장·새 대화·변환 확인).
