extends Control
class_name StructureVisualizer

const PX_PER_METER := 30.0

var controller: Node
var view_mode: String = "부재 위험도"
var displacement_amplification: float = 5.0
var baseline_by_member: Dictionary = {}
var broken_connections: Dictionary = {}
var _known_connection_positions: Dictionary = {}
var _invalid_member_count: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func set_controller(value: Node) -> void:
	controller = value
	queue_redraw()


func reset_visual_history() -> void:
	baseline_by_member.clear()
	broken_connections.clear()
	_known_connection_positions.clear()
	queue_redraw()


func set_view(mode: String, amplification: float) -> void:
	view_mode = mode
	displacement_amplification = maxf(amplification, 1.0)
	queue_redraw()


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if not is_instance_valid(controller):
		return
	var members: Array = controller.get("_members")
	var joints: Array = controller.get("_joints")
	var analysis: Dictionary = controller.get("_analysis_result")
	var member_demands: Dictionary = analysis.get("member_demands", {})
	_invalid_member_count = 0
	var connection_demands: Dictionary = analysis.get("connection_demands", {})
	var connection_data: Dictionary = controller.get("_connection_data")
	var active_connection_ids: Dictionary = {}
	var max_display_value := 0.0
	var min_density := INF
	var max_density := 0.0
	for member in members:
		if not is_instance_valid(member):
			continue
		if member.has_method("physical_mass_kg"):
			var density := float(member.get("material_density_kg_m3"))
			min_density = minf(min_density, density)
			max_density = maxf(max_density, density)
		if member_demands.has(member):
			max_display_value = maxf(max_display_value, _metric_value(member, member_demands[member]))
	for joint in joints:
		if is_instance_valid(joint) and not joint.is_queued_for_deletion():
			active_connection_ids[str(joint.get_instance_id())] = true
	for member in members:
		if not is_instance_valid(member):
			continue
		_draw_member(member, member_demands, max_display_value, min_density, max_density)
	for joint in joints:
		if not is_instance_valid(joint) or joint.is_queued_for_deletion():
			continue
		var key := str(joint.get_instance_id())
		var screen_position: Vector2 = joint.get_global_transform_with_canvas().origin
		_known_connection_positions[key] = {"name": joint.name, "position": screen_position}
		if bool(joint.get("failed")):
			broken_connections[key] = _known_connection_positions[key]
			continue
		_draw_connection(joint, screen_position, connection_demands.get(joint, {}), connection_data.get(joint, {}))
	for key in _known_connection_positions:
		if not active_connection_ids.has(key) and not broken_connections.has(key):
			broken_connections[key] = _known_connection_positions[key]
	for record in broken_connections.values():
		_draw_broken_connection(record["position"])
	_draw_selected_label(member_demands)


func _draw_member(member: RigidBody2D, member_demands: Dictionary, max_display_value: float, min_density: float, max_density: float) -> void:
	var member_id := str(member.get("member_id"))
	var length_m := float(member.get("member_length_m"))
	var rest_start: Vector2 = member.get("rest_start_world")
	var rest_end: Vector2 = member.get("rest_end_world")
	var transform_with_canvas := member.get_global_transform_with_canvas()
	var current_start: Vector2 = transform_with_canvas * Vector2(0.0, -length_m * PX_PER_METER * 0.5)
	var current_end: Vector2 = transform_with_canvas * Vector2(0.0, length_m * PX_PER_METER * 0.5)
	var canvas_transform := member.get_canvas_transform()
	var start: Vector2 = canvas_transform * rest_start
	var finish: Vector2 = canvas_transform * rest_end
	var demand: Dictionary = member_demands.get(member, {})
	var value := _metric_value(member, demand)
	var color := _member_color(member, demand, value, max_display_value, min_density, max_density)
	if bool(member.get("fractured")):
		color = Color("#ef5368")
	if not start.is_finite() or not finish.is_finite():
		return
	if not current_start.is_finite() or not current_end.is_finite():
		_invalid_member_count += 1
		var solver_view := view_mode in ["축력 N", "전단력 V", "휨모멘트 M", "응력 상한", "변형률 상한", "부재 위험도"]
		draw_line(start, finish, color if solver_view else Color("#536575"), 2.5 if solver_view else 2.0, true)
		if member == controller.get("_selected_member") and not demand.is_empty() and view_mode != "변위 확대":
			_draw_label((start + finish) * 0.5 + Vector2(9.0, -7.0), _selected_value_text(member, demand, NAN), Color("#f4f8fc"))
		return
	var baseline: Vector2 = baseline_by_member.get(member.get_instance_id(), member.global_position)
	if not baseline_by_member.has(member.get_instance_id()):
		baseline_by_member[member.get_instance_id()] = member.global_position
	var displacement_world := member.global_position - baseline
	var amplified_start := start + (current_start - start) * displacement_amplification
	var amplified_end := finish + (current_end - finish) * displacement_amplification
	var line_start := amplified_start if view_mode == "변위 확대" else start
	var line_end := amplified_end if view_mode == "변위 확대" else finish
	var width := 4.0 if member == controller.get("_selected_member") else 2.5
	draw_line(line_start, line_end, color, width, true)
	var crack_fraction: Variant = member.get_meta("crack_position_fraction") if member.has_meta("crack_position_fraction") else null
	if crack_fraction != null:
		var crack_point := line_start.lerp(line_end, clampf(float(crack_fraction), 0.0, 1.0))
		draw_line(crack_point + Vector2(-5.0, -5.0), crack_point + Vector2(5.0, 5.0), Color("#ffd166"), 3.0, true)
		_draw_label(crack_point + Vector2(7.0, -6.0), "균열", Color("#ffd166"))
	if bool(member.get("fractured")):
		var split_center := (line_start + line_end) * 0.5
		draw_line(split_center + Vector2(-6.0, -6.0), split_center + Vector2(6.0, 6.0), Color("#ff4d68"), 3.0)
	if member == controller.get("_selected_member"):
		var selected_value := _selected_value_text(member, demand, displacement_world.length() / PX_PER_METER)
		_draw_label((line_start + line_end) * 0.5 + Vector2(9.0, -7.0), selected_value, Color("#f4f8fc"))
	# 실제 프레임 해석에 좌굴 상태나 손상도가 공급된 경우에만 표식을 그린다.
	var buckling_ratio: Variant = member.get_meta("buckling_utilization") if member.has_meta("buckling_utilization") else null
	if buckling_ratio != null and is_finite(float(buckling_ratio)) and float(buckling_ratio) >= 1.0:
		var axis := (line_end - line_start).normalized()
		var normal := Vector2(-axis.y, axis.x)
		var wave := 9.0
		var points := PackedVector2Array([
			line_start, line_start.lerp(line_end, 0.25) + normal * wave,
			line_start.lerp(line_end, 0.5), line_start.lerp(line_end, 0.75) - normal * wave, line_end
		])
		draw_polyline(points, Color("#ff6262"), 3.0, true)


func _draw_connection(joint: Joint2D, position: Vector2, demand: Dictionary, _info: Dictionary) -> void:
	var ratio := float(demand.get("utilization", joint.call("utilization") if joint.has_method("utilization") else 0.0))
	var color := Color("#58c697")
	if ratio >= 1.0:
		color = Color("#f05467")
	elif ratio >= 0.7:
		color = Color("#f2b84b")
	var rigid := false
	if joint is StructuralConnection:
		rigid = (joint as StructuralConnection).connection_kind == StructuralConnection.ConnectionKind.RIGID
	if rigid:
		var diamond := PackedVector2Array([position + Vector2(0,-5),position + Vector2(5,0),position + Vector2(0,5),position + Vector2(-5,0)])
		draw_colored_polygon(diamond, color)
	else:
		draw_circle(position, 4.0, color)
	if joint.has_meta("damage_ratio"):
		var damage := clampf(float(joint.get_meta("damage_ratio")), 0.0, 1.0)
		draw_arc(position, 8.0, -PI*0.5, -PI*0.5 + TAU*damage, 24, Color("#ffd166"), 2.0, true)
	if bool(joint.get("failed")):
		_draw_broken_connection(position)


func _draw_broken_connection(position: Vector2) -> void:
	draw_line(position + Vector2(-5,-5),position + Vector2(5,5),Color("#fa5368"),2.5,true)
	draw_line(position + Vector2(5,-5),position + Vector2(-5,5),Color("#fa5368"),2.5,true)


func _metric_value(member: RigidBody2D, demand: Dictionary) -> float:
	if demand.is_empty():
		return 0.0
	match view_mode:
		"축력 N": return float(demand.get("axial_n", 0.0))
		"전단력 V": return float(demand.get("shear_n", 0.0))
		"휨모멘트 M": return float(demand.get("moment_nm", 0.0))
		"응력 상한": return _stress_upper_pa(member, demand)
		"변형률 상한": return _strain_upper(member, demand)
	return _member_utilization(demand)


func _stress_upper_pa(member: RigidBody2D, demand: Dictionary) -> float:
	var area := float(member.get("section_area_m2"))
	var section_modulus := float(member.call("section_modulus_m3")) if member.has_method("section_modulus_m3") else 0.0
	if area <= 0.0 or section_modulus <= 0.0:
		return NAN
	# 해석기가 부재 단부 절댓값 최대를 반환하므로 N/A + M/S 조합 상한으로 표기한다.
	return absf(float(demand.get("axial_n", 0.0))) / area + absf(float(demand.get("moment_nm", 0.0))) / section_modulus


func _strain_upper(member: RigidBody2D, demand: Dictionary) -> float:
	var modulus := float(member.get("elastic_modulus_pa"))
	var stress := _stress_upper_pa(member, demand)
	return stress / modulus if modulus > 0.0 else NAN


func _member_color(member: RigidBody2D, demand: Dictionary, value: float, max_value: float, min_density: float, max_density: float) -> Color:
	if view_mode == "재료 밀도":
		var range_density := maxf(max_density - min_density, 1.0)
		var amount := clampf((float(member.get("material_density_kg_m3")) - min_density) / range_density, 0.0, 1.0)
		return Color("#43c6b0").lerp(Color("#e5a950"), amount)
	if view_mode in ["축력 N", "전단력 V", "휨모멘트 M", "응력 상한", "변형률 상한"]:
		var amount := clampf(value / maxf(max_value, 1.0e-9), 0.0, 1.0)
		return Color("#52c7d4").lerp(Color("#f05c67"), amount)
	var ratio := _member_utilization(demand)
	if not is_finite(ratio):
		return Color("#657584")
	if ratio >= 1.0:
		return Color("#ef5368")
	return Color("#55c596").lerp(Color("#f2b84b"), clampf(ratio, 0.0, 1.0))


func _selected_value_text(member: RigidBody2D, demand: Dictionary, physical_displacement_m: float) -> String:
	match view_mode:
		"축력 N": return "N %.2f kN" % (float(demand.get("axial_n", 0.0)) / 1000.0)
		"전단력 V": return "V %.2f kN" % (float(demand.get("shear_n", 0.0)) / 1000.0)
		"휨모멘트 M": return "M %.2f kN·m" % (float(demand.get("moment_nm", 0.0)) / 1000.0)
		"응력 상한": return "σ 상한 %.2f MPa" % (_stress_upper_pa(member, demand) / 1.0e6)
		"변형률 상한": return "ε 상한 %.6f" % _strain_upper(member, demand)
		"변위 확대": return "물리 변위 %.4f m ×%.1f" % [physical_displacement_m, displacement_amplification]
		"재료 밀도": return "ρ %.0f kg/m³" % float(member.get("material_density_kg_m3"))
	return "수요/용량 %.1f%%" % (_member_utilization(demand) * 100.0)


func _member_utilization(demand: Dictionary) -> float:
	return maxf(
		float(demand.get("axial_n", 0.0)) / maxf(float(demand.get("axial_capacity_n", 0.0)), 1.0),
		maxf(
			float(demand.get("shear_n", 0.0)) / maxf(float(demand.get("shear_capacity_n", 0.0)), 1.0),
			float(demand.get("moment_nm", 0.0)) / maxf(float(demand.get("moment_capacity_nm", 0.0)), 1.0)
		)
	)


func _draw_label(position: Vector2, text_value: String, color: Color) -> void:
	draw_string(ThemeDB.fallback_font, position, text_value, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 11, color)


func _draw_selected_label(_member_demands: Dictionary) -> void:
	if not is_instance_valid(controller):
		return
	var mode_text := view_mode
	var status_text := str(controller.get("frame_analysis_status"))
	if _invalid_member_count > 0:
		status_text = "물리좌표 비유한 %d개 · 회색은 초기 설계 형상" % _invalid_member_count
	var label_text := "%s · %s" % [mode_text, status_text]
	draw_string(ThemeDB.fallback_font, Vector2(350.0, size.y - 12.0), label_text, HORIZONTAL_ALIGNMENT_LEFT, maxf(0.0, size.x - 370.0), 10, Color("#aebdca"))
