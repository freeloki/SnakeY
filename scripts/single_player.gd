extends Node2D

# --- Grid / timing (mirrors scripts/main.gd) ---
const CELL_SIZE := 32
const GRID_WIDTH := 15
const HALF_HEIGHT := 11
const BARRIER_ROW := HALF_HEIGHT
const GRID_HEIGHT := HALF_HEIGHT * 2 + 1
const PHASE1_DURATION := 5.0
const PHASE2_DURATION := 30.0
const MOVE_INTERVAL := 0.14

enum Dir { UP, DOWN, LEFT, RIGHT }
const CYCLE := [Dir.UP, Dir.RIGHT, Dir.DOWN, Dir.LEFT]

# --- Q-learning brain for the user's trained snake. Same file/format as
# scripts/main.gd so the brain is shared and keeps learning in both modes. ---
const AI_BRAIN_PATH := "user://ai_brain.json"
const ALPHA := 0.2
const GAMMA := 0.9
const EPSILON_START := 0.35
const EPSILON_MIN := 0.06
const EPSILON_DECAY := 0.992

# Reward shaping - kept identical to scripts/main.gd so the shared brain
# learns the same values regardless of which mode is training it.
const AI_DEATH_REWARD := -60.0
const AI_WIN_REWARD := 60.0
const AI_FOOD_REWARD := 15.0
const AI_STEP_PENALTY := -0.05
const AI_SHAPING_BONUS := 0.15
const AI_SHAPING_PENALTY := -0.15

# Imitation learning: read-only here (no live player in this mode), but the
# trained snake still leans on what the player demonstrated in Antrenman mode.
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

var chosen_level: int = 1
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
	_load_ai_brain()
	_load_player_model()
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
	elapsed += delta
	if phase == 1 and elapsed >= PHASE1_DURATION:
		_open_barrier()
	elif phase == 2 and elapsed >= PHASE1_DURATION + PHASE2_DURATION:
		_time_up()
	_update_timer_label()


func _open_barrier() -> void:
	phase = 2
	food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_trained + snake_preset)
	queue_redraw()


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
# Trained snake: same Q-learning state/action scheme as scripts/main.gd
# (bit layout must match exactly - the two scripts share one q_table file).
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
# Tick: both snakes are AI-controlled.
# ---------------------------------------------------------------------------

func _on_move_timer_timeout() -> void:
	if match_over:
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
		_finish_round(trained_crashed, preset_crashed)
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

	_update_score_label()
	queue_redraw()


func _finish_round(trained_crashed: bool, preset_crashed: bool) -> void:
	var text := ""
	var trained_won := false
	if trained_crashed and preset_crashed:
		if score_trained == score_preset:
			text = "Carpisma - Berabere!"
		elif score_trained > score_preset:
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
	if score_trained == score_preset:
		text = "Sure Doldu - Berabere!"
	elif score_trained > score_preset:
		text = "Sure Doldu - Yilanin Kazandi!"
		trained_won = true
	else:
		text = "Sure Doldu - Yilanin Kaybetti!"
	_end_match(text, trained_won)


func _end_match(result_text: String, trained_won: bool) -> void:
	match_over = true
	match_running = false
	move_timer.stop()

	games_played += 1
	_update_epsilon()
	_update_imitation_weight()
	_save_ai_brain()
	_update_ai_level_label()

	if trained_won and chosen_level > highest_cleared:
		highest_cleared = chosen_level
		_save_ladder_progress()

	message_label.text = "%s\nSeviye %d\nYilanin: %d   Rakip: %d" % [result_text, chosen_level, score_trained, score_preset]
	message_label.visible = true
	replay_button.visible = true
	change_level_button.visible = true
	menu_button.visible = true


func _update_score_label() -> void:
	score_label.text = "Yilanin: %d   Rakip: %d" % [score_trained, score_preset]


func _ai_tier_name() -> String:
	if games_played < 5:
		return "Acemi"
	elif games_played < 15:
		return "Gelisiyor"
	elif games_played < 40:
		return "Deneyimli"
	else:
		return "Usta"


func _update_ai_level_label() -> void:
	ai_level_label.text = "Senin AI: %s (%d mac)  |  Seviye %d: %s" % [_ai_tier_name(), games_played, chosen_level, _level_tier_name(chosen_level)]


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
# Persistence
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
