extends Node2D
## Antrenman: the player (bottom) plays against the AI (top); the AI learns from the player.

const CELL_SIZE := 32
const GRID_WIDTH := SnakeArena.GRID_WIDTH
const GRID_HEIGHT := SnakeArena.GRID_HEIGHT
const BARRIER_ROW := SnakeArena.BARRIER_ROW

const PHASE2_DURATION := 10.0
const MOVE_INTERVAL := 0.14
const SWIPE_THRESHOLD := 24.0
const SAVE_PATH := "user://snakey_save.json"

# Shared Q-learning brain (see scripts/core/brain.gd).
var brain := SnakeBrain.new()

# Game rules (see scripts/core/arena.gd). TOP = AI, BOTTOM = player. Mirrored food.
var arena := SnakeArena.new(PHASE2_DURATION, true)
var pending_direction_player: int = SnakeArena.Dir.RIGHT

var best_score: int = 0

var match_over: bool = false

var move_timer: Timer
var score_label: Label
var ai_level_label: Label
var timer_label: Label
var message_label: Label
var restart_button: Button
var menu_button: Button

var touch_start: Vector2 = Vector2.ZERO
var touch_start_valid: bool = false


func _ready() -> void:
	randomize()
	_load_best_score()
	brain.load_brain()
	brain.load_player_model()
	_setup_ui()

	move_timer = Timer.new()
	move_timer.one_shot = false
	move_timer.wait_time = MOVE_INTERVAL
	add_child(move_timer)
	move_timer.timeout.connect(_on_move_timer_timeout)

	_start_match()


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var width := float(CELL_SIZE * GRID_WIDTH)
	var height := float(CELL_SIZE * GRID_HEIGHT)

	score_label = Label.new()
	score_label.add_theme_font_size_override("font_size", 22)
	score_label.position = Vector2(16, 8)
	canvas.add_child(score_label)

	ai_level_label = Label.new()
	ai_level_label.add_theme_font_size_override("font_size", 15)
	ai_level_label.position = Vector2(16, 34)
	canvas.add_child(ai_level_label)

	timer_label = Label.new()
	timer_label.add_theme_font_size_override("font_size", 20)
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.size = Vector2(width, 28)
	timer_label.position = Vector2(0, 8)
	canvas.add_child(timer_label)

	message_label = Label.new()
	message_label.add_theme_font_size_override("font_size", 24)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.visible = false
	message_label.size = Vector2(width, 110)
	message_label.position = Vector2(0, height / 2.0 - 100)
	canvas.add_child(message_label)

	restart_button = Button.new()
	restart_button.text = "Tekrar Oyna"
	restart_button.visible = false
	restart_button.custom_minimum_size = Vector2(180, 56)
	restart_button.position = Vector2(width / 2.0 - 90, height / 2.0 + 10)
	restart_button.pressed.connect(_start_match)
	canvas.add_child(restart_button)

	menu_button = Button.new()
	menu_button.text = "Ana Menu"
	menu_button.visible = false
	menu_button.custom_minimum_size = Vector2(180, 56)
	menu_button.position = Vector2(width / 2.0 - 90, height / 2.0 + 76)
	menu_button.pressed.connect(_on_menu_pressed)
	canvas.add_child(menu_button)


func _start_match() -> void:
	match_over = false
	arena.reset()
	pending_direction_player = SnakeArena.Dir.RIGHT

	move_timer.wait_time = MOVE_INTERVAL
	move_timer.start()

	message_label.visible = false
	restart_button.visible = false
	menu_button.visible = false

	_update_score_label()
	_update_ai_level_label()
	_update_timer_label()
	queue_redraw()


func _process(delta: float) -> void:
	if match_over:
		return
	var event := arena.advance_time(delta)
	if event == SnakeArena.TimeEvent.BARRIER_OPENED:
		queue_redraw()
	elif event == SnakeArena.TimeEvent.TIME_UP:
		_time_up()
	_update_timer_label()


func _on_move_timer_timeout() -> void:
	if match_over:
		return

	# Learn from how the player is playing (imitation signal for the AI).
	# State and action use the heading from before this tick's pending input.
	var player_state := arena.compute_state(SnakeArena.Side.BOTTOM)
	var player_action := SnakeArena.direction_to_relative(pending_direction_player, arena.direction_bottom)
	brain.record_player_choice(player_state, player_action)

	var target_ai: Vector2i = arena.target_for(SnakeArena.Side.TOP)
	var old_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.TOP), target_ai)

	var state := arena.compute_state(SnakeArena.Side.TOP)
	var action := brain.select_action(state)
	var new_direction_ai := SnakeArena.relative_to_direction(action, arena.direction_top)

	var result := arena.step(new_direction_ai, pending_direction_player)
	var player_crashed: bool = result["bottom_crashed"]
	var ai_crashed: bool = result["top_crashed"]

	if player_crashed or ai_crashed:
		var terminal_reward: float = brain.terminal_reward(ai_crashed)
		brain.update_q(state, action, terminal_reward, "", true)
		_finish_round(player_crashed, ai_crashed)
		return

	var new_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.TOP), target_ai)
	var reward: float = brain.step_reward(result["top_ate"], old_dist, new_dist)

	var next_state := arena.compute_state(SnakeArena.Side.TOP)
	brain.update_q(state, action, reward, next_state, false)

	_update_score_label()
	queue_redraw()


func _finish_round(player_crashed: bool, ai_crashed: bool) -> void:
	var text := ""
	if player_crashed and ai_crashed:
		if arena.score_bottom == arena.score_top:
			text = "Carpisma - Berabere!"
		elif arena.score_bottom > arena.score_top:
			text = "Carpisma - Skorla Kazandin!"
		else:
			text = "Carpisma - Skorla Kaybettin!"
	elif ai_crashed:
		text = "Kazandin! Rakip carpti."
	else:
		text = "Kaybettin! Sen carptin."
	_end_match(text)


func _time_up() -> void:
	var text := ""
	if arena.score_bottom == arena.score_top:
		text = "Sure Doldu - Berabere!"
	elif arena.score_bottom > arena.score_top:
		text = "Sure Doldu - Kazandin!"
	else:
		text = "Sure Doldu - Kaybettin!"
	_end_match(text)


func _end_match(result_text: String) -> void:
	match_over = true
	move_timer.stop()

	if arena.score_bottom > best_score:
		best_score = arena.score_bottom
		_save_best_score()

	brain.finish_match()
	brain.save_brain()
	brain.save_player_model()
	_update_ai_level_label()

	message_label.text = "%s\nSen: %d   Bot: %d" % [result_text, arena.score_bottom, arena.score_top]
	message_label.visible = true
	restart_button.visible = true
	menu_button.visible = true


func _update_score_label() -> void:
	score_label.text = "Sen: %d   Bot: %d" % [arena.score_bottom, arena.score_top]


func _ai_tier_name() -> String:
	if brain.games_played < 5:
		return "Acemi"
	elif brain.games_played < 15:
		return "Gelisiyor"
	elif brain.games_played < 40:
		return "Deneyimli"
	else:
		return "Usta"


func _update_ai_level_label() -> void:
	ai_level_label.text = "AI: %s (%d mac)" % [_ai_tier_name(), brain.games_played]


func _update_timer_label() -> void:
	if arena.phase == 1:
		var remaining := int(ceil(SnakeArena.PHASE1_DURATION - arena.elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Hazirlik: %ds" % remaining
	else:
		var remaining := int(ceil(SnakeArena.PHASE1_DURATION + arena.phase2_duration - arena.elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Acik Saha: %ds" % remaining


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_UP, KEY_W:
				_queue_direction(SnakeArena.Dir.UP)
			KEY_DOWN, KEY_S:
				_queue_direction(SnakeArena.Dir.DOWN)
			KEY_LEFT, KEY_A:
				_queue_direction(SnakeArena.Dir.LEFT)
			KEY_RIGHT, KEY_D:
				_queue_direction(SnakeArena.Dir.RIGHT)

	if event is InputEventScreenTouch:
		if event.pressed:
			touch_start = event.position
			touch_start_valid = true
		else:
			touch_start_valid = false
	elif event is InputEventScreenDrag and touch_start_valid:
		var delta: Vector2 = event.position - touch_start
		if delta.length() > SWIPE_THRESHOLD:
			if absf(delta.x) > absf(delta.y):
				_queue_direction(SnakeArena.Dir.RIGHT if delta.x > 0 else SnakeArena.Dir.LEFT)
			else:
				_queue_direction(SnakeArena.Dir.DOWN if delta.y > 0 else SnakeArena.Dir.UP)
			touch_start_valid = false


func _queue_direction(new_dir: int) -> void:
	var opposite := {
		SnakeArena.Dir.UP: SnakeArena.Dir.DOWN,
		SnakeArena.Dir.DOWN: SnakeArena.Dir.UP,
		SnakeArena.Dir.LEFT: SnakeArena.Dir.RIGHT,
		SnakeArena.Dir.RIGHT: SnakeArena.Dir.LEFT,
	}
	if new_dir != opposite.get(arena.direction_bottom, -1):
		pending_direction_player = new_dir


func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _draw() -> void:
	for x in range(GRID_WIDTH):
		for y in range(GRID_HEIGHT):
			var rect := Rect2(x * CELL_SIZE, y * CELL_SIZE, CELL_SIZE, CELL_SIZE)
			var col := Color(0.13, 0.15, 0.13) if (x + y) % 2 == 0 else Color(0.11, 0.13, 0.11)
			draw_rect(rect, col)

	if arena.phase == 1:
		var barrier_rect := Rect2(0, BARRIER_ROW * CELL_SIZE, GRID_WIDTH * CELL_SIZE, CELL_SIZE)
		draw_rect(barrier_rect, Color(0.55, 0.2, 0.2))
	else:
		var line_y := BARRIER_ROW * CELL_SIZE + CELL_SIZE / 2.0
		var x := 0
		while x < GRID_WIDTH * CELL_SIZE:
			draw_line(Vector2(x, line_y), Vector2(x + CELL_SIZE * 0.6, line_y), Color(0.4, 0.4, 0.4), 2.0)
			x += CELL_SIZE

	if arena.phase == 1:
		_draw_food(arena.food_top)
		_draw_food(arena.food_bottom)
	else:
		_draw_food(arena.food_shared)

	_draw_snake(arena.snake_top, Color(0.55, 0.75, 1.0), Color(0.3, 0.5, 0.9))
	_draw_snake(arena.snake_bottom, Color(0.55, 0.95, 0.6), Color(0.25, 0.7, 0.3))


func _draw_food(pos: Vector2i) -> void:
	if pos.x < 0 or pos.y < 0:
		return
	draw_circle(
		Vector2(pos.x * CELL_SIZE + CELL_SIZE / 2.0, pos.y * CELL_SIZE + CELL_SIZE / 2.0),
		CELL_SIZE * 0.38,
		Color(0.9, 0.25, 0.25)
	)


func _draw_snake(body: Array, head_color: Color, body_color: Color) -> void:
	for i in range(body.size()):
		var p: Vector2i = body[i]
		var rect := Rect2(p.x * CELL_SIZE + 2, p.y * CELL_SIZE + 2, CELL_SIZE - 4, CELL_SIZE - 4)
		var col := head_color if i == 0 else body_color
		draw_rect(rect, col, true)


func _save_best_score() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"best": best_score}))
		f.close()


func _load_best_score() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(data) == TYPE_DICTIONARY and data.has("best"):
				best_score = int(data["best"])
