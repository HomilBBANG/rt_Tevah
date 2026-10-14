@tool
extends "res://addons/dialogue_editor/dialogue_card.gd"
## 기능 카드 (화면에 보이지 않는 노드). data.kind:
##   effect — 들어오면 효과(on_enter)를 차례로 실행하고 '다음 →' 으로
##   branch — 조건(condition)이 맞으면 '맞으면 →'(next_node), 아니면 '아니면 →'(fail_next)
## 효과·조건은 카드 안에서 목록으로 고른다 (addons/expr_rows.gd).

const ExprRows = preload("res://addons/expr_rows.gd")
const EFFECT_COLOR := Color(0.18, 0.36, 0.26)
const BRANCH_COLOR := Color(0.33, 0.24, 0.45)

var lookups := {}


func rebuild() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	out_ports = []
	var is_branch: bool = data.get("kind", "") == "branch"
	title = ("◇ 조건 분기   " if is_branch else "⚙ 효과   ") + data.node_id
	for s in ["titlebar", "titlebar_selected"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = (BRANCH_COLOR if is_branch else EFFECT_COLOR).lightened(0.15 if s == "titlebar_selected" else 0.0)
		sb.set_content_margin_all(6)
		add_theme_stylebox_override(s, sb)
	var head := Label.new()
	head.text = "조건을 확인해서 길이 갈립니다 (화면에 안 보임)" if is_branch else "아래 효과를 차례로 실행합니다 (화면에 안 보임)"
	head.modulate = Color(1, 1, 1, 0.7)
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_add_row(head, true, false)
	var field := "condition" if is_branch else "on_enter"
	var rows: Node = ExprRows.new().setup("cond" if is_branch else "effect", data.get(field, ""), lookups)
	rows.changed.connect(func(t):
		data[field] = t
		changed.emit())
	_add_row(rows, false, false)
	if is_branch:
		var yes := Label.new()
		yes.text = "맞으면 →  " + _target_hint(data.get("next_node", ""))
		yes.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_add_row(yes, false, true)
		out_ports.append(["next", -1])
		var no := Label.new()
		no.text = "아니면 →  " + _target_hint(data.get("fail_next", ""))
		no.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		no.add_theme_color_override("font_color", FAIL_COLOR)
		_add_row(no, false, true, FAIL_COLOR)
		out_ports.append(["else", -1])
	else:
		var nx := Label.new()
		nx.text = "다음 →  " + _target_hint(data.get("next_node", ""))
		nx.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_add_row(nx, false, true)
		out_ports.append(["next", -1])


func port_target(port: int) -> Array:
	if out_ports[port][0] == "else":
		return [data, "fail_next"]
	return super(port)
