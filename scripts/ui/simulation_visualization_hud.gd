extends CanvasLayer
class_name SimulationVisualizationHud

const VISUALIZER = preload("res://scripts/ui/structure_visualizer.gd")
const CHART = preload("res://scripts/ui/simulation_chart.gd")
const PX_PER_METER := 30.0
const MAX_SAMPLES := 360

var _controller: Node
var _visualizer: Control
var _chart: Control
var _panel: PanelContainer
var _panel_content: VBoxContainer
var _view_option: OptionButton
var _graph_option: OptionButton
var _amplification: HSlider
var _amplification_label: Label
var _speed_spin: SpinBox
var _play_button: Button
var _step_button: Button
var _collapse_button: Button
var _panel_collapsed: bool = false
var _data_label: Label
var _timeline_label: Label
var _samples: Array[Dictionary] = []
var _baseline_by_member: Dictionary = {}
var _previous_velocity_by_member: Dictionary = {}
var _event_lines: Array[String] = []
var _last_event_text: String = ""
var _structure_instance_id: int = 0
var _physics_frame_count: int = 0
var _elapsed_s: float = 0.0
var _sample_interval_frames: int = 6
var _single_step_requested: bool = false
var _last_sample: Dictionary = {}
var _telemetry_status: String = "실제 물리 표본 대기 중"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 0
	_controller = get_parent()
	_build_ui()
	_visualizer.call("set_controller", _controller)
	_sample_interval_frames = maxi(1, roundi(float(Engine.physics_ticks_per_second) / 20.0))
	get_tree().physics_frame.connect(_on_physics_frame)
	get_viewport().size_changed.connect(_on_viewport_size_changed)


func _process(_delta: float) -> void:
	if not is_instance_valid(_controller):
		return
	_check_structure_reset()
	_capture_dashboard_events()
	_update_controls()
	_visualizer.call("set_view", _view_option.get_item_text(_view_option.selected), _amplification.value)
	_update_chart()
	_update_data_label()


func _exit_tree() -> void:
	Engine.time_scale = 1.0


func _build_ui() -> void:
	_visualizer = VISUALIZER.new() as Control
	_visualizer.name = "StructureVisualizer"
	add_child(_visualizer)
	_panel = PanelContainer.new()
	_panel.name = "SimulationAnalysisPanel"
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -374.0
	_panel.offset_right = -12.0
	_panel.offset_top = 12.0
	_panel.offset_bottom = 368.0
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color("#111a25")
	panel_style.border_color = Color("#293a4b")
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(10)
	panel_style.content_margin_left = 10.0
	panel_style.content_margin_right = 10.0
	panel_style.content_margin_top = 8.0
	panel_style.content_margin_bottom = 8.0
	_panel.add_theme_stylebox_override("panel", panel_style)
	add_child(_panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_panel.add_child(scroll)
	_panel_content = VBoxContainer.new()
	_panel_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_content.add_theme_constant_override("separation", 6)
	scroll.add_child(_panel_content)
	_build_header()
	_build_transport_controls()
	_build_visual_controls()
	_build_chart()
	_build_status_and_timeline()
	_on_viewport_size_changed()


func _build_header() -> void:
	var row := HBoxContainer.new()
	var title := Label.new()
	title.text = "해석 · 시뮬레이션 뷰"
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(title)
	_collapse_button = Button.new()
	_collapse_button.text = "접기"
	_collapse_button.pressed.connect(_toggle_panel_collapse)
	row.add_child(_collapse_button)
	_panel_content.add_child(row)


func _build_transport_controls() -> void:
	var row := HBoxContainer.new()
	_play_button = Button.new()
	_play_button.custom_minimum_size.x = 98.0
	_play_button.pressed.connect(_toggle_play_pause)
	row.add_child(_play_button)
	_step_button = Button.new()
	_step_button.text = "한 프레임"
	_step_button.pressed.connect(_step_one_physics_frame)
	row.add_child(_step_button)
	var restart := Button.new()
	restart.text = "재시작"
	restart.pressed.connect(_restart_simulation)
	row.add_child(restart)
	_panel_content.add_child(row)
	var speed_row := HBoxContainer.new()
	var speed_label := _label("배속", 11, Color("#c6d4df"))
	speed_row.add_child(speed_label)
	_speed_spin = SpinBox.new()
	_speed_spin.min_value = 0.25
	_speed_spin.max_value = 2.0
	_speed_spin.step = 0.25
	_speed_spin.value = Engine.time_scale
	_speed_spin.suffix = "×"
	_speed_spin.value_changed.connect(_on_speed_changed)
	_speed_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_row.add_child(_speed_spin)
	_panel_content.add_child(speed_row)


func _build_visual_controls() -> void:
	var row := HBoxContainer.new()
	_view_option = OptionButton.new()
	for mode in ["부재 위험도", "재료 밀도", "축력 N", "전단력 V", "휨모멘트 M", "응력 상한", "변형률 상한", "변위 확대"]:
		_view_option.add_item(mode)
	_view_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_view_option)
	_graph_option = OptionButton.new()
	for graph_name in ["변위", "응답 가속도", "층간 변위비", "해석 응력"]:
		_graph_option.add_item(graph_name)
	_graph_option.item_selected.connect(func(_index): _update_chart())
	_graph_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_graph_option)
	_panel_content.add_child(row)
	var amplification_row := HBoxContainer.new()
	_amplification_label = _label("물리 변위 확대 5×", 10, Color("#8ea4b8"))
	_amplification_label.custom_minimum_size.x = 124.0
	amplification_row.add_child(_amplification_label)
	_amplification = HSlider.new()
	_amplification.min_value = 1.0
	_amplification.max_value = 20.0
	_amplification.step = 1.0
	_amplification.value = 5.0
	_amplification.value_changed.connect(func(value): _amplification_label.text = "물리 변위 확대 %.0f×" % value)
	amplification_row.add_child(_amplification)
	_panel_content.add_child(amplification_row)
	var hint := _label("N/V/M은 프레임 솔버 출력 · 변위/가속도는 물리 상태 표본", 9, Color("#718397"))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_content.add_child(hint)


func _build_chart() -> void:
	_chart = CHART.new() as Control
	_chart.custom_minimum_size = Vector2(0.0, 114.0)
	_chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel_content.add_child(_chart)


func _build_status_and_timeline() -> void:
	_data_label = _label("실제 물리 표본 대기 중", 10, Color("#b8c9d7"))
	_data_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_content.add_child(_data_label)
	_timeline_label = _label("이벤트 타임라인 · 아직 이벤트 없음", 9, Color("#8195a7"))
	_timeline_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_content.add_child(_timeline_label)


func _on_physics_frame() -> void:
	if not is_instance_valid(_controller):
		return
	if get_tree().paused and not _single_step_requested:
		return
	_elapsed_s += 1.0 / float(Engine.physics_ticks_per_second) * Engine.time_scale
	_physics_frame_count += 1
	if _physics_frame_count % _sample_interval_frames != 0 and not _single_step_requested:
		return
	_capture_physics_sample()
	_single_step_requested = false


func _capture_physics_sample() -> void:
	var members: Array = _controller.get("_members")
	if members.is_empty():
		_telemetry_status = "물리 표본 없음 · 부재가 없어"
		return
	var interval_s := float(_controller.get_physics_process_delta_time()) * float(_sample_interval_frames)
	if interval_s <= 0.0:
		interval_s = float(_sample_interval_frames) / float(Engine.physics_ticks_per_second)
	var displacement_m := 0.0
	var response_acceleration_m_s2 := 0.0
	var invalid_members := 0
	var story_displacements: Dictionary = {}
	var story_height_m := 0.0
	for member in members:
		if not is_instance_valid(member):
			continue
		var member_id := int(member.get_instance_id())
		var position: Vector2 = member.global_position
		var velocity: Vector2 = member.linear_velocity
		if not position.is_finite() or not velocity.is_finite():
			invalid_members += 1
			continue
		if not _baseline_by_member.has(member_id):
			_baseline_by_member[member_id] = position
		var baseline: Vector2 = _baseline_by_member[member_id]
		displacement_m = maxf(displacement_m, position.distance_to(baseline) / PX_PER_METER)
		if _previous_velocity_by_member.has(member_id):
			var previous: Vector2 = _previous_velocity_by_member[member_id]
			response_acceleration_m_s2 = maxf(response_acceleration_m_s2, (velocity - previous).length() / maxf(interval_s, 1.0e-6) / PX_PER_METER)
		_previous_velocity_by_member[member_id] = velocity
		if str(member.get("member_kind")) == "column":
			var member_name := str(member.get("member_id"))
			var story := int(member_name.trim_prefix("C").split("-")[0])
			if story > 0:
				if not story_displacements.has(story):
					story_displacements[story] = []
				(story_displacements[story] as Array).append((position.x - baseline.x) / PX_PER_METER)
				story_height_m = maxf(story_height_m, float(member.get("member_length_m")))
	if invalid_members > 0:
		_telemetry_status = "비유한 물리 상태 · %d/%d 부재 표본 제외" % [invalid_members, members.size()]
		return
	var story_drift_ratio: Variant = _max_story_drift_ratio(story_displacements, story_height_m)
	var stress_value: Variant = _maximum_solver_stress_pa()
	var sample := {
		"time_s": _elapsed_s,
		"displacement_m": displacement_m,
		"acceleration_m_s2": response_acceleration_m_s2,
		"sample_source": "rigid_body_state_and_frame_analysis_solver"
	}
	if story_drift_ratio != null:
		sample["story_drift_ratio"] = float(story_drift_ratio)
	if stress_value != null:
		sample["stress_pa"] = float(stress_value)
	_samples.append(sample)
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()
	_last_sample = sample
	_telemetry_status = "물리 표본 %d · %.2f s · solver %s" % [members.size(), _elapsed_s, "유효" if bool(_controller.get("frame_analysis_valid")) else "무효"]


func _maximum_solver_stress_pa() -> Variant:
	if not bool(_controller.get("frame_analysis_valid")):
		return null
	var analysis: Dictionary = _controller.get("_analysis_result")
	var member_demands: Dictionary = analysis.get("member_demands", {})
	var maximum := 0.0
	var found := false
	for member in member_demands:
		if not is_instance_valid(member) or not member.has_method("section_modulus_m3"):
			continue
		var demand: Dictionary = member_demands[member]
		var area := float(member.get("section_area_m2"))
		var section_modulus := float(member.call("section_modulus_m3"))
		if area <= 0.0 or section_modulus <= 0.0:
			continue
		var stress := absf(float(demand["axial_n"])) / area + absf(float(demand["moment_nm"])) / section_modulus
		maximum = maxf(maximum, stress)
		found = true
	return maximum if found else null


func _max_story_drift_ratio(story_displacements: Dictionary, story_height_m: float) -> Variant:
	if story_height_m <= 0.0 or story_displacements.is_empty():
		return null
	var previous_story_motion := 0.0
	var maximum := 0.0
	var max_story := 0
	for story in story_displacements:
		max_story = maxi(max_story, int(story))
	for story in range(1, max_story + 1):
		var motions: Array = story_displacements.get(story, [])
		if motions.is_empty():
			continue
		var sum_motion := 0.0
		for motion in motions:
			sum_motion += float(motion)
		var average_motion := sum_motion / float(motions.size())
		maximum = maxf(maximum, absf(average_motion - previous_story_motion) / story_height_m)
		previous_story_motion = average_motion
	return maximum


func _update_chart() -> void:
	if not is_instance_valid(_chart) or not is_instance_valid(_graph_option):
		return
	var index := _graph_option.selected
	var settings := [
		["displacement_m", "물리 수평변위", "m"],
		["acceleration_m_s2", "속도 차분 응답 가속도", "m/s²"],
		["story_drift_ratio", "층간변위비", "1"],
		["stress_pa", "솔버 응력 상한", "Pa"]
	]
	var selected: Array = settings[clampi(index, 0, settings.size() - 1)]
	_chart.call("set_data", _samples, str(selected[0]), str(selected[1]), str(selected[2]))


func _update_data_label() -> void:
	if not is_instance_valid(_data_label):
		return
	var second_line := "균열·좌굴 누적 데이터: 입력 없음"
	var current_sample := "아직 유효 표본 없음"
	if not _last_sample.is_empty():
		current_sample = "변위 %.4f m · 가속도 %.4f m/s²" % [
			float(_last_sample["displacement_m"]), float(_last_sample["acceleration_m_s2"])
		]
		if _last_sample.has("story_drift_ratio"):
			current_sample += " · 층간 %.5f" % float(_last_sample["story_drift_ratio"])
		if _last_sample.has("stress_pa"):
			current_sample += "\nσ 상한 %.3f MPa" % (float(_last_sample["stress_pa"]) / 1.0e6)
	_data_label.text = "%s\n%s\n%s" % [_telemetry_status, current_sample, second_line]


func _capture_dashboard_events() -> void:
	var dashboard: Node = _controller.get("_dashboard")
	if not is_instance_valid(dashboard):
		return
	var event_log: RichTextLabel = dashboard.get("event_log")
	if not is_instance_valid(event_log):
		return
	var current_text := event_log.get_parsed_text()
	if current_text == _last_event_text:
		return
	var lines := current_text.split("\n", false)
	var previous_lines := _last_event_text.split("\n", false)
	for index in range(previous_lines.size(), lines.size()):
		_event_lines.append(lines[index])
	while _event_lines.size() > 5:
		_event_lines.pop_front()
	_last_event_text = current_text
	_timeline_label.text = "파괴·시뮬레이션 이벤트\n" + "\n".join(_event_lines.slice(maxi(0, _event_lines.size() - 3), _event_lines.size())) if not _event_lines.is_empty() else "이벤트 타임라인 · 아직 이벤트 없음"


func _check_structure_reset() -> void:
	var structure: Dictionary = _controller.get("_structure")
	var container: Node = structure.get("container")
	var next_id := container.get_instance_id() if is_instance_valid(container) else 0
	if next_id == _structure_instance_id:
		return
	_structure_instance_id = next_id
	_baseline_by_member.clear()
	_previous_velocity_by_member.clear()
	_samples.clear()
	_last_sample.clear()
	_elapsed_s = 0.0
	_physics_frame_count = 0
	_event_lines.clear()
	_last_event_text = ""
	_visualizer.call("reset_visual_history")


func _toggle_play_pause() -> void:
	if is_instance_valid(_controller) and _controller.has_method("_toggle_pause"):
		_controller.call("_toggle_pause")


func _restart_simulation() -> void:
	if is_instance_valid(_controller) and _controller.has_method("_reset_simulation"):
		_controller.call("_reset_simulation", "시각화 패널에서 재시작")


func _step_one_physics_frame() -> void:
	if not get_tree().paused or _single_step_requested:
		return
	_single_step_requested = true
	get_tree().paused = false
	await get_tree().physics_frame
	get_tree().paused = true
	_single_step_requested = false


func _on_speed_changed(value: float) -> void:
	Engine.time_scale = clampf(value, 0.25, 2.0)


func _update_controls() -> void:
	var paused := get_tree().paused
	_play_button.text = "▶ 재생" if paused else "Ⅱ 일시정지"
	_step_button.disabled = not paused
	_speed_spin.value = Engine.time_scale


func _on_viewport_size_changed() -> void:
	if not is_instance_valid(_panel):
		return
	var view_height := get_viewport().get_visible_rect().size.y
	var panel_height := 58.0 if _panel_collapsed else 368.0
	_panel.offset_bottom = minf(panel_height, view_height - 24.0)


func _toggle_panel_collapse() -> void:
	_panel_collapsed = not _panel_collapsed
	_collapse_button.text = "펼치기" if _panel_collapsed else "접기"
	for child_index in range(1, _panel_content.get_child_count()):
		_panel_content.get_child(child_index).visible = not _panel_collapsed
	_on_viewport_size_changed()


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label
