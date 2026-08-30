extends Node2D

const CELL_SIZE := 32
const GRID_WIDTH := 15
const GRID_HEIGHT := 22
const SAVE_PATH := "user://snakey_save.json"
const LADDER_PATH := "user://ladder_progress.json"

var best_score: int = 0
var highest_cleared: int = 0


func _ready() -> void:
	_load_best_score()
	_load_ladder_progress()
	_setup_ui()


func _setup_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var width := float(CELL_SIZE * GRID_WIDTH)

	var title := Label.new()
	title.text = "SNAKEY"
	title.add_theme_font_size_override("font_size", 44)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.size = Vector2(width, 60)
	title.position = Vector2(0, 90)
	canvas.add_child(title)

	var best_label := Label.new()
	best_label.text = "En Iyi Skor: %d   |   En Yuksek Seviye: %d" % [best_score, highest_cleared]
	best_label.add_theme_font_size_override("font_size", 16)
	best_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	best_label.size = Vector2(width, 28)
	best_label.position = Vector2(0, 170)
	canvas.add_child(best_label)

	var train_button := Button.new()
	train_button.text = "Antrenman"
	train_button.custom_minimum_size = Vector2(220, 60)
	train_button.position = Vector2(width / 2.0 - 110, 250)
	train_button.pressed.connect(_on_train_pressed)
	canvas.add_child(train_button)

	var train_hint := Label.new()
	train_hint.text = "Yilanini sen kontrol et, AI ogrensin"
	train_hint.add_theme_font_size_override("font_size", 13)
	train_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	train_hint.size = Vector2(width, 20)
	train_hint.position = Vector2(0, 312)
	canvas.add_child(train_hint)

	var fast_button := Button.new()
	fast_button.text = "Hizli Antrenman"
	fast_button.custom_minimum_size = Vector2(220, 60)
	fast_button.position = Vector2(width / 2.0 - 110, 346)
	fast_button.pressed.connect(_on_fast_train_pressed)
	canvas.add_child(fast_button)

	var fast_hint := Label.new()
	fast_hint.text = "AI kendi kendine hizlica cok sayida mac oynasin"
	fast_hint.add_theme_font_size_override("font_size", 13)
	fast_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	fast_hint.size = Vector2(width, 20)
	fast_hint.position = Vector2(0, 408)
	canvas.add_child(fast_hint)

	var single_button := Button.new()
	single_button.text = "Tekli Oyun"
	single_button.custom_minimum_size = Vector2(220, 60)
	single_button.position = Vector2(width / 2.0 - 110, 442)
	single_button.pressed.connect(_on_single_pressed)
	canvas.add_child(single_button)

	var single_hint := Label.new()
	single_hint.text = "Egittigin AI, 1-100 seviye hazir AI'lara karsi"
	single_hint.add_theme_font_size_override("font_size", 13)
	single_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	single_hint.size = Vector2(width, 20)
	single_hint.position = Vector2(0, 504)
	canvas.add_child(single_hint)

	var multi_button := Button.new()
	multi_button.text = "Coklu Oyuncu (Yakinda)"
	multi_button.disabled = true
	multi_button.custom_minimum_size = Vector2(220, 60)
	multi_button.position = Vector2(width / 2.0 - 110, 538)
	canvas.add_child(multi_button)


func _on_train_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _on_single_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/single_player.tscn")


func _on_fast_train_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/fast_train.tscn")


func _load_best_score() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(data) == TYPE_DICTIONARY and data.has("best"):
				best_score = int(data["best"])


func _load_ladder_progress() -> void:
	if FileAccess.file_exists(LADDER_PATH):
		var f := FileAccess.open(LADDER_PATH, FileAccess.READ)
		if f:
			var data = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(data) == TYPE_DICTIONARY and data.has("highest_cleared"):
				highest_cleared = int(data["highest_cleared"])
