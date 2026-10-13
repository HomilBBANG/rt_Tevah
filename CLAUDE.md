# 테바 — 생존 호러 RPG (Godot 4.7)

## 현재 방향 (2026-10-13 변경)
- 기획서: `docs/survival_horror_rpg_tevah_v0.2.md` 가 기준. 숫자·규칙이 기획서에 없으면 임의로 정하지 말고 데이터(엑셀)로 조정 가능하게 두고 TODO 로 남긴다.
- **텍스트 어드벤처 → 탑뷰 모험으로 전환.** 아래 1단계에서 만든 엑셀 기반 노드·선택지·대화 시스템은 **스토리 전개와 인물 간 대화**에 그대로 쓴다 (대화 중 선택지 포함).
- **주사위(d20)는 대화 선택지에서만** 쓴다. 전투 회피는 플레이어 숙련(방향+타이밍 입력)으로 판정한다.
- 진행 순서는 기획서 §17.2: 전투 프로토타입 → **탐험 프로토타입(진행 중)** → 생존·베이스캠프 → 로그라이크 → 콘텐츠.
- 기획서와 아직 맞지 않는 부분(나중에 고칠 것): 에피소드 단위 진행·노드마다 자동 저장 ↔ 회차 구조·베이스캠프 저장(§11, §13).

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
  sheets/content.xlsx
```

## 아키텍처
- **DataLoader** (autoload): `res://data/*.json`을 읽어 ID로 조회. 
- **GameState** (autoload): 체력(hp), 정신력(sanity), 시간(time), 인벤토리, 에피소드 플래그, 월드 플래그.
- **StoryRunner** (autoload): 현재 노드 진행, 선택지 조건 판정, 효과 적용, 시그널 발신.
- **SaveManager** (autoload): `user://`에 월드 상태 파일 1개 + 에피소드 진행 파일 분리 저장.
- UI 씬은 로직을 갖지 않는다. StoryRunner·GameState 시그널을 받아 그리고, 선택 입력만 돌려준다.

## 엑셀 시트 (content.xlsx)
| 시트 | 열 |
| --- | --- |
| Episodes | episode_id, title, protagonist_id, start_node, unlock_condition |
| Nodes | node_id, episode_id, speaker_id, text, next_node, on_enter |
| Choices | choice_id, node_id, text, condition, show_mode, cost, effects, next_node |
| Items | item_id, name, type, description, use_effects, stack_max |
| Loot | loot_id, spot_id, item_id, amount, chance, time_cost |
| Characters | char_id, name, traits |
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

- 선택지 `type`: `normal`(주사위 없음) / `item`(주사위 없음, condition 의 `has:` 충족 시 반드시 성공) / `dice`
- `dice` 판정: **d20 + 보정치 ≥ dc** 이면 성공. 성공 확률 = `(21 − (dc − 보정치)) / 20` 을 선택지에 표시.
  - 성공 → `effects`·`next_node`, 실패 → `fail_effects`·`fail_next`
- 보정치 = 능력치 + 소지 아이템 `dice_bonus` + 선택지 `mod`(상황 보정)
  - 능력치: `Abilities` 시트(ability_id, name), 캐릭터별 기본값 `Characters.abilities` (`stat_a=3, stat_b=1`)
  - 육성: 효과 `abil:stat_a+1` (에피소드 안에서 유지), 조건 `abil:stat_a>=3`
  - 아이템: `Items.dice_bonus` (`stat_a+2` 또는 `all+1`), 소지 중이면 개수와 무관하게 1번 적용
- 추가 열·시트는 모두 선택(없어도 변환됨). 변환기가 check/dc/실패 출구 누락과 없는 ability_id 를 오류로 잡는다.
- 주사위 1 = 대실패(무조건 실패), 20 = 대성공(무조건 성공). 그래서 표시 확률은 5%~95%.
- 미정(TODO): 능력치 영구 성장, 에피소드 간 인계.

## 전투 프로토타입 (진행 중, 기획서 §7–9)
범위: 부위 선택 공격, 적 공격 전조, WASD 방향+타이밍 회피, 부위 파괴·사지 절단. 아트 없이 도형·텍스트 placeholder.
- 전투 로직은 `core/combat/` (UI 없이 테스트 가능), 화면은 `scenes/combat.tscn`. 타이틀의 "전투 테스트"로 진입.
- 데이터: 엑셀 `PlayerParts`, `Enemies`, `EnemyParts`, `EnemyAttacks` 시트 + Config 의 `combat_*` 키.
- 회피 키: 머리 W / 왼팔·왼다리 A / 몸통 S / 오른팔·오른다리 D. 판정 완벽·일반·실패(기획서 §8.3).
- 공격 패턴: normal / quick / combo(여러 부위 연속) / feint(전조가 도중에 바뀜).
- 임시로 정한 것(TODO, 기획서 §18 미확정): 턴 순서(플레이어→적), 부위 HP·명중률·피해량, 회피 판정 시간, 방어·도주 효과, 절단 시 행동 제약, 스태미나 없음.

## 탐험 프로토타입 (진행 중, 기획서 §6, §17.2 2단계)
범위: 탑뷰 이동·벽 충돌·카메라, 순찰·시야·추격하는 적, 접촉 시 전투(필드 위에 겹쳐 띄움) → 승리/도주/사망 처리, 조사 지점(텍스트 + Loot 굴림).
- 화면 `scenes/field/field.tscn` (타이틀 "탐험 테스트"). 플레이어 신체 상태(부상·절단)는 한 회차 동안 전투 사이에 이어진다.
- 맵 모양: `tools/maps/<map_id>.txt` (`#` 벽, `.` 바닥, `P` 시작, 그 밖의 글자 = FieldObjects 의 marker). 아트가 들어오면 TileMap 으로 옮길 것.
- 맵 위 물체: 엑셀 `FieldObjects` (enemy: ref=enemy_id, patrol='right 4' 왕복 / investigate: text, ref=Loot spot_id). 조정값 Config `field_*`.
- 적 순찰 경로는 매 회차 같다 (외워서 피하기, §6). 도주하면 `field_flee_grace` 초 동안 다시 덤비지 않는다.
- 입력 액션은 `core/input_actions.gd` 한 곳에서 등록 (move_*, interact, dodge_*).
- **NPC 대화**: Nodes 에서 `episode_id` 를 비운 노드 = 필드 대화, 끝은 `next_node`(또는 `fail_next`)에 `EXIT`. FieldObjects `type=npc`, `ref`=시작 노드. 말을 걸 때마다 시작 노드부터 (플래그·조건으로 분기). 대화 화면은 `scenes/main_play` 를 `embedded=true` 로 필드 위에 띄우고 `StoryRunner.start_dialogue()` (mode="field": 엔딩·스탯 규칙·자동 저장 없음).
- 탐험 중 주인공은 Config `protagonist_id` (능력치·능력·주사위 보정·대화 배치).
- 임시·미구현(TODO): 사망 시 맵 처음부터(회차·부활 §11), 시간 흐름(§4), 생존 파라미터(§5, 필드 대화의 stat: 효과도 이때 연결), 맵 이동, 대화에서 전투 시작, 소지품 가득 참 처리(필드 조사), 조사 time_cost.
