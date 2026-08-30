extends Node2D

const CELL_SIZE := 32
const GRID_WIDTH := 15
const HALF_HEIGHT := 11
const BARRIER_ROW := HALF_HEIGHT
const GRID_HEIGHT := HALF_HEIGHT * 2 + 1

const PHASE1_DURATION := 5
const PHASE2_DURATION := 10
const MOVE_INTERVAL := 0.14
const SWIPE_THRESHOLD := 24.0
const SAVE_PATH := "user://snakey_save.json"

enum Dir { UP, DOWN, LEFT, RIGHT }

# Clockwise order (screen coords): UP -> RIGHT -> DOWN -> LEFT -> UP
const CYCLE := [Dir.UP, Dir.RIGHT, Dir.DOWN, Dir.LEFT]

# --- AI / reinforcement learning (tabular Q-learning) ---
const AI_BRAIN_PATH := "user://ai_brain.json"
const ALPHA := 0.2           # learning rate (raised: converge faster per sample)
const GAMMA := 0.9           # discount factor
const EPSILON_START := 0.35  # exploration rate for a brand new AI
const EPSILON_MIN := 0.06    # raised: keep exploring longer, avoid locking onto a mediocre policy
const EPSILON_DECAY := 0.992 # per match played (slowed: was decaying to the floor by ~100 games)

# Reward shaping - tuned to reduce over-caution (the old -100/+10 ratio
# pushed the AI toward playing too passively / not chasing food near risk).
const AI_DEATH_REWARD := -60.0
const AI_WIN_REWARD := 60.0
const AI_FOOD_REWARD := 15.0
const AI_STEP_PENALTY := -0.05
const AI_SHAPING_BONUS := 0.15
const AI_SHAPING_PENALTY := -0.15

var q_table: Dictionary = {}
var games_played: int = 0
var epsilon: float = EPSILON_START

# --- Imitation learning: the AI also watches how YOU play and leans on that
# early on (when its own Q-values are still mostly zero), fading out as it
# accumulates its own real experience. ---
const PLAYER_MODEL_PATH := "user://player_model.json"
const IMITATION_WEIGHT_START := 1.0
const IMITATION_DECAY := 0.994  # slowed: stay influential much longer (was fading out by ~150 games)
const IMITATION_SCALE := 35.0   # raised: a stronger nudge while it is active

var player_model: Dictionary = {}
var imitation_weight: float = IMITATION_WEIGHT_START

var snake_player: Array = []
var snake_ai: Array = []
var direction_player: int = Dir.RIGHT
var pending_direction_player: int = Dir.RIGHT
var direction_ai: int = Dir.RIGHT

var food_top: Vector2i
var food_bottom: Vector2i
var food_shared: Vector2i

var score_player: int = 0
var score_ai: int = 0
var best_score: int = 0

var phase: int = 1
var elapsed: float = 0.0
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
	_load_ai_brain()
	_load_player_model()
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
	phase = 1
	elapsed = 0.0
	score_player = 0
	score_ai = 0

	direction_player = Dir.RIGHT
	pending_direction_player = Dir.RIGHT
	direction_ai = Dir.RIGHT

	var mid_x := GRID_WIDTH / 2

	snake_ai.clear()
	var ai_row := HALF_HEIGHT / 2
	snake_ai.append(Vector2i(mid_x, ai_row))
	snake_ai.append(Vector2i(mid_x - 1, ai_row))
	snake_ai.append(Vector2i(mid_x - 2, ai_row))

	snake_player.clear()
	var player_row := BARRIER_ROW + 1 + HALF_HEIGHT / 2
	snake_player.append(Vector2i(mid_x, player_row))
	snake_player.append(Vector2i(mid_x - 1, player_row))
	snake_player.append(Vector2i(mid_x - 2, player_row))

	var initial_food_pair := _spawn_mirrored_food_pair(snake_ai, snake_player)
	food_top = initial_food_pair[0]
	food_bottom = initial_food_pair[1]

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
	elapsed += delta
	if phase == 1 and elapsed >= PHASE1_DURATION:
		_open_barrier()
	elif phase == 2 and elapsed >= PHASE1_DURATION + PHASE2_DURATION:
		_time_up()
	_update_timer_label()


func _open_barrier() -> void:
	phase = 2
	food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_player + snake_ai)
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


func _spawn_mirrored_food_pair(exclude_top: Array, exclude_bottom: Array) -> Array:
	# Faz 1'de yem, ust ve alt yaridaki ayna noktalarinda (ayni sutun, barikata
	# ayni mesafede) birlikte cikar; boylece AI'nin karsilastigi durum oyuncunun
	# az once karsilastigi durumun simetrigi olur ve taklit ogrenme daha
	# anlamli hale gelir.
	var candidates: Array = []
	for x in range(GRID_WIDTH):
		for y in range(0, BARRIER_ROW):
			var top := Vector2i(x, y)
			var bottom := Vector2i(x, 2 * BARRIER_ROW - y)
			if not exclude_top.has(top) and not exclude_bottom.has(bottom):
				candidates.append([top, bottom])
	if candidates.is_empty():
		# Aynali bos hucre bulunamadi (cok nadir) - bagimsiz yerlestirmeye don.
		var fallback_top: Vector2i = _spawn_food_in_range(0, BARRIER_ROW - 1, exclude_top)
		var fallback_bottom: Vector2i = _spawn_food_in_range(BARRIER_ROW + 1, GRID_HEIGHT - 1, exclude_bottom)
		return [fallback_top, fallback_bottom]
	return candidates[randi() % candidates.size()]


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


# ---------------------------------------------------------------------------
# AI: relative actions are 0=straight, 1=turn left, 2=turn right (never a
# reversal, since only these three neighbours exist on the direction cycle).
# ---------------------------------------------------------------------------

func _relative_action_to_direction(action: int, heading: int) -> int:
	var idx: int = CYCLE.find(heading)
	if action == 0:
		return heading
	elif action == 1:
		return CYCLE[(idx + 3) % 4]
	else:
		return CYCLE[(idx + 1) % 4]


func _direction_to_relative_action(new_dir: int, old_dir: int) -> int:
	if new_dir == old_dir:
		return 0
	var idx: int = CYCLE.find(old_dir)
	if new_dir == CYCLE[(idx + 3) % 4]:
		return 1
	return 2


func _danger_for_action(action: int) -> bool:
	var d: int = _relative_action_to_direction(action, direction_ai)
	var np: Vector2i = snake_ai[0] + _dir_vector(d)
	return _is_blocked(np, snake_ai, snake_player)


func _compute_state() -> String:
	var head: Vector2i = snake_ai[0]
	var target: Vector2i = food_top if phase == 1 else food_shared
	var opp_head: Vector2i = snake_player[0]

	var bits := 0
	if _danger_for_action(0):
		bits |= 1
	if _danger_for_action(1):
		bits |= 2
	if _danger_for_action(2):
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

	return str(bits) + "_" + str(direction_ai)


# --- Same state encoding, but computed generically so it can also describe
# the PLAYER's situation (own head/heading/body vs opponent). This lets the
# AI's imitation lookup directly compare "am I in a state the player has
# also been in" using one shared key space. ---

func _danger_for_body(head: Vector2i, heading: int, own_body: Array, other_body: Array, action: int) -> bool:
	var d: int = _relative_action_to_direction(action, heading)
	var np: Vector2i = head + _dir_vector(d)
	return _is_blocked(np, own_body, other_body)


func _compute_player_state(head: Vector2i, heading: int, opp_head: Vector2i, target: Vector2i) -> String:
	var bits := 0
	if _danger_for_body(head, heading, snake_player, snake_ai, 0):
		bits |= 1
	if _danger_for_body(head, heading, snake_player, snake_ai, 1):
		bits |= 2
	if _danger_for_body(head, heading, snake_player, snake_ai, 2):
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
	return str(bits) + "_" + str(heading)


func _record_player_choice(state: String, action: int) -> void:
	if not player_model.has(state):
		player_model[state] = [0, 0, 0]
	var counts: Array = player_model[state]
	counts[action] = counts[action] + 1


func _player_preference(state: String) -> Array:
	if not player_model.has(state):
		return [0.0, 0.0, 0.0]
	var counts: Array = player_model[state]
	var total: float = float(counts[0] + counts[1] + counts[2])
	if total <= 0.0:
		return [0.0, 0.0, 0.0]
	return [counts[0] / total, counts[1] / total, counts[2] / total]


func _get_q(state: String) -> Array:
	if q_table.has(state):
		return q_table[state]
	return [0.0, 0.0, 0.0]


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


func _on_move_timer_timeout() -> void:
	if match_over:
		return

	var player_old_direction: int = direction_player
	var player_head_before: Vector2i = snake_player[0]
	var ai_head_before_for_player_state: Vector2i = snake_ai[0]

	direction_player = pending_direction_player

	var target_ai: Vector2i = food_top if phase == 1 else food_shared
	var target_player: Vector2i = food_bottom if phase == 1 else food_shared

	# Learn from how the player is playing (imitation signal for the AI).
	var player_state := _compute_player_state(player_head_before, player_old_direction, ai_head_before_for_player_state, target_player)
	var player_action := _direction_to_relative_action(direction_player, player_old_direction)
	_record_player_choice(player_state, player_action)

	var ai_head_before: Vector2i = snake_ai[0]
	var old_dist: int = abs(ai_head_before.x - target_ai.x) + abs(ai_head_before.y - target_ai.y)

	var state := _compute_state()
	var action := _select_action(state)
	direction_ai = _relative_action_to_direction(action, direction_ai)

	var new_head_player: Vector2i = snake_player[0] + _dir_vector(direction_player)
	var new_head_ai: Vector2i = snake_ai[0] + _dir_vector(direction_ai)

	var player_crashed := _is_blocked(new_head_player, snake_player, snake_ai)
	var ai_crashed := _is_blocked(new_head_ai, snake_ai, snake_player)

	if new_head_player == new_head_ai:
		player_crashed = true
		ai_crashed = true
	else:
		if snake_ai.has(new_head_player):
			player_crashed = true
		if snake_player.has(new_head_ai):
			ai_crashed = true

	if player_crashed or ai_crashed:
		var terminal_reward: float = AI_DEATH_REWARD if ai_crashed else AI_WIN_REWARD
		_update_q(state, action, terminal_reward, "", true)
		_finish_round(player_crashed, ai_crashed)
		return

	snake_player.insert(0, new_head_player)
	if new_head_player == target_player:
		score_player += 1
		if phase == 1:
			var respawn_pair_a := _spawn_mirrored_food_pair(snake_ai, snake_player)
			food_top = respawn_pair_a[0]
			food_bottom = respawn_pair_a[1]
		else:
			food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_player + snake_ai)
	else:
		snake_player.pop_back()

	var ai_ate: bool = new_head_ai == target_ai
	snake_ai.insert(0, new_head_ai)
	if ai_ate:
		score_ai += 1
		if phase == 1:
			var respawn_pair_b := _spawn_mirrored_food_pair(snake_ai, snake_player)
			food_top = respawn_pair_b[0]
			food_bottom = respawn_pair_b[1]
		else:
			food_shared = _spawn_food_in_range(0, GRID_HEIGHT - 1, snake_player + snake_ai)
	else:
		snake_ai.pop_back()

	var reward: float
	if ai_ate:
		reward = AI_FOOD_REWARD
	else:
		var new_dist: int = abs(new_head_ai.x - target_ai.x) + abs(new_head_ai.y - target_ai.y)
		reward = AI_STEP_PENALTY
		if new_dist < old_dist:
			reward += AI_SHAPING_BONUS
		else:
			reward += AI_SHAPING_PENALTY

	var next_state := _compute_state()
	_update_q(state, action, reward, next_state, false)

	_update_score_label()
	queue_redraw()


func _finish_round(player_crashed: bool, ai_crashed: bool) -> void:
	var text := ""
	if player_crashed and ai_crashed:
		if score_player == score_ai:
			text = "Carpisma - Berabere!"
		elif score_player > score_ai:
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
	if score_player == score_ai:
		text = "Sure Doldu - Berabere!"
	elif score_player > score_ai:
		text = "Sure Doldu - Kazandin!"
	else:
		text = "Sure Doldu - Kaybettin!"
	_end_match(text)


func _end_match(result_text: String) -> void:
	match_over = true
	move_timer.stop()

	if score_player > best_score:
		best_score = score_player
		_save_best_score()

	games_played += 1
	_update_epsilon()
	_update_imitation_weight()
	_save_ai_brain()
	_save_player_model()
	_update_ai_level_label()

	message_label.text = "%s\nSen: %d   Bot: %d" % [result_text, score_player, score_ai]
	message_label.visible = true
	restart_button.visible = true
	menu_button.visible = true


func _update_score_label() -> void:
	score_label.text = "Sen: %d   Bot: %d" % [score_player, score_ai]


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
	ai_level_label.text = "AI: %s (%d mac)" % [_ai_tier_name(), games_played]


func _update_timer_label() -> void:
	if phase == 1:
		var remaining := int(ceil(PHASE1_DURATION - elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Hazirlik: %ds" % remaining
	else:
		var remaining := int(ceil(PHASE1_DURATION + PHASE2_DURATION - elapsed))
		remaining = max(remaining, 0)
		timer_label.text = "Acik Saha: %ds" % remaining


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_UP, KEY_W:
				_queue_direction(Dir.UP)
			KEY_DOWN, KEY_S:
				_queue_direction(Dir.DOWN)
			KEY_LEFT, KEY_A:
				_queue_direction(Dir.LEFT)
			KEY_RIGHT, KEY_D:
				_queue_direction(Dir.RIGHT)

	if event is InputEventScreenTouch:
		if event.pressed:
			touch_start = event.position
			touch_start_valid = true
		else:
			touch_start_valid = false
	elif event is InputEventScreenDrag and touch_start_valid:
		var delta: Vector2 = event.position - touch_start
		if delta.length() > SWIPE_THRESHOLD:
			if abs(delta.x) > abs(delta.y):
				_queue_direction(Dir.RIGHT if delta.x > 0 else Dir.LEFT)
			else:
				_queue_direction(Dir.DOWN if delta.y > 0 else Dir.UP)
			touch_start_valid = false


func _queue_direction(new_dir: int) -> void:
	var opposite := {
		Dir.UP: Dir.DOWN,
		Dir.DOWN: Dir.UP,
		Dir.LEFT: Dir.RIGHT,
		Dir.RIGHT: Dir.LEFT,
	}
	if new_dir != opposite.get(direction_player, -1):
		pending_direction_player = new_dir


func _on_menu_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/menu.tscn")


func _draw() -> void:
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

	_draw_snake(snake_ai, Color(0.55, 0.75, 1.0), Color(0.3, 0.5, 0.9))
	_draw_snake(snake_player, Color(0.55, 0.95, 0.6), Color(0.25, 0.7, 0.3))


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


func _save_player_model() -> void:
	var f := FileAccess.open(PLAYER_MODEL_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(player_model))
		f.close()
