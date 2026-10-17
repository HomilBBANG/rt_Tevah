extends ColorRect
## 화면 가장자리 어둠 (비네트). 필드 HUD 맨 아래(지도·인물 위, 글자·창 아래)에 깐다. 마우스는 통과.
## Config vignette_strength(0 = 끔 ~ 1 = 가장자리 완전히 검게) · vignette_inner(어두워지기 시작하는 거리, 0 = 가운데 ~ 1 = 가장자리)
## · vignette_color. 화면 비율에 맞춰 원이 아니라 화면 모양으로 어두워짐.

const SHADER := """
shader_type canvas_item;
uniform float strength = 0.6;
uniform float inner = 0.45;
uniform float aspect = 1.7778;
uniform vec3 tint = vec3(0.0);
void fragment() {
	vec2 p = (UV - 0.5) * 2.0;               // 화면 모양 타원: 가운데 0, 위·아래·좌·우 끝 1, 모서리 1.41
	p.y *= mix(1.0, 1.0 / aspect, 0.25);    // 가로로 긴 화면: 위·아래는 조금 덜 어둡게
	float v = smoothstep(inner, 1.42, length(p));
	COLOR = vec4(tint, clamp(v * strength, 0.0, 1.0));
}
"""


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := ShaderMaterial.new()
	mat.shader = Shader.new()
	mat.shader.code = SHADER
	material = mat
	apply_config()
	resized.connect(_on_resized)
	_on_resized()


func apply_config() -> void:
	var cfg: Dictionary = DataLoader.config
	var strength := float(cfg.get("vignette_strength", 0.75))
	material.set_shader_parameter("strength", strength)
	material.set_shader_parameter("inner", float(cfg.get("vignette_inner", 0.35)))
	var c := str(cfg.get("vignette_color", "#000000"))
	var col := Color.html(c) if Color.html_is_valid(c) else Color.BLACK
	material.set_shader_parameter("tint", Vector3(col.r, col.g, col.b))
	visible = strength > 0.0


func _on_resized() -> void:
	if size.y > 0:
		material.set_shader_parameter("aspect", size.x / size.y)
