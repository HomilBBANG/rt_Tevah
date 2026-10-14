extends RefCounted
## 키 입력 액션 등록 (project.godot 대신 코드에서 한 곳에 모아 둠).
##   move_*  : 탐험 이동 (WASD, 방향키, 패드 십자키·왼스틱)
##   interact: 조사·대화 (E, Space, Enter, 패드 A)
##   inventory: 소지품 (I, Tab, 패드 Y)
##   equipment: 장비창 (Q, 패드 X)
##   run     : 누르는 동안 달리기 (Shift, 패드 L1)
##   dodge_* : 전투 회피 (WASD, 방향키, 패드 십자키) — 기획서 §8.1

const KEYS := {
	"move_up": [KEY_W, KEY_UP], "move_left": [KEY_A, KEY_LEFT],
	"move_down": [KEY_S, KEY_DOWN], "move_right": [KEY_D, KEY_RIGHT],
	"dodge_up": [KEY_W, KEY_UP], "dodge_left": [KEY_A, KEY_LEFT],
	"dodge_down": [KEY_S, KEY_DOWN], "dodge_right": [KEY_D, KEY_RIGHT],
	"interact": [KEY_E, KEY_SPACE, KEY_ENTER],
	"inventory": [KEY_I, KEY_TAB],
	"equipment": [KEY_Q],
	"run": [KEY_SHIFT],
}
const PAD_BUTTONS := {
	"move_up": JOY_BUTTON_DPAD_UP, "move_left": JOY_BUTTON_DPAD_LEFT,
	"move_down": JOY_BUTTON_DPAD_DOWN, "move_right": JOY_BUTTON_DPAD_RIGHT,
	"dodge_up": JOY_BUTTON_DPAD_UP, "dodge_left": JOY_BUTTON_DPAD_LEFT,
	"dodge_down": JOY_BUTTON_DPAD_DOWN, "dodge_right": JOY_BUTTON_DPAD_RIGHT,
	"interact": JOY_BUTTON_A,
	"inventory": JOY_BUTTON_Y,
	"equipment": JOY_BUTTON_X,
	"run": JOY_BUTTON_LEFT_SHOULDER,
}
const PAD_AXES := {
	"move_up": [JOY_AXIS_LEFT_Y, -1.0], "move_down": [JOY_AXIS_LEFT_Y, 1.0],
	"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0],
}


static func ensure() -> void:
	for action in KEYS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action, 0.3)
		for k in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(action, ev)
		var jb := InputEventJoypadButton.new()
		jb.button_index = PAD_BUTTONS[action]
		InputMap.action_add_event(action, jb)
		if PAD_AXES.has(action):
			var ja := InputEventJoypadMotion.new()
			ja.axis = PAD_AXES[action][0]
			ja.axis_value = PAD_AXES[action][1]
			InputMap.action_add_event(action, ja)
