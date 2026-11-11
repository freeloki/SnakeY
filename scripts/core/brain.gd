class_name SnakeBrain
extends RefCounted
## Shared tabular Q-learning brain with imitation of the player model.
## Used by Antrenman (main), Tekli Oyun (single_player) and Hizli Antrenman (fast_train).
## State encoding stays in the scene scripts; this class only owns learning,
## action selection and persistence.

const DEFAULT_BRAIN_PATH := "user://ai_brain.json"
const DEFAULT_PLAYER_MODEL_PATH := "user://player_model.json"

const ALL_ACTIONS: Array[int] = [0, 1, 2]

const ALPHA := 0.2           # learning rate
const GAMMA := 0.9           # discount factor
const EPSILON_START := 0.35  # exploration rate for a brand new AI
const EPSILON_MIN := 0.06    # keep exploring, avoid locking onto a mediocre policy
const EPSILON_DECAY := 0.992 # per match played

# Reward shaping
const AI_DEATH_REWARD := -60.0
const AI_WIN_REWARD := 60.0
const AI_FOOD_REWARD := 15.0
const AI_STEP_PENALTY := -0.05
const AI_SHAPING_BONUS := 0.15
const AI_SHAPING_PENALTY := -0.15

# Imitation learning: the AI leans on how the player plays early on, fading out
# as it accumulates its own experience.
const IMITATION_WEIGHT_START := 1.0
const IMITATION_DECAY := 0.994
const IMITATION_SCALE := 35.0

# Tunable learning parameters. They start as the constants above and only differ
# when a tool calls configure() (e.g. tools/train_ai.gd parameter sweeps). The
# game modes never call it, so their behaviour is exactly the constants.
var alpha: float = ALPHA
var gamma: float = GAMMA
var epsilon_start: float = EPSILON_START
var epsilon_min: float = EPSILON_MIN
var epsilon_decay: float = EPSILON_DECAY
var death_reward: float = AI_DEATH_REWARD
var win_reward: float = AI_WIN_REWARD
var food_reward: float = AI_FOOD_REWARD
var step_penalty: float = AI_STEP_PENALTY
var shaping_bonus: float = AI_SHAPING_BONUS
var shaping_penalty: float = AI_SHAPING_PENALTY
var imitation_weight_start: float = IMITATION_WEIGHT_START
var imitation_decay: float = IMITATION_DECAY
var imitation_scale: float = IMITATION_SCALE

var q_table: Dictionary = {}
var games_played: int = 0
var epsilon: float = EPSILON_START
var player_model: Dictionary = {}
var imitation_weight: float = IMITATION_WEIGHT_START

var brain_path: String
var player_model_path: String


func _init(p_brain_path: String = DEFAULT_BRAIN_PATH, p_player_model_path: String = DEFAULT_PLAYER_MODEL_PATH) -> void:
	brain_path = p_brain_path
	player_model_path = p_player_model_path


## Names accepted by configure(), i.e. the tunable variables above.
static func tunable_names() -> PackedStringArray:
	return PackedStringArray([
		"alpha", "gamma", "epsilon_start", "epsilon_min", "epsilon_decay",
		"death_reward", "win_reward", "food_reward", "step_penalty",
		"shaping_bonus", "shaping_penalty",
		"imitation_weight_start", "imitation_decay", "imitation_scale",
	])


## Current value of every tunable parameter, {name: float}.
func tunables() -> Dictionary:
	var out := {}
	for n in tunable_names():
		out[n] = float(get(n))
	return out


## Optional override of learning parameters, {name: float}. For tools only (the
## game modes never call this). Returns "" on success or an error message; on an
## error nothing is changed. Refreshes epsilon and imitation weight afterwards.
func configure(overrides: Dictionary) -> String:
	var names := tunable_names()
	for key in overrides.keys():
		if not names.has(str(key)):
			return "unknown brain parameter '%s' (known: %s)" % [str(key), ", ".join(names)]
		var t := typeof(overrides[key])
		if t != TYPE_FLOAT and t != TYPE_INT:
			return "brain parameter '%s' must be a number" % str(key)
	var eps_start: float = float(overrides.get("epsilon_start", epsilon_start))
	var eps_min: float = float(overrides.get("epsilon_min", epsilon_min))
	if eps_min > eps_start:
		return "epsilon_min (%s) must not exceed epsilon_start (%s)" % [str(eps_min), str(eps_start)]
	if float(overrides.get("imitation_weight_start", imitation_weight_start)) < 0.0:
		return "imitation_weight_start must be >= 0 (its floor is 0)"
	for key in overrides.keys():
		set(str(key), float(overrides[key]))
	_update_epsilon()
	_update_imitation_weight()
	return ""


func get_q(state: String) -> Array:
	if q_table.has(state):
		return q_table[state]
	return [0.0, 0.0, 0.0]


func player_preference(state: String) -> Array:
	if not player_model.has(state):
		return [0.0, 0.0, 0.0]
	var counts: Array = player_model[state]
	var total: float = float(counts[0] + counts[1] + counts[2])
	if total <= 0.0:
		return [0.0, 0.0, 0.0]
	return [counts[0] / total, counts[1] / total, counts[2] / total]


## Picks an action, never a blocked one while a free one exists. Danger bits cover
## blocked cells only, so a head-on crash with the rival stays possible.
func select_action(state: String) -> int:
	var candidates := _free_actions(state)
	if randf() < epsilon:
		return candidates[randi() % candidates.size()]
	var q: Array = get_q(state)
	var pref: Array = player_preference(state)
	var best_action: int = candidates[0]
	var best_value: float = -INF
	for action in candidates:
		var score: float = q[action] + imitation_weight * imitation_scale * pref[action]
		if score > best_value:
			best_value = score
			best_action = action
	return best_action


## Actions whose danger bit is clear; all three if every action is blocked.
## Key format "<bits>_<heading>" comes from SnakeArena.compute_state, where bit N
## of <bits> is the danger of action N (0 = straight, 1 = left, 2 = right).
func _free_actions(state: String) -> Array[int]:
	var bits: int = state.get_slice("_", 0).to_int()
	var free: Array[int] = []
	for action in ALL_ACTIONS:
		if bits & (1 << action) == 0:
			free.append(action)
	if free.is_empty():
		return ALL_ACTIONS
	return free


func update_q(state: String, action: int, reward: float, next_state: String, done: bool) -> void:
	if not q_table.has(state):
		q_table[state] = [0.0, 0.0, 0.0]
	var q: Array = q_table[state]
	var target_value: float = reward
	if not done:
		var next_q: Array = get_q(next_state)
		var max_next: float = next_q[0]
		if next_q[1] > max_next:
			max_next = next_q[1]
		if next_q[2] > max_next:
			max_next = next_q[2]
		target_value += gamma * max_next
	q[action] = q[action] + alpha * (target_value - q[action])


func record_player_choice(state: String, action: int) -> void:
	if not player_model.has(state):
		player_model[state] = [0, 0, 0]
	var counts: Array = player_model[state]
	counts[action] = counts[action] + 1


## Reward for a non-terminal step (food eaten, or distance-shaping otherwise).
func step_reward(ate: bool, old_dist: int, new_dist: int) -> float:
	var reward: float
	if ate:
		reward = food_reward
	else:
		reward = step_penalty
		if new_dist < old_dist:
			reward += shaping_bonus
		else:
			reward += shaping_penalty
	return reward


## Reward for the AI at a terminal step: death if the AI crashed, win otherwise.
func terminal_reward(crashed: bool) -> float:
	return death_reward if crashed else win_reward


## Call once per finished match: counts the match, then refreshes the decays.
func finish_match() -> void:
	games_played += 1
	_update_epsilon()
	_update_imitation_weight()


func _update_epsilon() -> void:
	epsilon = clamp(epsilon_start * pow(epsilon_decay, games_played), epsilon_min, epsilon_start)


func _update_imitation_weight() -> void:
	imitation_weight = clamp(imitation_weight_start * pow(imitation_decay, games_played), 0.0, imitation_weight_start)


func load_brain() -> void:
	if FileAccess.file_exists(brain_path):
		var f := FileAccess.open(brain_path, FileAccess.READ)
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


func save_brain() -> void:
	var f := FileAccess.open(brain_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"games_played": games_played, "q_table": q_table}))
		f.close()


func load_player_model() -> void:
	if FileAccess.file_exists(player_model_path):
		var f := FileAccess.open(player_model_path, FileAccess.READ)
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


## Only Antrenman (main.gd) may call this; other modes treat the model as read-only.
func save_player_model() -> void:
	var f := FileAccess.open(player_model_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(player_model))
		f.close()
