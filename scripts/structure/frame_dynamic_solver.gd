extends RefCounted
class_name FrameDynamicSolver

## SI 2D 프레임의 선형 시간 이력 해석. Newmark 평균가속도(β=1/4, γ=1/2)를 사용해.
const FRAME_SOLVER = preload("res://scripts/structure/linear_frame_solver.gd")
const DOF_PER_NODE: int = 3
const BETA: float = 0.25
const GAMMA: float = 0.5


func simulate(
	nodes: Array,
	elements: Array,
	materials: Dictionary,
	supports: Dictionary,
	loads_by_step: Array,
	delta_t_s: float,
	damping_ratio: float = 0.02,
	reference_frequency_hz: float = 1.0
) -> Dictionary:
	if nodes.is_empty() or elements.is_empty() or loads_by_step.is_empty():
		return _error("시간 이력에는 절점, 요소, 하중 표본이 필요해.")
	if delta_t_s <= 0.0 or damping_ratio < 0.0 or reference_frequency_hz <= 0.0:
		return _error("dt와 기준 주파수는 양수, 감쇠비는 0 이상이어야 해.")
	var zero_loads: Dictionary = {}
	var baseline: Dictionary = FRAME_SOLVER.new().analyze(nodes, elements, materials, zero_loads, supports)
	if not bool(baseline.get("valid", false)):
		return _error("동적 모델 초기 강성 해석 실패: %s" % str(baseline.get("error", "")))
	var node_ids: Array = baseline["node_ids"]
	var dof_count: int = node_ids.size() * DOF_PER_NODE
	var stiffness: Array = baseline["global_stiffness_matrix_n_m"]
	var mass_data := _assemble_mass(nodes, elements, materials, node_ids)
	if not bool(mass_data.get("valid", false)):
		return mass_data
	var mass: Array = mass_data["global_mass_matrix_kg"]
	var fixed_dofs := _fixed_dofs(node_ids, supports)
	var free_dofs: Array[int] = []
	for dof in range(dof_count):
		if not fixed_dofs.has(dof):
			free_dofs.append(dof)
	if free_dofs.is_empty():
		return _error("동적 모델에 자유도가 없어.")
	var reduced_stiffness := _reduce_matrix(stiffness, free_dofs)
	var reduced_mass := _reduce_matrix(mass, free_dofs)
	var omega_ref := TAU * reference_frequency_hz
	var damping := _scale_matrix(reduced_mass, 2.0 * damping_ratio * omega_ref)
	var acceleration_factor := 1.0 / (BETA * delta_t_s * delta_t_s)
	var velocity_factor := GAMMA / (BETA * delta_t_s)
	var effective_stiffness := _zero_matrix(free_dofs.size(), free_dofs.size())
	for row in range(free_dofs.size()):
		for column in range(free_dofs.size()):
			effective_stiffness[row][column] = reduced_stiffness[row][column] + acceleration_factor * reduced_mass[row][column] + velocity_factor * damping[row][column]
	var displacement := _zero_vector(free_dofs.size())
	var velocity := _zero_vector(free_dofs.size())
	var acceleration := _zero_vector(free_dofs.size())
	var history: Array[Dictionary] = [_snapshot(0.0, node_ids, free_dofs, displacement, dof_count)]
	var peak_displacement := 0.0
	var peak_lateral_displacement := 0.0
	for step in range(loads_by_step.size()):
		var full_force := _load_vector(loads_by_step[step], node_ids)
		if not bool(full_force.get("valid", false)):
			return _error("시간 단계 %d 하중 오류: %s" % [step, str(full_force.get("error", ""))])
		var reduced_force := _reduce_vector(full_force["values"], free_dofs)
		var right_hand_side := _zero_vector(free_dofs.size())
		for row in range(free_dofs.size()):
			right_hand_side[row] = reduced_force[row]
			for column in range(free_dofs.size()):
				var inertial_term := acceleration_factor * displacement[column] + (1.0 / (BETA * delta_t_s)) * velocity[column] + (1.0 / (2.0 * BETA) - 1.0) * acceleration[column]
				var damping_term := velocity_factor * displacement[column] + (GAMMA / BETA - 1.0) * velocity[column] + delta_t_s * (GAMMA / (2.0 * BETA) - 1.0) * acceleration[column]
				right_hand_side[row] += reduced_mass[row][column] * inertial_term + damping[row][column] * damping_term
		var solved: Dictionary = FRAME_SOLVER.new().solve_linear_system(effective_stiffness, right_hand_side)
		if not bool(solved.get("valid", false)):
			return _error("동적 단계 %d의 Newmark 선형계 풀이 실패: %s" % [step, str(solved.get("error", ""))])
		var next_displacement: Array[float] = solved["solution"]
		var next_acceleration := _zero_vector(free_dofs.size())
		var next_velocity := _zero_vector(free_dofs.size())
		for index in range(free_dofs.size()):
			next_acceleration[index] = acceleration_factor * (next_displacement[index] - displacement[index]) - velocity[index] / (BETA * delta_t_s) - (1.0 / (2.0 * BETA) - 1.0) * acceleration[index]
			next_velocity[index] = velocity[index] + delta_t_s * ((1.0 - GAMMA) * acceleration[index] + GAMMA * next_acceleration[index])
		displacement = next_displacement
		velocity = next_velocity
		acceleration = next_acceleration
		var time_s := float(step + 1) * delta_t_s
		var sample := _snapshot(time_s, node_ids, free_dofs, displacement, dof_count)
		history.append(sample)
		peak_displacement = maxf(peak_displacement, float(sample["maximum_displacement_m"]))
		peak_lateral_displacement = maxf(peak_lateral_displacement, float(sample["maximum_lateral_displacement_m"]))
	return {
		"valid": true, "method": "linear_frame_newmark_average_acceleration",
		"source": "SI frame stiffness + consistent element mass + supplied nodal force history",
		"damping_model": "mass_proportional_rayleigh_at_reference_frequency",
		"damping_ratio": damping_ratio, "reference_frequency_hz": reference_frequency_hz,
		"delta_t_s": delta_t_s, "sample_count": history.size(), "duration_s": float(loads_by_step.size()) * delta_t_s,
		"nodal_lumped_mass_kg": mass_data["nodal_lumped_mass_kg"],
		"peak_displacement_m": peak_displacement,
		"peak_lateral_displacement_m": peak_lateral_displacement,
		"time_history": history
	}


func base_excitation_loads(nodal_lumped_mass_kg: Dictionary, ground_acceleration_xy_m_s2: Vector2) -> Dictionary:
	if not ground_acceleration_xy_m_s2.is_finite():
		return _error("기초 가속도는 유한한 m/s² 값이어야 해.")
	var loads: Dictionary = {}
	for node_id in nodal_lumped_mass_kg:
		var nodal_mass := float(nodal_lumped_mass_kg[node_id])
		if nodal_mass < 0.0 or not is_finite(nodal_mass):
			return _error("절점 질량은 유한한 0 이상 kg 값이어야 해.")
		loads[str(node_id)] = Vector3(-nodal_mass * ground_acceleration_xy_m_s2.x, -nodal_mass * ground_acceleration_xy_m_s2.y, 0.0)
	return {"valid": true, "loads": loads, "source": "equivalent_base_excitation_inertial_load", "units": "N"}


func combine_nodal_loads(loads_a: Dictionary, loads_b: Dictionary) -> Dictionary:
	var combined := loads_a.duplicate(true)
	for node_id in loads_b:
		var current: Vector3 = combined.get(node_id, Vector3.ZERO)
		var added: Vector3 = loads_b[node_id]
		if not current.is_finite() or not added.is_finite():
			return _error("합산할 절점 하중은 유한한 N 값이어야 해.")
		combined[node_id] = current + added
	return {"valid": true, "loads": combined, "units": "N"}


func _assemble_mass(nodes: Array, elements: Array, materials: Dictionary, node_ids: Array) -> Dictionary:
	var index_by_id: Dictionary = {}
	var point_by_id: Dictionary = {}
	for i in range(node_ids.size()):
		index_by_id[str(node_ids[i])] = i
	for node in nodes:
		point_by_id[str(node["id"])] = Vector2(float(node["x_m"]), float(node["y_m"]))
	var total_dofs := node_ids.size() * DOF_PER_NODE
	var global_mass := _zero_matrix(total_dofs, total_dofs)
	var nodal_lumped: Dictionary = {}
	for node_id in node_ids:
		nodal_lumped[str(node_id)] = 0.0
	for element in elements:
		var material: Dictionary = materials[str(element["material_id"])]
		var node_i := str(element["node_i"])
		var node_j := str(element["node_j"])
		var delta: Vector2 = point_by_id[node_j] - point_by_id[node_i]
		var length_m := delta.length()
		var area := float(element["area_m2"])
		var density := float(material.get("density_kg_m3", 0.0))
		if length_m <= 0.0 or area <= 0.0 or density <= 0.0:
			return _error("동적 질량 계산에 유효한 길이, 면적, 재료 밀도가 필요해.")
		var mass_scale := density * area * length_m / 420.0
		var local_mass := _zero_matrix(6, 6)
		local_mass[0][0] = 140.0 * mass_scale
		local_mass[0][3] = 70.0 * mass_scale
		local_mass[3][0] = 70.0 * mass_scale
		local_mass[3][3] = 140.0 * mass_scale
		var l := length_m
		var bend := [
			[156.0, 22.0*l, 54.0, -13.0*l],
			[22.0*l, 4.0*l*l, 13.0*l, -3.0*l*l],
			[54.0, 13.0*l, 156.0, -22.0*l],
			[-13.0*l, -3.0*l*l, -22.0*l, 4.0*l*l]
		]
		var bend_dofs := [1, 2, 4, 5]
		for row in range(4):
			for column in range(4):
				local_mass[bend_dofs[row]][bend_dofs[column]] = float(bend[row][column]) * mass_scale
		var axis := delta / length_m
		var transform := _transformation(axis.x, axis.y)
		var global_element_mass := _congruence(local_mass, transform)
		var index_i: int = index_by_id[node_i]
		var index_j: int = index_by_id[node_j]
		var dofs := [index_i*3,index_i*3+1,index_i*3+2,index_j*3,index_j*3+1,index_j*3+2]
		for row in range(6):
			for column in range(6):
				global_mass[dofs[row]][dofs[column]] += global_element_mass[row][column]
		var element_mass := density * area * length_m
		nodal_lumped[node_i] = float(nodal_lumped[node_i]) + element_mass * 0.5
		nodal_lumped[node_j] = float(nodal_lumped[node_j]) + element_mass * 0.5
	return {"valid": true, "global_mass_matrix_kg": global_mass, "nodal_lumped_mass_kg": nodal_lumped}


func _fixed_dofs(node_ids: Array, supports: Dictionary) -> Dictionary:
	var fixed: Dictionary = {}
	for node_id in supports:
		var index := node_ids.find(str(node_id))
		var conditions: Array = supports[node_id]
		for dof in range(DOF_PER_NODE):
			if bool(conditions[dof]):
				fixed[index * DOF_PER_NODE + dof] = true
	return fixed


func _load_vector(loads: Variant, node_ids: Array) -> Dictionary:
	if not loads is Dictionary:
		return {"valid": false, "error": "절점 하중 표본은 Dictionary여야 해."}
	var values := _zero_vector(node_ids.size() * DOF_PER_NODE)
	for node_id in loads:
		var index := node_ids.find(str(node_id))
		if index < 0:
			return {"valid": false, "error": "하중에서 알 수 없는 절점을 참조해: %s" % str(node_id)}
		var force: Vector3 = loads[node_id]
		if not force.is_finite():
			return {"valid": false, "error": "비유한 하중: %s" % str(node_id)}
		values[index * 3] += force.x
		values[index * 3 + 1] += force.y
		values[index * 3 + 2] += force.z
	return {"valid": true, "values": values}


func _snapshot(time_s: float, node_ids: Array, free_dofs: Array[int], free_values: Array[float], total_dofs: int) -> Dictionary:
	var full := _zero_vector(total_dofs)
	for i in range(free_dofs.size()):
		full[free_dofs[i]] = free_values[i]
	var nodal: Dictionary = {}
	var maximum := 0.0
	var maximum_lateral := 0.0
	for i in range(node_ids.size()):
		var displacement := Vector3(full[i*3], full[i*3+1], full[i*3+2])
		nodal[str(node_ids[i])] = displacement
		maximum = maxf(maximum, Vector2(displacement.x, displacement.y).length())
		maximum_lateral = maxf(maximum_lateral, absf(displacement.x))
	return {"time_s":time_s,"node_displacements_m_rad":nodal,"maximum_displacement_m":maximum,"maximum_lateral_displacement_m":maximum_lateral}


func _transformation(cosine: float, sine: float) -> Array:
	var matrix := _zero_matrix(6, 6)
	for offset in [0, 3]:
		matrix[offset][offset] = cosine
		matrix[offset][offset+1] = sine
		matrix[offset+1][offset] = -sine
		matrix[offset+1][offset+1] = cosine
		matrix[offset+2][offset+2] = 1.0
	return matrix


func _congruence(local_matrix: Array, transform: Array) -> Array:
	var intermediate := _zero_matrix(6, 6)
	var global_matrix := _zero_matrix(6, 6)
	for row in range(6):
		for column in range(6):
			for inner in range(6):
				intermediate[row][column] += local_matrix[row][inner] * transform[inner][column]
	for row in range(6):
		for column in range(6):
			for inner in range(6):
				global_matrix[row][column] += transform[inner][row] * intermediate[inner][column]
	return global_matrix


func _reduce_matrix(matrix: Array, free_dofs: Array[int]) -> Array:
	var result := _zero_matrix(free_dofs.size(), free_dofs.size())
	for i in range(free_dofs.size()):
		for j in range(free_dofs.size()):
			result[i][j] = matrix[free_dofs[i]][free_dofs[j]]
	return result


func _reduce_vector(vector: Array[float], free_dofs: Array[int]) -> Array[float]:
	var result := _zero_vector(free_dofs.size())
	for i in range(free_dofs.size()):
		result[i] = vector[free_dofs[i]]
	return result


func _scale_matrix(matrix: Array, factor: float) -> Array:
	var result := _zero_matrix(matrix.size(), matrix.size())
	for i in range(matrix.size()):
		for j in range(matrix.size()):
			result[i][j] = float(matrix[i][j]) * factor
	return result


func _zero_matrix(rows: int, columns: int) -> Array:
	var result: Array = []
	for i in range(rows):
		var row: Array[float] = []
		row.resize(columns)
		row.fill(0.0)
		result.append(row)
	return result


func _zero_vector(size: int) -> Array[float]:
	var result: Array[float] = []
	result.resize(size)
	result.fill(0.0)
	return result


func _error(message: String) -> Dictionary:
	return {"valid": false, "error": message}
