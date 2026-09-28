# 텍스트 생존 어드벤처 — 프로토타입 (1단계)

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
