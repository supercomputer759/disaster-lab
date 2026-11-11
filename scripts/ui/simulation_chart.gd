extends Control
class_name SimulationChart

var samples: Array[Dictionary] = []
var metric_key: String = "displacement_m"
var metric_title: String = "변위"
var unit_label: String = "m"


func set_data(p_samples: Array[Dictionary], p_metric_key: String, p_title: String, p_unit: String) -> void:
	samples = p_samples.duplicate()
	metric_key = p_metric_key
	metric_title = p_title
	unit_label = p_unit
	queue_redraw()


func _draw() -> void:
	var bounds := Rect2(Vector2.ZERO, size)
	draw_rect(bounds, Color("#0c151e"), true)
	draw_rect(bounds, Color("#293a4b"), false, 1.0)
	var font := ThemeDB.fallback_font
	var title_text := "%s · %s" % [metric_title, unit_label]
	draw_string(font, Vector2(10.0, 17.0), title_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, Color("#c9d7e2"))
	if samples.is_empty():
		draw_string(font, Vector2(10.0, size.y * 0.58), "실제 표본 대기 중", HORIZONTAL_ALIGNMENT_CENTER, size.x - 20.0, 12, Color("#718397"))
		return
	var plot := Rect2(32.0, 28.0, maxf(1.0, size.x - 44.0), maxf(1.0, size.y - 48.0))
	for grid_index in range(1, 4):
		var y := plot.position.y + plot.size.y * float(grid_index) / 4.0
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), Color(0.24, 0.34, 0.43, 0.45), 1.0)
	var valid_samples: Array[Dictionary] = []
	var max_abs_value := 0.0
	for sample in samples:
		if not sample.has(metric_key):
			continue
		var value := float(sample[metric_key])
		if is_finite(value):
			valid_samples.append(sample)
			max_abs_value = maxf(max_abs_value, absf(value))
	if valid_samples.is_empty():
		draw_string(font, Vector2(10.0, size.y * 0.58), "이 항목의 실제 계산 표본 없음", HORIZONTAL_ALIGNMENT_CENTER, size.x - 20.0, 11, Color("#718397"))
		return
	if max_abs_value <= 1.0e-12:
		max_abs_value = 1.0
	var first_time := float(valid_samples.front().get("time_s", 0.0))
	var last_time := float(valid_samples.back().get("time_s", first_time))
	var time_span := maxf(last_time - first_time, 1.0e-6)
	var points := PackedVector2Array()
	for sample in valid_samples:
		var value := float(sample[metric_key])
		var time_s := float(sample.get("time_s", first_time))
		if not is_finite(value) or not is_finite(time_s):
			continue
		var x := plot.position.x + (time_s - first_time) / time_span * plot.size.x
		var y := plot.position.y + plot.size.y * 0.5 - value / max_abs_value * plot.size.y * 0.46
		points.append(Vector2(x, y))
	if points.size() > 1:
		draw_polyline(points, Color("#5fd0dc"), 2.0, true)
	var last_value := float(valid_samples.back()[metric_key])
	draw_string(font, Vector2(10.0, size.y - 6.0), "t %.2f s" % last_time, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 10, Color("#8195a7"))
	draw_string(font, Vector2(size.x - 124.0, 17.0), "%.4f %s" % [last_value, unit_label], HORIZONTAL_ALIGNMENT_RIGHT, 114.0, 10, Color("#5fd0dc"))
