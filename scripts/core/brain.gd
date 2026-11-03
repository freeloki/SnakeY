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
		var score: float = q[action] + imitation_weight * IMITATION_SCALE * pref[action]
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
		target_value += GAMMA * max_next
	q[action] = q[action] + ALPHA * (target_value - q[action])


func record_player_choice(state: String, action: int) -> void:
	if not player_model.has(state):
		player_model[state] = [0, 0, 0]
	var counts: Array = player_model[state]
	counts[action] = counts[action] + 1


## Reward for a non-terminal step (food eaten, or distance-shaping otherwise).
func step_reward(ate: bool, old_dist: int, new_dist: int) -> float:
	var reward: float
	if ate:
		reward = AI_FOOD_REWARD
	else:
		reward = AI_STEP_PENALTY
		if new_dist < old_dist:
			reward += AI_SHAPING_BONUS
		else:
			reward += AI_SHAPING_PENALTY
	return reward


## Reward for the AI at a terminal step: death if the AI crashed, win otherwise.
func terminal_reward(crashed: bool) -> float:
	return AI_DEATH_REWARD if crashed else AI_WIN_REWARD


## Call once per finished match: counts the match, then refreshes the decays.
func finish_match() -> void:
	games_played += 1
	_update_epsilon()
	_update_imitation_weight()


func _update_epsilon() -> void:
	epsilon = clamp(EPSILON_START * pow(EPSILON_DECAY, games_played), EPSILON_MIN, EPSILON_START)


func _update_imitation_weight() -> void:
	imitation_weight = clamp(IMITATION_WEIGHT_START * pow(IMITATION_DECAY, games_played), 0.0, IMITATION_WEIGHT_START)


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
