extends Node2D

const CELL_SIZE := 32
const GRID_WIDTH := SnakeArena.GRID_WIDTH
const GRID_HEIGHT := SnakeArena.GRID_HEIGHT
const BARRIER_ROW := SnakeArena.BARRIER_ROW
const PHASE2_DURATION := 30.0
const MOVE_INTERVAL := 0.14

const LADDER_PATH := "user://ladder_progress.json"

# Shared Q-learning brain (see scripts/core/brain.gd). The player model is read-only here.
var brain := SnakeBrain.new()
var highest_cleared: int = 0

var chosen_level: int = 1
var preset_mistake_chance: float = 0.5
var preset_safety_weight: float = 0.0
var preset_aggression_weight: float = 0.0

# Game rules (see scripts/core/arena.gd). TOP = preset rival, BOTTOM = trained snake.
var arena := SnakeArena.new(PHASE2_DURATION, false)

var match_over: bool = false
var match_running: bool = false

var move_timer: Timer

# --- UI: level picker ---
var picker_canvas: CanvasLayer
var level_value_label: Label
var level_tier_label: Label
var highest_label: Label
var level_slider: HSlider
var start_button: Button

# --- UI: game / result ---
var game_canvas: CanvasLayer
var score_label: Label
var ai_level_label: Label
var timer_label: Label
var message_label: Label
var replay_button: Button
var change_level_button: Button
var menu_button: Button


func _ready() -> void:
	randomize()
	brain.load_brain()
	brain.load_player_model()
	_load_ladder_progress()
	_setup_picker_ui()
	_setup_game_ui()

	move_timer = Timer.new()
	move_timer.one_shot = false
	move_timer.wait_time = MOVE_INTERVAL
	add_child(move_timer)
	move_timer.timeout.connect(_on_move_timer_timeout)

	_show_picker()


# ---------------------------------------------------------------------------
# Picker UI
# ---------------------------------------------------------------------------

func _setup_picker_ui() -> void:
	picker_canvas = CanvasLayer.new()
	add_child(picker_canvas)

	var width := float(CELL_SIZE * GRID_WIDTH)

	var title := Label.new()
	title.text = "TEKLI OYUN"
	title.add_theme_font_size_override("font_size", 34)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size = Vector2(width, 48)
	title.position = Vector2(0, 80)
	picker_canvas.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Egittigin yilani hazir AI'lara karsi test et.\nBir seviyeyi yenmeden bir sonrakine gecemezsin."
	subtitle.add_theme_font_size_override("font_size", 15)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.size = Vector2(width, 50)
	subtitle.position = Vector2(0, 130)
	picker_canvas.add_child(subtitle)

	highest_label = Label.new()
	highest_label.add_theme_font_size_override("font_size", 16)
	highest_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	highest_label.size = Vector2(width, 24)
	highest_label.position = Vector2(0, 190)
	picker_canvas.add_child(highest_label)

	level_value_label = Label.new()
	level_value_label.add_theme_font_size_override("font_size", 30)
	level_value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_value_label.size = Vector2(width, 42)
	level_value_label.position = Vector2(0, 250)
	picker_canvas.add_child(level_value_label)

	level_tier_label = Label.new()
	level_tier_label.add_theme_font_size_override("font_size", 18)
	level_tier_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level_tier_label.size = Vector2(width, 28)
	level_tier_label.position = Vector2(0, 292)
	picker_canvas.add_child(level_tier_label)

	level_slider = HSlider.new()
	level_slider.min_value = 1
	level_slider.max_value = 1
	level_slider.step = 1
	level_slider.value = 1
	level_slider.custom_minimum_size = Vector2(width - 64, 24)
	level_slider.position = Vector2(32, 340)
	level_slider.value_changed.connect(_on_level_slider_changed)
	picker_canvas.add_child(level_slider)

	start_button = Button.new()
	start_button.text = "Baslat"
	start_button.custom_minimum_size = Vector2(180, 56)
	start_button.position = Vector2(width / 2.0 - 90, 400)
	start_button.pressed.connect(_on_start_pressed)
	picker_canvas.add_child(start_button)

	var back_button := Button.new()
	back_button.text = "Ana Menu"
	back_button.custom_minimum_size = Vector2(180, 56)
	back_button.position = Vector2(width / 2.0 - 90, 470)
	back_button.pressed.connect(_on_menu_pressed)
	picker_canvas.add_child(back_button)


func _on_level_slider_changed(value: float) -> void:
	chosen_level = int(value)
	level_value_label.text = "Seviye %d" % chosen_level
	level_tier_label.text = _level_tier_name(chosen_level)


func _show_picker() -> void:
	match_running = false
	match_over = false
	move_timer.stop()
	game_canvas.visible = false
	picker_canvas.visible = true

	var max_unlocked: int = min(100, highest_cleared + 1)
	level_slider.max_value = max_unlocked
	chosen_level = max_unlocked
	level_slider.value = chosen_level
	highest_label.text = "En Yuksek Yenilen Seviye: %d   (Acik: 1-%d)" % [highest_cleared, max_unlocked]
	_on_level_slider_changed(float(chosen_level))


func _on_start_pressed() -> void:
	picker_canvas.visible = false
	game_canvas.visible = true
	var params: Dictionary = _level_params(chosen_level)
	preset_mistake_chance = params["mistake"]
	preset_safety_weight = params["safety"]
	preset_aggression_weight = params["aggression"]
	_start_match()


func _level_params(level: int) -> Dictionary:
	var t: float = float(level - 1) / 99.0
	var mistake: float = lerp(0.55, 0.0, t)
	var safety: float = lerp(0.0, 1.0, t)
	var aggro_t: float = clamp(float(level - 25) / 75.0, 0.0, 1.0)
	var aggression: float = lerp(0.0, 1.0, aggro_t)
	return {"mistake": mistake, "safety": safety, "aggression": aggression}


func _level_tier_name(level: int) -> String:
	if level <= 20:
		return "Cok Kolay"
	elif level <= 40:
		return "Kolay"
	elif level <= 60:
		return "Orta"
	elif level <= 80:
		return "Zor"
	else:
		return "Cok Zor"


# ---------------------------------------------------------------------------
# Game UI
# ---------------------------------------------------------------------------

func _setup_game_ui() -> void:
	game_canvas = CanvasLayer.new()
	game_canvas.visible = false
	add_child(game_canvas)

	var width := float(CELL_SIZE * GRID_WIDTH)
	var height := float(CELL_SIZE * GRID_HEIGHT)

	score_label = Label.new()
	score_label.add_theme_font_size_override("font_size", 22)
	score_label.position = Vector2(16, 8)
	game_canvas.add_child(score_label)

	ai_level_label = Label.new()
	ai_level_label.add_theme_font_size_override("font_size", 15)
	ai_level_label.position = Vector2(16, 34)
	game_canvas.add_child(ai_level_label)

	timer_label = Label.new()
	timer_label.add_theme_font_size_override("font_size", 20)
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.size = Vector2(width, 28)
	timer_label.position = Vector2(0, 8)
	game_canvas.add_child(timer_label)

	message_label = Label.new()
	message_label.add_theme_font_size_override("font_size", 22)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.visible = false
	message_label.size = Vector2(width, 130)
	message_label.position = Vector2(0, height / 2.0 - 140)
	game_canvas.add_child(message_label)

	replay_button = Button.new()
	replay_button.text = "Tekrar Oyna"
	replay_button.visible = false
	replay_button.custom_minimum_size = Vector2(180, 56)
	replay_button.position = Vector2(width / 2.0 - 90, height / 2.0 - 10)
	replay_button.pressed.connect(_start_match)
	game_canvas.add_child(replay_button)

	change_level_button = Button.new()
	change_level_button.text = "Seviye Degistir"
	change_level_button.visible = false
	change_level_button.custom_minimum_size = Vector2(180, 56)
	change_level_button.position = Vector2(width / 2.0 - 90, height / 2.0 + 56)
	change_level_button.pressed.connect(_show_picker)
	game_canvas.add_child(change_level_button)

	menu_button = Button.new()
	menu_button.text = "Ana Menu"
	menu_button.visible = false
	menu_button.custom_minimum_size = Vector2(180, 56)
	menu_button.position = Vector2(width / 2.0 - 90, height / 2.0 + 122)
	menu_button.pressed.connect(_on_menu_pressed)
	game_canvas.add_child(menu_button)


# ---------------------------------------------------------------------------
# Match lifecycle
# ---------------------------------------------------------------------------

func _start_match() -> void:
	match_over = false
	match_running = true
	arena.reset()

	move_timer.wait_time = MOVE_INTERVAL
	move_timer.start()

	message_label.visible = false
	replay_button.visible = false
	change_level_button.visible = false
	menu_button.visible = false

	_update_score_label()
	_update_ai_level_label()
	_update_timer_label()
	queue_redraw()


func _process(delta: float) -> void:
	if not match_running or match_over:
		return
	var event := arena.advance_time(delta)
	if event == SnakeArena.TimeEvent.BARRIER_OPENED:
		queue_redraw()
	elif event == SnakeArena.TimeEvent.TIME_UP:
		_time_up()
	_update_timer_label()


# ---------------------------------------------------------------------------
# Preset ladder AI: deterministic, difficulty scales with the chosen level.
# ---------------------------------------------------------------------------

func _flood_fill_count(start: Vector2i, own_body: Array, other_body: Array) -> int:
	var visited := {}
	visited[start] = true
	var queue: Array = [start]
	var count := 0
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		count += 1
		for d in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var np: Vector2i = cur + d
			if visited.has(np):
				continue
			if arena.is_blocked(np, own_body, other_body):
				continue
			visited[np] = true
			queue.append(np)
	return count


func _preset_decide() -> int:
	var head: Vector2i = arena.snake_top[0]
	var target: Vector2i = arena.target_for(SnakeArena.Side.TOP)
	var opp_head: Vector2i = arena.snake_bottom[0]

	var candidates: Array = []
	for a in [0, 1, 2]:
		var d: int = SnakeArena.relative_to_direction(a, arena.direction_top)
		var np: Vector2i = head + SnakeArena.dir_vector(d)
		if not arena.is_blocked(np, arena.snake_top, arena.snake_bottom):
			candidates.append({"action": a, "pos": np})

	if candidates.is_empty():
		return 0

	if randf() < preset_mistake_chance:
		var pick = candidates[randi() % candidates.size()]
		return pick["action"]

	var best_action: int = candidates[0]["action"]
	var best_score := -INF
	for c in candidates:
		var np: Vector2i = c["pos"]
		var food_dist: int = abs(np.x - target.x) + abs(np.y - target.y)
		var s: float = -float(food_dist)
		if preset_safety_weight > 0.0:
			var space: int = _flood_fill_count(np, arena.snake_top, arena.snake_bottom)
			s += preset_safety_weight * float(space) * 0.15
		if preset_aggression_weight > 0.0 and arena.phase == 2:
			var opp_dist: int = abs(np.x - opp_head.x) + abs(np.y - opp_head.y)
			s += preset_aggression_weight * (-float(opp_dist)) * 0.5
		if s > best_score:
			best_score = s
			best_action = c["action"]
	return best_action


# ---------------------------------------------------------------------------
# Tick: both snakes are AI-controlled.
# ---------------------------------------------------------------------------

func _on_move_timer_timeout() -> void:
	if match_over:
		return

	var target_trained: Vector2i = arena.target_for(SnakeArena.Side.BOTTOM)
	var old_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.BOTTOM), target_trained)

	var state := arena.compute_state(SnakeArena.Side.BOTTOM)
	var action := brain.select_action(state)
	var new_direction_trained := SnakeArena.relative_to_direction(action, arena.direction_bottom)

	var preset_action := _preset_decide()
	var new_direction_preset := SnakeArena.relative_to_direction(preset_action, arena.direction_top)

	var result := arena.step(new_direction_preset, new_direction_trained)
	var trained_crashed: bool = result["bottom_crashed"]
	var preset_crashed: bool = result["top_crashed"]

	if trained_crashed or preset_crashed:
		var terminal_reward: float = brain.terminal_reward(trained_crashed)
		brain.update_q(state, action, terminal_reward, "", true)
		_finish_round(trained_crashed, preset_crashed)
		return

	var new_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.BOTTOM), target_trained)
	var reward: float = brain.step_reward(result["bottom_ate"], old_dist, new_dist)

	var next_state := arena.compute_state(SnakeArena.Side.BOTTOM)
	brain.update_q(state, action, reward, next_state, false)

	_update_score_label()
	queue_redraw()


func _finish_round(trained_crashed: bool, preset_crashed: bool) -> void:
	var text := ""
	var trained_won := false
	if trained_crashed and preset_crashed:
		if arena.score_bottom == arena.score_top:
			text = "Carpisma - Berabere!"
		elif arena.score_bottom > arena.score_top:
			text = "Carpisma - Yilanin Kazandi (skorla)!"
			trained_won = true
		else:
			text = "Carpisma - Yilanin Kaybetti (skorla)!"
	elif preset_crashed:
		text = "Yilanin Kazandi! Rakip carpti."
		trained_won = true
	else:
		text = "Yilanin Kaybetti!"
	_end_match(text, trained_won)


func _time_up() -> void:
	var text := ""
	var trained_won := false
	if arena.score_bottom == arena.score_top:
		text = "Sure Doldu - Berabere!"
	elif arena.score_bottom > arena.score_top:
		text = "Sure Doldu - Yilanin Kazandi!"
		trained_won = true
	else:
		text = "Sure Doldu - Yilanin Kaybetti!"
	_end_match(text, trained_won)


func _end_match(result_text: String, trained_won: bool) -> void:
	match_over = true
	match_running = false
	move_timer.stop()

	brain.finish_match()
	brain.save_brain()
	_update_ai_level_label()

	if trained_won and chosen_level > highest_cleared:
		highest_cleared = chosen_level
		_save_ladder_progress()

	message_label.text = "%s\nSeviye %d\nYilanin: %d   Rakip: %d" % [result_text, chosen_level, arena.score_bottom, arena.score_top]
	message_label.visible = true
	replay_button.visible = true
	change_level_button.visible = true
	menu_button.visible = true


func _update_score_label() -> void:
	score_label.text = "Yilanin: %d   Rakip: %d" % [arena.score_bottom, arena.score_top]


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
	ai_level_label.text = "Senin AI: %s (%d mac)  |  Seviye %d: %s" % [_ai_tier_name(), brain.games_played, chosen_level, _level_tier_name(chosen_level)]


func _update_timer_label() -> void:
	if arena.phase == 1:
		var remaining := int(ceil(SnakeArena.PHASE1_DURATION - arena.elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Hazirlik: %ds" % remaining
	else:
		var remaining := int(ceil(SnakeArena.PHASE1_DURATION + PHASE2_DURATION - arena.elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Acik Saha: %ds" % remaining


func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	if not match_running:
		return

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


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

func _load_ladder_progress() -> void:
	if FileAccess.file_exists(LADDER_PATH):
		var f := FileAccess.open(LADDER_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(data) == TYPE_DICTIONARY and data.has("highest_cleared"):
				highest_cleared = int(data["highest_cleared"])


func _save_ladder_progress() -> void:
	var f := FileAccess.open(LADDER_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"highest_cleared": highest_cleared}))
		f.close()
