extends Control
## 영화식 위아래 검은 띠 (화면 높이의 BAR). 타이틀·에피소드 선택 등은 늘 띄워 둠.
## 탐험 필드는 플레이어가 조작할 수 없을 때(대화·연출)만 띄움 — set_open(true/false) 로 위아래에서 밀려 들어오고 나감.

const BAR := 0.106

var _tw: Tween


## on = 띠를 보임, time = 밀려 들어오는 시간 (0 = 바로)
func set_open(on: bool, time := 0.35) -> void:
	if _tw and _tw.is_valid():
		_tw.kill()
	var top: Control = $Top
	var bottom: Control = $Bottom
	var to := BAR if on else 0.0
	if time <= 0.0 or not is_inside_tree():
		top.anchor_bottom = to
		bottom.anchor_top = 1.0 - to
		return
	_tw = create_tween().set_parallel().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_tw.tween_property(top, "anchor_bottom", to, time)
	_tw.tween_property(bottom, "anchor_top", 1.0 - to, time)


func is_open() -> bool:
	return ($Top as Control).anchor_bottom > BAR * 0.5
