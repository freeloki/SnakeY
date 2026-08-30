extends Node2D

# Hizli Antrenman: kullanicinin egittigi yilan, hazir seviye rakiplerine karsi
# arka arkaya cok sayida mac oynar (elle oynamaya gerek yok). Amac, ai_brain.json'a
# kaydedilen Q-table'in cok daha kisa surede cok daha fazla deneyimle buyumesi.
# Grid/Q-learning semasi scripts/single_player.gd ile birebir ayni (ayni beyni
# paylasiyorlar).

const CELL_SIZE := 32
const GRID_WIDTH := 15
const HALF_HEIGHT := 11
const BARRIER_ROW := HALF_HEIGHT
const GRID_HEIGHT := HALF_HEIGHT * 2 + 1
const PHASE1_DURATION := 5.0
const PHASE2_DURATION := 30.0
const MOVE_INTERVAL := 0.14
const TURBO_TICKS_PER_FRAME := 15

enum Dir { UP, DOWN, LEFT, RIGHT }
const CYCLE := [Dir.UP, Dir.RIGHT, Dir.DOWN, Dir.LEFT]

# --- Q-learning brain: ayni dosya/format, scripts/main.gd ve
# scripts/single_player.gd ile paylasiliyor. ---
const AI_BRAIN_PATH := "user://ai_brain.json"
const ALPHA := 0.2
const GAMMA := 0.9
const EPSILON_START := 0.35
const EPSILON_MIN := 0.06
const EPSILON_DECAY := 0.992

const AI_DEATH_REWARD := -60.0
const AI_WIN_REWARD := 60.0
const AI_FOOD_REWARD := 15.0
const AI_STEP_PENALTY := -0.05
const AI_SHAPING_BONUS := 0.15
const AI_SHAPING_PENALTY := -0.15

const PLAYER_MODEL_PATH := "user://player_model.json"
const IMITATION_WEIGHT_START := 1.0
const IMITATION_DECAY := 0.994
const IMITATION_SCALE := 35.0

const LADDER_PATH := "user://ladder_progress.json"

var q_table: Dictionary = {}
var games_played: int = 0
var epsilon: float = EPSILON_START
var player_model: Dictionary = {}
var imitation_weight: float = IMITATION_WEIGHT_START
var highest_cleared: int = 0

var current_level: int = 1
var preset_mistake_chance: float = 0.5
var preset_safety_weight: float = 0.0
var preset_aggression_weight: float = 0.0

var snake_trained: Array = []
var snake_preset: Array = []
var direction_trained: int = Dir.RIGHT
var direction_preset: int = Dir.RIGHT

var food_top: Vector2i
var food_bottom: Vector2i
var food_shared: Vector2i

var score_trained: int = 0
var score_preset: int = 0

var phase: int = 1
var elapsed: float = 0.0
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
	_load_ai_brain()
	_load_player_model()
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
	setup_level_label.text = "Su anki hedef: Seviye %d (%s)   |   En yuksek gecilen: %d" % [frontier, _level_tier_name(frontier), highest_cleared]


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
	var params: Dictionary = _level_params(current_level)
	preset_mistake_chance = params["mistake"]
	preset_safety_weight = params["safety"]
	preset_aggression_weight = params["aggression"]


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
	_save_ai_brain()

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
	phase = 1
	elapsed = 0.0
	score_trained = 0
	score_preset = 0

	direction_trained = Dir.RIGHT
	direction_preset = Dir.RIGHT

	var mid_x := GRID_WIDTH / 2

	snake_preset.clear()
	var preset_row := HALF_HEIGHT / 2
	snake_preset.append(Vector2i(mid_x, preset_row))
	snake_preset.append(Vector2i(mid_x - 1, preset_row))
	snake_preset.append(Vector2i(mid_x - 2, preset_row))

	snake_trained.clear()
	var trained_row := BARRIER_ROW + 1 + HALF_HEIGHT / 2
	snake_trained.append(Vector2i(mid_x, trained_row))
	snake_trained.append(Vector2i(mid_x - 1, trained_row))
	snake_trained.append(Vector2i(mid_x - 2, trained_row))

	food_top = _spawn_food_in_range(0, BARRIER_ROW - 1, snake_preset)
	food_bottom = _spawn_food_in_range(BARRIER_ROW + 1, GRID_HEIGHT - 1, snake_trained)

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

	elapsed += MOVE_INTERVAL
	if phase == 1 and elapsed >= PHASE1_DURATION:
		_open_barrier()
	elif phase == 2 and elapsed >= PHASE1_DURATION + PHASE2_DURATION:
		_time_up_session()
		return

	var target_trained: Vector2i = food_bottom if phase == 1 else food_shared
	var target_preset: Vector2i = food_top if phase == 1 else food_shared
	var trained_head_before: Vector2i = snake_trained[0]
	var old_dist: int = abs(trained_head_before.x - target_trained.x) + abs(trained_head_before.y - target_trained.y)

	var state := _compute_trained_state(target_trained)
	var action := _select_action(state)
	direction_trained = _relative_action_to_direction(action, direction_trained)

	var preset_action := _preset_decide()
	direction_preset = _relative_action_to_direction(preset_action, direction_preset)

	var new_head_trained: Vector2i = snake_trained[0] + _dir_vector(direction_trained)
	var new_head_preset: Vector2i = snake_preset[0] + _dir_vector(direction_preset)

	var trained_crashed := _is_blocked(new_head_trained, snake_trained, snake_preset)
	var preset_crashed := _is_blocked(new_head_preset, snake_preset, snake_trained)

	if new_head_trained == new_head_preset:
		trained_crashed = true
		preset_crashed = true
	else:
		if snake_preset.has(new_head_trained):
			trained_crashed = true
		if snake_trained.has(new_head_preset):
			preset_crashed = true

	if trained_crashed or preset_crashed:
		var terminal_reward: float = AI_DEATH_REWARD if trained_crashed else AI_WIN_REWARD
		_update_q(state, action, terminal_reward, "", true)
		_resolve_match_end(trained_crashed, preset_crashed)
		return

	snake_preset.insert(0, new_head_preset)
	if new_head_preset == target_preset:
		score_preset += 1
		if phase == 1:
			food_top = _spawn_food_in_range(0, BARRIER_ROW - 1, snake_preset)
		else:
			food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_trained + snake_preset)
	else:
		snake_preset.pop_back()

	var trained_ate: bool = new_head_trained == target_trained
	snake_trained.insert(0, new_head_trained)
	if trained_ate:
		score_trained += 1
		if phase == 1:
			food_bottom = _spawn_food_in_range(BARRIER_ROW + 1, GRID_HEIGHT - 1, snake_trained)
		else:
			food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_trained + snake_preset)
	else:
		snake_trained.pop_back()

	var reward: float
	if trained_ate:
		reward = AI_FOOD_REWARD
	else:
		var new_dist: int = abs(new_head_trained.x - target_trained.x) + abs(new_head_trained.y - target_trained.y)
		reward = AI_STEP_PENALTY
		if new_dist < old_dist:
			reward += AI_SHAPING_BONUS
		else:
			reward += AI_SHAPING_PENALTY

	var next_target: Vector2i = food_bottom if phase == 1 else food_shared
	var next_state := _compute_trained_state(next_target)
	_update_q(state, action, reward, next_state, false)


func _open_barrier() -> void:
	phase = 2
	food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_trained + snake_preset)


func _resolve_match_end(trained_crashed: bool, preset_crashed: bool) -> void:
	match_over = true
	var trained_won := false
	if trained_crashed and preset_crashed:
		trained_won = score_trained > score_preset
	elif preset_crashed:
		trained_won = true
	else:
		trained_won = false
	_after_match(trained_won)


func _time_up_session() -> void:
	match_over = true
	var trained_won: bool = score_trained > score_preset
	_after_match(trained_won)


func _after_match(trained_won: bool) -> void:
	session_matches_done += 1
	if trained_won:
		session_wins += 1

	games_played += 1
	_update_epsilon()
	_update_imitation_weight()

	if trained_won and current_level > highest_cleared:
		highest_cleared = current_level
		_save_ladder_progress()
		current_level = min(100, highest_cleared + 1)
		_apply_level_params()

	if session_matches_done % 10 == 0:
		_save_ai_brain()

	_update_session_label()
	_update_level_label()

	if not session_running:
		return

	if session_matches_done >= session_target:
		session_running = false
		_save_ai_brain()
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
	level_label.text = "Seviye %d: %s   |   Yilanin: %d  Rakip: %d" % [current_level, _level_tier_name(current_level), score_trained, score_preset]


func _update_timer_label() -> void:
	if phase == 1:
		var remaining := int(ceil(PHASE1_DURATION - elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Hazirlik: %ds" % remaining
	else:
		var remaining := int(ceil(PHASE1_DURATION + PHASE2_DURATION - elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Acik Saha: %ds" % remaining


func _on_menu_pressed() -> void:
	session_running = false
	_save_ai_brain()
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


# ---------------------------------------------------------------------------
# Shared grid helpers (mirrors scripts/single_player.gd)
# ---------------------------------------------------------------------------

func _spawn_food_in_range(row_min: int, row_max: int, exclude_cells: Array) -> Vector2i:
	var free_cells: Array = []
	for x in range(GRID_WIDTH):
		for y in range(row_min, row_max + 1):
			var p := Vector2i(x, y)
			if not exclude_cells.has(p):
				free_cells.append(p)
	if free_cells.is_empty():
		return Vector2i(-1, -1)
	return free_cells[randi() % free_cells.size()]


func _dir_vector(d: int) -> Vector2i:
	match d:
		Dir.UP:
			return Vector2i(0, -1)
		Dir.DOWN:
			return Vector2i(0, 1)
		Dir.LEFT:
			return Vector2i(-1, 0)
		Dir.RIGHT:
			return Vector2i(1, 0)
	return Vector2i.ZERO


func _is_blocked(pos: Vector2i, own_body: Array, other_body: Array) -> bool:
	if pos.x < 0 or pos.x >= GRID_WIDTH or pos.y < 0 or pos.y >= GRID_HEIGHT:
		return true
	if phase == 1 and pos.y == BARRIER_ROW:
		return true
	if own_body.has(pos):
		return true
	if phase == 2 and other_body.has(pos):
		return true
	return false


func _relative_action_to_direction(action: int, heading: int) -> int:
	var idx: int = CYCLE.find(heading)
	if action == 0:
		return heading
	elif action == 1:
		return CYCLE[(idx + 3) % 4]
	else:
		return CYCLE[(idx + 1) % 4]


# ---------------------------------------------------------------------------
# Trained snake: identical Q-learning state/action scheme to scripts/main.gd
# and scripts/single_player.gd (bit layout must match - shared q_table file).
# ---------------------------------------------------------------------------

func _danger_for_trained(action: int) -> bool:
	var d: int = _relative_action_to_direction(action, direction_trained)
	var np: Vector2i = snake_trained[0] + _dir_vector(d)
	return _is_blocked(np, snake_trained, snake_preset)


func _compute_trained_state(target: Vector2i) -> String:
	var head: Vector2i = snake_trained[0]
	var opp_head: Vector2i = snake_preset[0]

	var bits := 0
	if _danger_for_trained(0):
		bits |= 1
	if _danger_for_trained(1):
		bits |= 2
	if _danger_for_trained(2):
		bits |= 4
	if target.y < head.y:
		bits |= 8
	if target.y > head.y:
		bits |= 16
	if target.x < head.x:
		bits |= 32
	if target.x > head.x:
		bits |= 64
	if opp_head.y < head.y:
		bits |= 128
	if opp_head.y > head.y:
		bits |= 256
	if opp_head.x < head.x:
		bits |= 512
	if opp_head.x > head.x:
		bits |= 1024
	var opp_dist: int = abs(opp_head.x - head.x) + abs(opp_head.y - head.y)
	if opp_dist <= 5:
		bits |= 2048
	if phase == 2:
		bits |= 4096

	return str(bits) + "_" + str(direction_trained)


func _get_q(state: String) -> Array:
	if q_table.has(state):
		return q_table[state]
	return [0.0, 0.0, 0.0]


func _player_preference(state: String) -> Array:
	if not player_model.has(state):
		return [0.0, 0.0, 0.0]
	var counts: Array = player_model[state]
	var total: float = float(counts[0] + counts[1] + counts[2])
	if total <= 0.0:
		return [0.0, 0.0, 0.0]
	return [counts[0] / total, counts[1] / total, counts[2] / total]


func _select_action(state: String) -> int:
	if randf() < epsilon:
		return randi() % 3
	var q: Array = _get_q(state)
	var pref: Array = _player_preference(state)
	var scores := [
		q[0] + imitation_weight * IMITATION_SCALE * pref[0],
		q[1] + imitation_weight * IMITATION_SCALE * pref[1],
		q[2] + imitation_weight * IMITATION_SCALE * pref[2],
	]
	var best_action := 0
	var best_value: float = scores[0]
	if scores[1] > best_value:
		best_value = scores[1]
		best_action = 1
	if scores[2] > best_value:
		best_value = scores[2]
		best_action = 2
	return best_action


func _update_q(state: String, action: int, reward: float, next_state: String, done: bool) -> void:
	if not q_table.has(state):
		q_table[state] = [0.0, 0.0, 0.0]
	var q: Array = q_table[state]
	var target_value: float = reward
	if not done:
		var next_q: Array = _get_q(next_state)
		var max_next: float = next_q[0]
		if next_q[1] > max_next:
			max_next = next_q[1]
		if next_q[2] > max_next:
			max_next = next_q[2]
		target_value += GAMMA * max_next
	q[action] = q[action] + ALPHA * (target_value - q[action])


# ---------------------------------------------------------------------------
# Preset ladder AI: deterministic, difficulty scales with current_level.
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
			if _is_blocked(np, own_body, other_body):
				continue
			visited[np] = true
			queue.append(np)
	return count


func _preset_decide() -> int:
	var head: Vector2i = snake_preset[0]
	var target: Vector2i = food_top if phase == 1 else food_shared
	var opp_head: Vector2i = snake_trained[0]

	var candidates: Array = []
	for a in [0, 1, 2]:
		var d: int = _relative_action_to_direction(a, direction_preset)
		var np: Vector2i = head + _dir_vector(d)
		if not _is_blocked(np, snake_preset, snake_trained):
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
			var space: int = _flood_fill_count(np, snake_preset, snake_trained)
			s += preset_safety_weight * float(space) * 0.15
		if preset_aggression_weight > 0.0 and phase == 2:
			var opp_dist: int = abs(np.x - opp_head.x) + abs(np.y - opp_head.y)
			s += preset_aggression_weight * (-float(opp_dist)) * 0.5
		if s > best_score:
			best_score = s
			best_action = c["action"]
	return best_action


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

	if phase == 1:
		var barrier_rect := Rect2(0, BARRIER_ROW * CELL_SIZE, GRID_WIDTH * CELL_SIZE, CELL_SIZE)
		draw_rect(barrier_rect, Color(0.55, 0.2, 0.2))
	else:
		var line_y := BARRIER_ROW * CELL_SIZE + CELL_SIZE / 2.0
		var x := 0
		while x < GRID_WIDTH * CELL_SIZE:
			draw_line(Vector2(x, line_y), Vector2(x + CELL_SIZE * 0.6, line_y), Color(0.4, 0.4, 0.4), 2.0)
			x += CELL_SIZE

	if phase == 1:
		_draw_food(food_top)
		_draw_food(food_bottom)
	else:
		_draw_food(food_shared)

	_draw_snake(snake_preset, Color(0.55, 0.75, 1.0), Color(0.3, 0.5, 0.9))
	_draw_snake(snake_trained, Color(0.55, 0.95, 0.6), Color(0.25, 0.7, 0.3))


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

func _update_epsilon() -> void:
	epsilon = clamp(EPSILON_START * pow(EPSILON_DECAY, games_played), EPSILON_MIN, EPSILON_START)


func _update_imitation_weight() -> void:
	imitation_weight = clamp(IMITATION_WEIGHT_START * pow(IMITATION_DECAY, games_played), 0.0, IMITATION_WEIGHT_START)


func _load_ai_brain() -> void:
	if FileAccess.file_exists(AI_BRAIN_PATH):
		var f := FileAccess.open(AI_BRAIN_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(data) == TYPE_DICTIONARY:
				games_played = int(data.get("games_played", 0))
				var raw_table = data.get("q_table", {})
				if typeof(raw_table) == TYPE_DICTIONARY:
					for key in raw_table.keys():
						var arr = raw_table[key]
						var q3 := [0.0, 0.0, 0.0]
						if typeof(arr) == TYPE_ARRAY:
							for i in range(min(3, arr.size())):
								q3[i] = float(arr[i])
						q_table[key] = q3
	_update_epsilon()
	_update_imitation_weight()


func _save_ai_brain() -> void:
	var f := FileAccess.open(AI_BRAIN_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"games_played": games_played, "q_table": q_table}))
		f.close()


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


func _load_player_model() -> void:
	if FileAccess.file_exists(PLAYER_MODEL_PATH):
		var f := FileAccess.open(PLAYER_MODEL_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(data) == TYPE_DICTIONARY:
				for key in data.keys():
					var arr = data[key]
					var c3 := [0, 0, 0]
					if typeof(arr) == TYPE_ARRAY:
						for i in range(min(3, arr.size())):
							c3[i] = int(arr[i])
					player_model[key] = c3
