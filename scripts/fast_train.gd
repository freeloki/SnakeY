extends Node2D

# Hizli Antrenman: kullanicinin egittigi yilan, hazir seviye rakiplerine karsi
# arka arkaya cok sayida mac oynar (elle oynamaya gerek yok). Amac, ai_brain.json'a
# kaydedilen Q-table'in cok daha kisa surede cok daha fazla deneyimle buyumesi.
# Grid/Q-learning semasi scripts/single_player.gd ile birebir ayni (ayni beyni
# paylasiyorlar).

const CELL_SIZE := 32
const GRID_WIDTH := SnakeArena.GRID_WIDTH
const GRID_HEIGHT := SnakeArena.GRID_HEIGHT
const BARRIER_ROW := SnakeArena.BARRIER_ROW
const PHASE2_DURATION := 30.0
const MOVE_INTERVAL := 0.14
const TURBO_TICKS_PER_FRAME := 15

const LADDER_PATH := "user://ladder_progress.json"

# Shared Q-learning brain (see scripts/core/brain.gd). The player model is read-only here.
var brain := SnakeBrain.new()
var highest_cleared: int = 0

var current_level: int = 1
var preset_params: Dictionary = {"mistake": 0.5, "safety": 0.0, "aggression": 0.0}

# Game rules (see scripts/core/arena.gd). TOP = preset rival, BOTTOM = trained snake.
var arena := SnakeArena.new(PHASE2_DURATION, false)

var match_over: bool = false

# --- Session state ---
var session_running: bool = false
var session_target: int = 100
var session_matches_done: int = 0
var session_wins: int = 0
var turbo: bool = true

# --- UI: setup ---
var setup_canvas: CanvasLayer
var setup_level_label: Label
var setup_count_label: Label
var count_slider: HSlider
var speed_button: Button
var start_session_button: Button

# --- UI: session / board ---
var game_canvas: CanvasLayer
var session_label: Label
var level_label: Label
var timer_label: Label
var message_label: Label
var stop_button: Button
var restart_button: Button
var settings_button: Button
var menu_button: Button


func _ready() -> void:
	randomize()
	brain.load_brain()
	brain.load_player_model()
	_load_ladder_progress()
	_setup_setup_ui()
	_setup_game_ui()
	_show_setup()


# ---------------------------------------------------------------------------
# Setup UI
# ---------------------------------------------------------------------------

func _setup_setup_ui() -> void:
	setup_canvas = CanvasLayer.new()
	add_child(setup_canvas)

	var width := float(CELL_SIZE * GRID_WIDTH)

	var title := Label.new()
	title.text = "HIZLI ANTRENMAN"
	title.add_theme_font_size_override("font_size", 30)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size = Vector2(width, 44)
	title.position = Vector2(0, 64)
	setup_canvas.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "AI, sen izlerken kendi kendine art arda mac oynar.\nSu an takildigin seviyeye karsi otomatik antrenman yapar."
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.size = Vector2(width, 50)
	subtitle.position = Vector2(0, 112)
	setup_canvas.add_child(subtitle)

	setup_level_label = Label.new()
	setup_level_label.add_theme_font_size_override("font_size", 16)
	setup_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	setup_level_label.size = Vector2(width, 24)
	setup_level_label.position = Vector2(0, 176)
	setup_canvas.add_child(setup_level_label)

	var count_title := Label.new()
	count_title.text = "Mac Sayisi"
	count_title.add_theme_font_size_override("font_size", 15)
	count_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	count_title.size = Vector2(width, 20)
	count_title.position = Vector2(0, 226)
	setup_canvas.add_child(count_title)

	setup_count_label = Label.new()
	setup_count_label.add_theme_font_size_override("font_size", 26)
	setup_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	setup_count_label.size = Vector2(width, 36)
	setup_count_label.position = Vector2(0, 250)
	setup_canvas.add_child(setup_count_label)

	count_slider = HSlider.new()
	count_slider.min_value = 10
	count_slider.max_value = 500
	count_slider.step = 10
	count_slider.value = 100
	count_slider.custom_minimum_size = Vector2(width - 64, 24)
	count_slider.position = Vector2(32, 292)
	count_slider.value_changed.connect(_on_count_slider_changed)
	setup_canvas.add_child(count_slider)

	speed_button = Button.new()
	speed_button.custom_minimum_size = Vector2(220, 48)
	speed_button.position = Vector2(width / 2.0 - 110, 336)
	speed_button.pressed.connect(_on_speed_button_pressed)
	setup_canvas.add_child(speed_button)

	start_session_button = Button.new()
	start_session_button.text = "Baslat"
	start_session_button.custom_minimum_size = Vector2(180, 56)
	start_session_button.position = Vector2(width / 2.0 - 90, 400)
	start_session_button.pressed.connect(_on_start_session_pressed)
	setup_canvas.add_child(start_session_button)

	var back_button := Button.new()
	back_button.text = "Ana Menu"
	back_button.custom_minimum_size = Vector2(180, 56)
	back_button.position = Vector2(width / 2.0 - 90, 470)
	back_button.pressed.connect(_on_menu_pressed)
	setup_canvas.add_child(back_button)

	_on_count_slider_changed(count_slider.value)
	_update_speed_button()


func _on_count_slider_changed(value: float) -> void:
	session_target = int(value)
	setup_count_label.text = "%d mac" % session_target


func _on_speed_button_pressed() -> void:
	turbo = not turbo
	_update_speed_button()


func _update_speed_button() -> void:
	speed_button.text = "Hiz: Turbo (cok hizli)" if turbo else "Hiz: Normal (izlenebilir)"


func _show_setup() -> void:
	session_running = false
	match_over = false
	game_canvas.visible = false
	setup_canvas.visible = true

	var frontier: int = min(100, highest_cleared + 1)
	setup_level_label.text = "Su anki hedef: Seviye %d (%s)   |   En yuksek gecilen: %d" % [frontier, PresetAI.level_tier_name(frontier), highest_cleared]


func _on_start_session_pressed() -> void:
	setup_canvas.visible = false
	game_canvas.visible = true

	current_level = min(100, highest_cleared + 1)
	_apply_level_params()

	session_running = true
	session_matches_done = 0
	session_wins = 0

	message_label.visible = false
	restart_button.visible = false
	settings_button.visible = false
	menu_button.visible = false
	stop_button.visible = true

	_start_match()
	_update_session_label()


func _apply_level_params() -> void:
	preset_params = PresetAI.level_params(current_level)


# ---------------------------------------------------------------------------
# Game / session UI
# ---------------------------------------------------------------------------

func _setup_game_ui() -> void:
	game_canvas = CanvasLayer.new()
	game_canvas.visible = false
	add_child(game_canvas)

	var width := float(CELL_SIZE * GRID_WIDTH)
	var height := float(CELL_SIZE * GRID_HEIGHT)

	session_label = Label.new()
	session_label.add_theme_font_size_override("font_size", 18)
	session_label.position = Vector2(16, 8)
	game_canvas.add_child(session_label)

	level_label = Label.new()
	level_label.add_theme_font_size_override("font_size", 15)
	level_label.position = Vector2(16, 32)
	game_canvas.add_child(level_label)

	timer_label = Label.new()
	timer_label.add_theme_font_size_override("font_size", 18)
	timer_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	timer_label.size = Vector2(width, 24)
	timer_label.position = Vector2(0, 8)
	game_canvas.add_child(timer_label)

	stop_button = Button.new()
	stop_button.text = "Durdur"
	stop_button.visible = false
	stop_button.custom_minimum_size = Vector2(120, 40)
	stop_button.position = Vector2(width - 132, 4)
	stop_button.pressed.connect(_on_stop_pressed)
	game_canvas.add_child(stop_button)

	message_label = Label.new()
	message_label.add_theme_font_size_override("font_size", 20)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.visible = false
	message_label.size = Vector2(width, 130)
	message_label.position = Vector2(0, height / 2.0 - 150)
	game_canvas.add_child(message_label)

	restart_button = Button.new()
	restart_button.text = "Tekrar Baslat"
	restart_button.visible = false
	restart_button.custom_minimum_size = Vector2(180, 56)
	restart_button.position = Vector2(width / 2.0 - 90, height / 2.0 - 10)
	restart_button.pressed.connect(_on_start_session_pressed)
	game_canvas.add_child(restart_button)

	settings_button = Button.new()
	settings_button.text = "Ayarlar"
	settings_button.visible = false
	settings_button.custom_minimum_size = Vector2(180, 56)
	settings_button.position = Vector2(width / 2.0 - 90, height / 2.0 + 56)
	settings_button.pressed.connect(_show_setup)
	game_canvas.add_child(settings_button)

	menu_button = Button.new()
	menu_button.text = "Ana Menu"
	menu_button.visible = false
	menu_button.custom_minimum_size = Vector2(180, 56)
	menu_button.position = Vector2(width / 2.0 - 90, height / 2.0 + 122)
	menu_button.pressed.connect(_on_menu_pressed)
	game_canvas.add_child(menu_button)


func _on_stop_pressed() -> void:
	_stop_session()


func _stop_session() -> void:
	if not session_running:
		return
	session_running = false
	brain.save_brain()

	stop_button.visible = false
	message_label.text = "Oturum durduruldu.\n%d/%d mac oynandi, %d galibiyet." % [session_matches_done, session_target, session_wins]
	message_label.visible = true
	restart_button.visible = true
	settings_button.visible = true
	menu_button.visible = true


# ---------------------------------------------------------------------------
# Match lifecycle (auto-restarts within a session, no user input needed)
# ---------------------------------------------------------------------------

func _start_match() -> void:
	match_over = false
	arena.reset()

	_update_level_label()
	_update_timer_label()
	queue_redraw()


func _process(_delta: float) -> void:
	if not session_running:
		return

	if turbo:
		for i in range(TURBO_TICKS_PER_FRAME):
			if not session_running:
				break
			_tick_once()
	else:
		_tick_once()

	if session_running:
		queue_redraw()
		_update_timer_label()


func _tick_once() -> void:
	if match_over:
		return

	var event := arena.advance_time(MOVE_INTERVAL)
	if event == SnakeArena.TimeEvent.TIME_UP:
		_time_up_session()
		return

	var target_trained: Vector2i = arena.target_for(SnakeArena.Side.BOTTOM)
	var old_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.BOTTOM), target_trained)

	var state := arena.compute_state(SnakeArena.Side.BOTTOM)
	var action := brain.select_action(state)
	var new_direction_trained := SnakeArena.relative_to_direction(action, arena.direction_bottom)

	var preset_action := PresetAI.decide(arena, SnakeArena.Side.TOP, preset_params)
	var new_direction_preset := SnakeArena.relative_to_direction(preset_action, arena.direction_top)

	var result := arena.step(new_direction_preset, new_direction_trained)
	var trained_crashed: bool = result["bottom_crashed"]
	var preset_crashed: bool = result["top_crashed"]

	if trained_crashed or preset_crashed:
		var terminal_reward: float = brain.terminal_reward(trained_crashed)
		brain.update_q(state, action, terminal_reward, "", true)
		_resolve_match_end(trained_crashed, preset_crashed)
		return

	var new_dist: int = SnakeArena.distance(arena.head_of(SnakeArena.Side.BOTTOM), target_trained)
	var reward: float = brain.step_reward(result["bottom_ate"], old_dist, new_dist)

	var next_state := arena.compute_state(SnakeArena.Side.BOTTOM)
	brain.update_q(state, action, reward, next_state, false)


func _resolve_match_end(trained_crashed: bool, preset_crashed: bool) -> void:
	match_over = true
	var trained_won := false
	if trained_crashed and preset_crashed:
		trained_won = arena.score_bottom > arena.score_top
	elif preset_crashed:
		trained_won = true
	else:
		trained_won = false
	_after_match(trained_won)


func _time_up_session() -> void:
	match_over = true
	var trained_won: bool = arena.score_bottom > arena.score_top
	_after_match(trained_won)


func _after_match(trained_won: bool) -> void:
	session_matches_done += 1
	if trained_won:
		session_wins += 1

	brain.finish_match()

	if trained_won and current_level > highest_cleared:
		highest_cleared = current_level
		_save_ladder_progress()
		current_level = min(100, highest_cleared + 1)
		_apply_level_params()

	if session_matches_done % 10 == 0:
		brain.save_brain()

	_update_session_label()
	_update_level_label()

	if not session_running:
		return

	if session_matches_done >= session_target:
		session_running = false
		brain.save_brain()
		stop_button.visible = false
		message_label.text = "Oturum bitti!\n%d mac, %d galibiyet (%%%.0f)\nUlasilan en yuksek seviye: %d" % [session_matches_done, session_wins, 100.0 * float(session_wins) / float(max(session_matches_done, 1)), highest_cleared]
		message_label.visible = true
		restart_button.visible = true
		settings_button.visible = true
		menu_button.visible = true
	else:
		_start_match()


func _update_session_label() -> void:
	var pct: float = 0.0
	if session_matches_done > 0:
		pct = 100.0 * float(session_wins) / float(session_matches_done)
	session_label.text = "Mac: %d/%d   Galibiyet: %d (%%%.0f)" % [session_matches_done, session_target, session_wins, pct]


func _update_level_label() -> void:
	level_label.text = "Seviye %d: %s   |   Yilanin: %d  Rakip: %d" % [current_level, PresetAI.level_tier_name(current_level), arena.score_bottom, arena.score_top]


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
	session_running = false
	brain.save_brain()
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

func _draw() -> void:
	if not game_canvas.visible:
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
# Persistence (identical scheme to scripts/single_player.gd)
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


