extends CharacterBody2D
## 탐험 중 플레이어 (아트 전 placeholder: 원 + 바라보는 방향 표시)

var field: Node          # field.gd
var radius := 23.0
var sprite: Sprite2D     # 캐릭터 그림 (Config player_sprite — 없으면 원 도형). 발 = 충돌 원 아래쪽
var _anim_t := 0.0
var speed := 192.0        # 걷기 (픽셀/초)
var run_speed := 288.0    # 달리기: run 액션(Shift)을 누르는 동안
var facing := Vector2.DOWN:
	set(v):
		facing = v
		queue_redraw()


func _physics_process(_delta: float) -> void:
	if field.frozen:
		velocity = Vector2.ZERO
		return
	var dir := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	# 무게: 무거우면 느려지고 최대 무게면 못 움직인다 (GameState.carry_speed_mult)
	velocity = dir * (run_speed if Input.is_action_pressed("run") else speed) * GameState.carry_speed_mult()
	if dir != Vector2.ZERO:
		facing = dir.normalized()
		queue_redraw()
	move_and_slide()
	_animate(_delta, velocity.length() > 1.0)


## 캐릭터 그림: Config player_sprite (가로로 이어 붙인 프레임, player_sprite_frames 장, player_sprite_frame_time 초씩).
## 크기 = 타일과 같은 픽셀 밀도 (field_tile / tile_art_px 배, Config character_scale 로 바꿀 수 있음). 그림이 왼쪽을 보면 오른쪽으로 갈 때 뒤집음.
func setup_sprite() -> void:
	var path := str(DataLoader.config.get("player_sprite", "res://art/characters/player.png"))
	var tex: Texture2D = load(path) if ResourceLoader.exists(path) else null
	if tex == null:
		return
	var frames := maxi(1, int(DataLoader.config.get("player_sprite_frames", 2)))
	var k := float(DataLoader.config.get("character_scale", 0.0))
	if k <= 0.0:
		k = float(DataLoader.config.get("field_tile", 80)) / float(DataLoader.config.get("tile_art_px", 16))
	sprite = Sprite2D.new()
	sprite.texture = tex
	sprite.hframes = frames
	sprite.frame = frames - 1 if frames > 1 else 0
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.centered = false
	var fw := tex.get_width() / frames
	sprite.offset = Vector2(-fw / 2.0, -tex.get_height() + 1)   # 그림 아래 가운데 = 발
	sprite.scale = Vector2(k, k)
	sprite.position = Vector2(0, radius * 0.6)
	add_child(sprite)
	queue_redraw()


func _animate(delta: float, moving: bool) -> void:
	if sprite == null:
		return
	if facing.x > 0.1:
		sprite.flip_h = true   # 원래 그림이 왼쪽을 봄
	elif facing.x < -0.1:
		sprite.flip_h = false
	if sprite.hframes < 2:
		return
	if not moving:
		sprite.frame = sprite.hframes - 1
		_anim_t = 0.0
		return
	_anim_t += delta
	var ft := float(DataLoader.config.get("player_sprite_frame_time", 0.6))
	if Input.is_action_pressed("run"):
		ft *= 0.6
	sprite.frame = int(_anim_t / maxf(0.05, ft)) % sprite.hframes


func _draw() -> void:
	if sprite != null:
		return   # 그림이 있으면 원 도형은 안 그림
	draw_circle(Vector2.ZERO, radius, Color("e8dcc8"))
	draw_circle(Vector2.ZERO, radius, Color("3a3a3a"), false, 3.0, true)
	draw_line(Vector2.ZERO, facing * radius * 0.9, Color("3a3a3a"), 5.0, true)
