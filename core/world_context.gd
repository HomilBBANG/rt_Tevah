extends RefCounted
## 에피소드 밖(에피소드 선택 화면)에서 해금 조건을 판정할 때 쓰는 조건 컨텍스트.
## 월드 플래그만 참이 될 수 있고, 아이템·스탯·에피소드 플래그·능력은 항상 없음으로 본다.


func item_count(_id: String) -> int: return 0
func get_stat(_name: String) -> int: return 0
func get_ability(_id: String) -> int: return 0
func has_flag(_name: String) -> bool: return false
func has_wflag(name: String) -> bool: return GameState.has_wflag(name)
func has_trait(_name: String) -> bool: return false
