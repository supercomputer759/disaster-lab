extends RefCounted
class_name FluidFloodModel

## 정수압·부력과 수위 상승 모델. 유속, 항력, 파랑, 수격은 포함하지 않아.
const STANDARD_GRAVITY_M_S2: float = 9.80665
const FRESH_WATER_DENSITY_KG_M3: float = 1000.0

var water_level_m: float = 0.0
var target_water_level_m: float = 0.0
var rise_rate_m_s: float = 0.0
var fluid_density_kg_m3: float = FRESH_WATER_DENSITY_KG_M3
var elapsed_time_s: float = 0.0


func pressure_at_depth(depth_m: float, density_kg_m3: float = FRESH_WATER_DENSITY_KG_M3) -> Dictionary:
	if depth_m < 0.0 or density_kg_m3 <= 0.0 or not is_finite(depth_m) or not is_finite(density_kg_m3):
		return _error("깊이는 0 이상, 유체 밀도는 양수인 유한 SI 값이어야 해.")
	var gauge_pressure := density_kg_m3 * STANDARD_GRAVITY_M_S2 * depth_m
	return {"valid": true, "depth_m": depth_m, "gauge_pressure_pa": gauge_pressure, "absolute_pressure_pa": 101325.0 + gauge_pressure, "units": "Pa", "model": "incompressible_hydrostatic"}


func vertical_wall_resultant(submerged_height_m: float, width_m: float, density_kg_m3: float = FRESH_WATER_DENSITY_KG_M3) -> Dictionary:
	if submerged_height_m < 0.0 or width_m <= 0.0 or density_kg_m3 <= 0.0:
		return _error("침수 높이는 0 이상, 벽 폭과 유체 밀도는 양수여야 해.")
	var maximum_pressure := density_kg_m3 * STANDARD_GRAVITY_M_S2 * submerged_height_m
	var resultant := 0.5 * maximum_pressure * submerged_height_m * width_m
	return {
		"valid": true, "maximum_pressure_pa": maximum_pressure,
		"resultant_force_n": resultant,
		"centroid_above_bottom_m": submerged_height_m / 3.0,
		"centroid_below_water_surface_m": 2.0 * submerged_height_m / 3.0,
		"units": {"pressure": "Pa", "force": "N", "length": "m"}
	}


func buoyancy_force(displaced_volume_m3: float, density_kg_m3: float = FRESH_WATER_DENSITY_KG_M3) -> Dictionary:
	if displaced_volume_m3 < 0.0 or density_kg_m3 <= 0.0 or not is_finite(displaced_volume_m3) or not is_finite(density_kg_m3):
		return _error("변위 유체 체적은 0 이상, 유체 밀도는 양수인 유한 값이어야 해.")
	var force := density_kg_m3 * STANDARD_GRAVITY_M_S2 * displaced_volume_m3
	return {"valid": true, "displaced_volume_m3": displaced_volume_m3, "buoyant_force_n": force, "force_xy_n": Vector2(0.0, force), "direction": "upward_y_positive", "units": "N"}


func add_buoyancy_to_solver_loads(loads: Dictionary, node_id: String, displaced_volume_m3: float) -> Dictionary:
	if node_id.is_empty():
		return _error("부력 적용 절점 ID가 비어 있어.")
	var buoyancy := buoyancy_force(displaced_volume_m3, fluid_density_kg_m3)
	if not bool(buoyancy["valid"]):
		return buoyancy
	var updated_loads := loads.duplicate(true)
	var nodal_load: Vector3 = updated_loads.get(node_id, Vector3.ZERO)
	nodal_load.y += float(buoyancy["buoyant_force_n"])
	updated_loads[node_id] = nodal_load
	return {"valid": true, "loads": updated_loads, "buoyant_force_n": buoyancy["buoyant_force_n"], "load_source": "archimedes_displaced_fluid_weight", "units": "N"}


func configure_flood(initial_level_m: float, target_level_m: float, rise_rate_m_s: float, density_kg_m3: float = FRESH_WATER_DENSITY_KG_M3) -> Dictionary:
	if not is_finite(initial_level_m) or not is_finite(target_level_m) or not is_finite(rise_rate_m_s) or initial_level_m < 0.0 or target_level_m < initial_level_m or rise_rate_m_s <= 0.0 or density_kg_m3 <= 0.0:
		return _error("침수 수위는 0 이상으로 상승해야 하고 상승률/유체 밀도는 양수여야 해.")
	water_level_m = initial_level_m
	target_water_level_m = target_level_m
	self.rise_rate_m_s = rise_rate_m_s
	fluid_density_kg_m3 = density_kg_m3
	elapsed_time_s = 0.0
	return {"valid": true, "water_level_m": water_level_m, "target_level_m": target_level_m, "rise_rate_m_s": rise_rate_m_s}


func advance_flood(delta_s: float) -> Dictionary:
	if delta_s <= 0.0 or not is_finite(delta_s):
		return _error("시간 간격은 유한한 양수여야 해.")
	var old_level := water_level_m
	water_level_m = minf(target_water_level_m, water_level_m + rise_rate_m_s * delta_s)
	elapsed_time_s += delta_s
	var is_rising := water_level_m < target_water_level_m
	return {
		"valid": true, "time_s": elapsed_time_s, "water_level_m": water_level_m,
		"water_level_change_m": water_level_m - old_level,
		"surface_rise_rate_m_s": rise_rate_m_s if is_rising else 0.0,
		"flood_active": is_rising, "fluid_density_kg_m3": fluid_density_kg_m3
	}


func submerged_state_for_vertical_member(bottom_y_m: float, top_y_m: float) -> Dictionary:
	if not is_finite(bottom_y_m) or not is_finite(top_y_m) or top_y_m <= bottom_y_m:
		return _error("수직 부재는 유한하고 위쪽 좌표가 아래쪽보다 커야 해.")
	var full_height := top_y_m - bottom_y_m
	var submerged_height := clampf(water_level_m - bottom_y_m, 0.0, full_height)
	return {
		"valid": true, "water_level_m": water_level_m,
		"submerged_height_m": submerged_height,
		"submerged_fraction": submerged_height / full_height,
		"maximum_gauge_pressure_pa": fluid_density_kg_m3 * STANDARD_GRAVITY_M_S2 * maxf(0.0, water_level_m - bottom_y_m)
	}


func build_current_hydrostatic_frame_loads(nodes: Array, elements: Array, exposed_surfaces: Dictionary) -> Dictionary:
	return build_hydrostatic_frame_loads(nodes, elements, water_level_m, exposed_surfaces)


func build_hydrostatic_frame_loads(nodes: Array, elements: Array, water_surface_y_m: float, exposed_surfaces: Dictionary) -> Dictionary:
	if not is_finite(water_surface_y_m):
		return _error("수면 높이가 유한한 m 값이 아니야.")
	var nodes_by_id: Dictionary = {}
	for node in nodes:
		if not node is Dictionary or not node.has("id") or not node.has("y_m"):
			return _error("프레임 절점에는 id와 y_m이 필요해.")
		nodes_by_id[str(node["id"])] = node
	var member_loads: Dictionary = {}
	var total_force_xy := Vector2.ZERO
	for element in elements:
		var element_id := str(element.get("id", ""))
		if not exposed_surfaces.has(element_id):
			continue
		var surface: Dictionary = exposed_surfaces[element_id]
		var node_i_id := str(element.get("node_i", ""))
		var node_j_id := str(element.get("node_j", ""))
		if not nodes_by_id.has(node_i_id) or not nodes_by_id.has(node_j_id):
			return _error("수압 노출면 %s이 알 수 없는 절점을 참조해." % element_id)
		var width := float(surface.get("width_m", 0.0))
		var normal: Vector2 = surface.get("normal_global", Vector2.ZERO)
		if width <= 0.0 or not normal.is_finite() or normal.length_squared() < 1.0e-12:
			return _error("요소 %s의 노출면은 양수 폭과 유한한 단위 방향을 가져야 해." % element_id)
		normal = normal.normalized()
		var y_i := float(nodes_by_id[node_i_id]["y_m"])
		var y_j := float(nodes_by_id[node_j_id]["y_m"])
		var point_i := Vector2(float(nodes_by_id[node_i_id].get("x_m", 0.0)), y_i)
		var point_j := Vector2(float(nodes_by_id[node_j_id].get("x_m", 0.0)), y_j)
		var delta := point_j - point_i
		var length_m := delta.length()
		if length_m <= 1.0e-9:
			return _error("수압 노출 요소 %s의 길이가 0이야." % element_id)
		var axis_x := delta / length_m
		var axis_y := Vector2(-axis_x.y, axis_x.x)
		var local_load := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		var total_steps := 64
		var integration_step := length_m / float(total_steps)
		# Simpson 적분은 자유수면을 가로지르는 요소에서 건조 구간의 하중이 생기지 않게 한다.
		for sample in range(total_steps + 1):
			var ratio := float(sample) / float(total_steps)
			var y := lerpf(y_i, y_j, ratio)
			var pressure := fluid_density_kg_m3 * STANDARD_GRAVITY_M_S2 * maxf(0.0, water_surface_y_m - y)
			var q_global := normal * pressure * width
			var qx := q_global.dot(axis_x)
			var qy := q_global.dot(axis_y)
			var simpson_weight := 1.0 if sample == 0 or sample == total_steps else (4.0 if sample % 2 == 1 else 2.0)
			var scale := simpson_weight * integration_step / 3.0
			var axial_i := 1.0 - ratio
			var axial_j := ratio
			var bend_i := 1.0 - 3.0 * ratio * ratio + 2.0 * ratio * ratio * ratio
			var rotate_i := length_m * (ratio - 2.0 * ratio * ratio + ratio * ratio * ratio)
			var bend_j := 3.0 * ratio * ratio - 2.0 * ratio * ratio * ratio
			var rotate_j := length_m * (-ratio * ratio + ratio * ratio * ratio)
			local_load[0] += axial_i * qx * scale
			local_load[3] += axial_j * qx * scale
			local_load[1] += bend_i * qy * scale
			local_load[2] += rotate_i * qy * scale
			local_load[4] += bend_j * qy * scale
			local_load[5] += rotate_j * qy * scale
			total_force_xy += q_global * scale
		member_loads[element_id] = local_load
	return {
		"valid": true, "element_loads_local_by_id": member_loads,
		"resultant_force_xy_n": total_force_xy,
		"source": "lumped_hydrostatic_pressure_to_frame_consistent_loads",
		"units": {"pressure": "Pa", "distributed_load": "N/m", "resultant": "N"},
		"model_note": "정지 유체의 단면당 정수압을 선형 보간해 Euler-Bernoulli 2D 프레임의 등가 절점하중으로 변환. 단면 폭/노출면/법선은 호출자가 지정."
	}


func _error(message: String) -> Dictionary:
	return {"valid": false, "error": message}
