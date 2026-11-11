extends RefCounted
class_name WindLoadModel

## Power-law 평균 풍속과 반사인 돌풍을 단면 풍압하중으로 바꾼다. 설계기준 풍속/계수 인증용이 아니야.
const AIR_DENSITY_KG_M3: float = 1.225

var reference_speed_m_s: float = 0.0
var reference_height_m: float = 10.0
var wind_direction_deg: float = 0.0
var air_density_kg_m3: float = AIR_DENSITY_KG_M3
var profile_exponent: float = 0.14
var elapsed_time_s: float = 0.0
var gust_start_s: float = -1.0
var gust_duration_s: float = 0.0
var gust_increment_m_s: float = 0.0


func configure(
	wind_speed_m_s: float,
	reference_height: float = 10.0,
	force_direction_deg: float = 0.0,
	density_kg_m3: float = AIR_DENSITY_KG_M3,
	height_exponent: float = 0.14
) -> Dictionary:
	if wind_speed_m_s < 0.0 or reference_height <= 0.0 or density_kg_m3 <= 0.0 or height_exponent < 0.0:
		return _error("풍속은 0 이상, 기준 높이/공기 밀도는 양수여야 해.")
	if not is_finite(wind_speed_m_s) or not is_finite(reference_height) or not is_finite(force_direction_deg) or not is_finite(density_kg_m3) or not is_finite(height_exponent):
		return _error("풍속 설정은 유한한 SI 값이어야 해.")
	reference_speed_m_s = wind_speed_m_s
	reference_height_m = reference_height
	wind_direction_deg = force_direction_deg
	air_density_kg_m3 = density_kg_m3
	profile_exponent = height_exponent
	elapsed_time_s = 0.0
	gust_start_s = -1.0
	gust_duration_s = 0.0
	gust_increment_m_s = 0.0
	return {"valid": true, "reference_speed_m_s": reference_speed_m_s, "reference_height_m": reference_height_m, "wind_direction_deg": wind_direction_deg}


func set_gust(start_time_s: float, duration_s: float, speed_increment_m_s: float) -> Dictionary:
	if start_time_s < 0.0 or duration_s <= 0.0 or speed_increment_m_s < 0.0:
		return _error("돌풍 시작은 0 이상, 지속시간 양수, 속도 증분 0 이상이어야 해.")
	gust_start_s = start_time_s
	gust_duration_s = duration_s
	gust_increment_m_s = speed_increment_m_s
	return {"valid": true, "gust_start_s": start_time_s, "gust_duration_s": duration_s, "peak_speed_increment_m_s": speed_increment_m_s, "shape": "half_sine"}


func set_wind_direction(direction_deg: float) -> Dictionary:
	if not is_finite(direction_deg):
		return _error("풍향은 유한한 도(degree) 값이어야 해.")
	wind_direction_deg = direction_deg
	return {"valid": true, "wind_direction_deg": wind_direction_deg}


func advance_time(delta_s: float) -> Dictionary:
	if delta_s <= 0.0 or not is_finite(delta_s):
		return _error("풍하중 시간 간격은 양수여야 해.")
	elapsed_time_s += delta_s
	return {"valid": true, "time_s": elapsed_time_s, "wind_speed_at_reference_m_s": wind_speed_at_height(reference_height_m, elapsed_time_s)}


func wind_speed_at_height(height_m: float, time_s: float = -1.0) -> float:
	if height_m < 0.0:
		return NAN
	var time_value := elapsed_time_s if time_s < 0.0 else time_s
	var gust := 0.0
	if gust_duration_s > 0.0 and time_value >= gust_start_s and time_value <= gust_start_s + gust_duration_s:
		var phase := (time_value - gust_start_s) / gust_duration_s
		gust = gust_increment_m_s * sin(PI * phase)
	var reference_speed := maxf(0.0, reference_speed_m_s + gust)
	if height_m == 0.0 and profile_exponent > 0.0:
		return 0.0
	if profile_exponent == 0.0:
		return reference_speed
	return reference_speed * pow(height_m / reference_height_m, profile_exponent)


func dynamic_pressure_pa(height_m: float, time_s: float = -1.0) -> float:
	var speed := wind_speed_at_height(height_m, time_s)
	return 0.5 * air_density_kg_m3 * speed * speed


func build_frame_nodal_loads(nodes: Array, elements: Array, exposed_surfaces: Dictionary, time_s: float = -1.0) -> Dictionary:
	var nodes_by_id: Dictionary = {}
	for node in nodes:
		if not node is Dictionary or not node.has("id") or not node.has("x_m") or not node.has("y_m"):
			return _error("풍하중 절점에는 id와 SI 좌표 x_m/y_m이 필요해.")
		nodes_by_id[str(node["id"])] = node
	var wind_angle := deg_to_rad(wind_direction_deg)
	var wind_direction := Vector2(cos(wind_angle), sin(wind_angle))
	var nodal_loads: Dictionary = {}
	var element_loads_local: Dictionary = {}
	var resultant := Vector2.ZERO
	var maximum_pressure := 0.0
	for element in elements:
		var element_id := str(element.get("id", ""))
		if not exposed_surfaces.has(element_id):
			continue
		var node_i_id := str(element.get("node_i", ""))
		var node_j_id := str(element.get("node_j", ""))
		if not nodes_by_id.has(node_i_id) or not nodes_by_id.has(node_j_id):
			return _error("풍하중 표면 %s의 절점 참조가 없어." % element_id)
		var surface: Dictionary = exposed_surfaces[element_id]
		var width := float(surface.get("width_m", 0.0))
		var outward_normal: Vector2 = surface.get("outward_normal_global", Vector2.ZERO)
		if width <= 0.0 or not outward_normal.is_finite() or outward_normal.length_squared() < 1.0e-12:
			return _error("요소 %s 풍압면에 양수 폭과 외향 단위법선이 필요해." % element_id)
		outward_normal = outward_normal.normalized()
		var incidence := maxf(0.0, -wind_direction.dot(outward_normal))
		if incidence <= 0.0:
			continue
		var point_i := Vector2(float(nodes_by_id[node_i_id]["x_m"]), float(nodes_by_id[node_i_id]["y_m"]))
		var point_j := Vector2(float(nodes_by_id[node_j_id]["x_m"]), float(nodes_by_id[node_j_id]["y_m"]))
		var delta := point_j - point_i
		var length_m := delta.length()
		if length_m <= 1.0e-9:
			return _error("풍하중 요소 %s 길이가 0이야." % element_id)
		var axis_x := delta / length_m
		var axis_y := Vector2(-axis_x.y, axis_x.x)
		var local_load: Array[float] = [0.0,0.0,0.0,0.0,0.0,0.0]
		var total_steps := 64
		var integration_step := length_m / float(total_steps)
		for sample in range(total_steps + 1):
			var ratio := float(sample) / float(total_steps)
			var height := maxf(0.0, lerpf(point_i.y, point_j.y, ratio))
			var speed := wind_speed_at_height(height, time_s)
			var pressure := 0.5 * air_density_kg_m3 * speed * speed * float(surface.get("pressure_coefficient", 1.0)) * incidence
			if not is_finite(pressure) or pressure < 0.0:
				return _error("요소 %s 풍압 계수가 올바르지 않아." % element_id)
			maximum_pressure = maxf(maximum_pressure, pressure)
			var q_global := wind_direction * pressure * width
			var qx := q_global.dot(axis_x)
			var qy := q_global.dot(axis_y)
			var weight := 1.0 if sample == 0 or sample == total_steps else (4.0 if sample % 2 == 1 else 2.0)
			var scale := weight * integration_step / 3.0
			var axial_i := 1.0 - ratio
			var axial_j := ratio
			var bend_i := 1.0 - 3.0*ratio*ratio + 2.0*ratio*ratio*ratio
			var rotate_i := length_m * (ratio - 2.0*ratio*ratio + ratio*ratio*ratio)
			var bend_j := 3.0*ratio*ratio - 2.0*ratio*ratio*ratio
			var rotate_j := length_m * (-ratio*ratio + ratio*ratio*ratio)
			local_load[0] += axial_i*qx*scale
			local_load[1] += bend_i*qy*scale
			local_load[2] += rotate_i*qy*scale
			local_load[3] += axial_j*qx*scale
			local_load[4] += bend_j*qy*scale
			local_load[5] += rotate_j*qy*scale
			resultant += q_global * scale
		var transform := _transformation(axis_x.x, axis_x.y)
		var dofs := [0,1,2,3,4,5]
		var global_load := [0.0,0.0,0.0,0.0,0.0,0.0]
		for row in range(6):
			for column in range(6):
				global_load[column] += transform[row][column] * local_load[row]
		_add_nodal_load(nodal_loads, node_i_id, Vector3(global_load[0],global_load[1],global_load[2]))
		_add_nodal_load(nodal_loads, node_j_id, Vector3(global_load[3],global_load[4],global_load[5]))
		element_loads_local[element_id] = local_load
	return {
		"valid": true, "nodal_loads": nodal_loads, "element_loads_local_by_id": element_loads_local,
		"resultant_force_xy_n": resultant, "maximum_pressure_pa": maximum_pressure,
		"wind_speed_at_reference_m_s": wind_speed_at_height(reference_height_m, time_s),
		"wind_direction_deg": wind_direction_deg,
		"source": "dynamic_pressure_times_surface_coefficient_and_windward_projection",
		"units": {"speed":"m/s","pressure":"Pa","force":"N","length":"m"}
	}


func _add_nodal_load(loads: Dictionary, node_id: String, force: Vector3) -> void:
	var current: Vector3 = loads.get(node_id, Vector3.ZERO)
	loads[node_id] = current + force


func _transformation(cosine: float, sine: float) -> Array:
	var matrix: Array = []
	for row in range(6):
		var values: Array[float] = []
		values.resize(6)
		values.fill(0.0)
		matrix.append(values)
	for offset in [0,3]:
		matrix[offset][offset] = cosine
		matrix[offset][offset+1] = sine
		matrix[offset+1][offset] = -sine
		matrix[offset+1][offset+1] = cosine
		matrix[offset+2][offset+2] = 1.0
	return matrix


func _error(message: String) -> Dictionary:
	return {"valid": false, "error": message}
