extends RefCounted
class_name LinearFrameSolver

## SI 단위 2D Euler-Bernoulli 보-기둥 요소 기반 선형 정적 구조해석기.
## 입력 좌표는 m, 하중은 N/Nm, E는 Pa, A는 m², I는 m⁴ 단위다.
## 자체중량과 동적 효과는 자동으로 더하지 않는다. 모든 하중은 loads에 명시한다.

const DOF_PER_NODE: int = 3
const SINGULAR_TOLERANCE: float = 1.0e-12


func analyze(
	nodes: Array,
	elements: Array,
	materials: Dictionary,
	loads: Dictionary,
	supports: Dictionary,
	connections: Array = [],
	thermal_strains_by_element: Dictionary = {},
	element_loads_local_by_id: Dictionary = {}
) -> Dictionary:
	var node_ids: Array[String] = []
	var node_positions: Array[Vector2] = []
	var node_index_by_id: Dictionary = {}
	for node in nodes:
		if not node is Dictionary or not node.has("id") or not node.has("x_m") or not node.has("y_m"):
			return _error("절점에는 id, x_m, y_m이 필요해.")
		var node_id := str(node["id"])
		if node_id.is_empty() or node_index_by_id.has(node_id):
			return _error("절점 ID가 비었거나 중복돼: %s" % node_id)
		var position := Vector2(float(node["x_m"]), float(node["y_m"]))
		if not position.is_finite():
			return _error("절점 좌표가 유한한 SI 값이 아니야: %s" % node_id)
		node_index_by_id[node_id] = node_ids.size()
		node_ids.append(node_id)
		node_positions.append(position)
	if node_ids.is_empty():
		return _error("해석할 절점이 없어.")
	if elements.is_empty():
		return _error("해석할 요소가 없어.")

	var dof_count := node_ids.size() * DOF_PER_NODE
	var global_stiffness := _zero_matrix(dof_count, dof_count)
	var load_vector := _zero_vector(dof_count)
	for node_index in range(node_ids.size()):
		var node_id: String = node_ids[node_index]
		var nodal_load: Vector3 = loads.get(node_id, Vector3.ZERO)
		if not nodal_load.is_finite():
			return _error("절점 하중이 유한하지 않아: %s" % node_id)
		var offset := node_index * DOF_PER_NODE
		load_vector[offset] += nodal_load.x
		load_vector[offset + 1] += nodal_load.y
		load_vector[offset + 2] += nodal_load.z

	var element_cache: Array[Dictionary] = []
	var element_ids: Dictionary = {}
	for element in elements:
		var validation_error := _validate_element(element, node_index_by_id, materials, element_ids)
		if not validation_error.is_empty():
			return _error(validation_error)
		var element_id: String = str(element["id"])
		var node_i: String = str(element["node_i"])
		var node_j: String = str(element["node_j"])
		var index_i: int = int(node_index_by_id[node_i])
		var index_j: int = int(node_index_by_id[node_j])
		var delta: Vector2 = node_positions[index_j] - node_positions[index_i]
		var length_m := delta.length()
		if length_m <= 1.0e-9:
			return _error("요소 길이가 0이거나 너무 작아: %s" % element_id)
		var cosine := delta.x / length_m
		var sine := delta.y / length_m
		var material: Dictionary = materials[str(element["material_id"])]
		var elastic_modulus_pa := float(material["elastic_modulus_pa"])
		# 재료 사전은 해석 중 원본이 바뀌어도 결과가 흔들리지 않도록 요소별로 복사해 둬.
		var material_properties: Dictionary = material.duplicate(true)
		var area_m2 := float(element["area_m2"])
		var inertia_m4 := float(element["inertia_m4"])
		var depth_m := float(element["depth_m"])
		var local_stiffness := _local_stiffness(elastic_modulus_pa, area_m2, inertia_m4, length_m)
		var transform := _transformation(cosine, sine)
		var global_element_stiffness := _congruence(local_stiffness, transform)
		var element_dofs: Array[int] = [
			index_i * 3, index_i * 3 + 1, index_i * 3 + 2,
			index_j * 3, index_j * 3 + 1, index_j * 3 + 2
		]
		_assemble_matrix(global_stiffness, global_element_stiffness, element_dofs)
		var thermal_strain := float(thermal_strains_by_element.get(element_id, 0.0))
		if not is_finite(thermal_strain):
			return _error("요소 %s의 열변형률이 유한하지 않아." % element_id)
		var thermal_local_load := _zero_vector(6)
		thermal_local_load[0] = -elastic_modulus_pa * area_m2 * thermal_strain
		thermal_local_load[3] = elastic_modulus_pa * area_m2 * thermal_strain
		var element_load: Array = element_loads_local_by_id.get(element_id, [0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
		if element_load.size() != 6:
			return _error("요소 %s의 등가 절점하중은 로컬 6자유도 값이어야 해." % element_id)
		var local_applied_load := _zero_vector(6)
		for local_dof in range(6):
			if not is_finite(float(element_load[local_dof])):
				return _error("요소 %s의 등가 절점하중이 유한하지 않아." % element_id)
			local_applied_load[local_dof] = thermal_local_load[local_dof] + float(element_load[local_dof])
			for global_dof in range(6):
				load_vector[element_dofs[global_dof]] += transform[local_dof][global_dof] * local_applied_load[local_dof]
		element_cache.append({
			"id": element_id,
			"material_id": str(element["material_id"]),
			"material_properties": material_properties,
			"node_i": node_i,
			"node_j": node_j,
			"length_m": length_m,
			"cosine": cosine,
			"sine": sine,
			"elastic_modulus_pa": elastic_modulus_pa,
			"area_m2": area_m2,
			"inertia_m4": inertia_m4,
			"depth_m": depth_m,
			"local_stiffness": local_stiffness,
			"thermal_strain": thermal_strain,
			"local_applied_load": local_applied_load,
			"transform": transform,
			"dofs": element_dofs
		})

	var connection_cache: Array[Dictionary] = []
	var connection_ids: Dictionary = {}
	for connection in connections:
		var validation_error := _validate_connection(connection, node_index_by_id, connection_ids)
		if not validation_error.is_empty():
			return _error(validation_error)
		var connection_id := str(connection["id"])
		var node_a := str(connection["node_a"])
		var node_b := str(connection["node_b"])
		var index_a: int = int(node_index_by_id[node_a])
		var index_b: int = int(node_index_by_id[node_b])
		var offset_a := index_a * DOF_PER_NODE
		var offset_b := index_b * DOF_PER_NODE
		var translational_stiffness := float(connection["translational_stiffness_n_m"])
		var rotational_stiffness := float(connection["rotational_stiffness_nm_rad"])
		for axis in range(2):
			var dof_a := offset_a + axis
			var dof_b := offset_b + axis
			global_stiffness[dof_a][dof_a] += translational_stiffness
			global_stiffness[dof_b][dof_b] += translational_stiffness
			global_stiffness[dof_a][dof_b] -= translational_stiffness
			global_stiffness[dof_b][dof_a] -= translational_stiffness
		var rotation_a := offset_a + 2
		var rotation_b := offset_b + 2
		global_stiffness[rotation_a][rotation_a] += rotational_stiffness
		global_stiffness[rotation_b][rotation_b] += rotational_stiffness
		global_stiffness[rotation_a][rotation_b] -= rotational_stiffness
		global_stiffness[rotation_b][rotation_a] -= rotational_stiffness
		var axis: Vector2 = connection.get("local_axis", Vector2.RIGHT)
		connection_cache.append({
			"id": connection_id,
			"node_a": node_a,
			"node_b": node_b,
			"translational_stiffness_n_m": translational_stiffness,
			"rotational_stiffness_nm_rad": rotational_stiffness,
			"axis": axis.normalized()
		})

	var fixed_dofs: Dictionary = {}
	for node_id_variant in supports:
		var node_id := str(node_id_variant)
		if not node_index_by_id.has(node_id):
			return _error("경계조건에서 모르는 절점 ID를 참조해: %s" % node_id)
		var restraints: Variant = supports[node_id_variant]
		if not restraints is Array or restraints.size() != DOF_PER_NODE:
			return _error("절점 %s의 경계조건은 [ux 고정, uy 고정, rz 고정] 3개 값이어야 해." % node_id)
		var node_offset: int = int(node_index_by_id[node_id]) * DOF_PER_NODE
		for local_dof in range(DOF_PER_NODE):
			if bool(restraints[local_dof]):
				fixed_dofs[node_offset + local_dof] = true

	var free_dofs: Array[int] = []
	for dof in range(dof_count):
		if not fixed_dofs.has(dof):
			free_dofs.append(dof)
	var reduced_stiffness := _reduce_matrix(global_stiffness, free_dofs)
	var reduced_load := _reduce_vector(load_vector, free_dofs)
	var reduced_displacement := _solve(reduced_stiffness, reduced_load)
	if not bool(reduced_displacement.get("valid", false)):
		return _error(str(reduced_displacement.get("error", "강성 행렬 풀이에 실패했어.")))

	var displacement_vector := _zero_vector(dof_count)
	var free_values: Array = reduced_displacement["solution"]
	for index in range(free_dofs.size()):
		displacement_vector[free_dofs[index]] = float(free_values[index])
	for value in displacement_vector:
		if not is_finite(float(value)):
			return _error("변위 해가 유한하지 않아.")

	var node_displacements: Dictionary = {}
	for node_index in range(node_ids.size()):
		var offset := node_index * DOF_PER_NODE
		node_displacements[node_ids[node_index]] = Vector3(
			displacement_vector[offset],
			displacement_vector[offset + 1],
			displacement_vector[offset + 2]
		)
	var internal_force := _matrix_vector(global_stiffness, displacement_vector)
	var reactions: Dictionary = {}
	for dof in fixed_dofs:
		var node_index := int(dof) / DOF_PER_NODE
		var local_dof := int(dof) % DOF_PER_NODE
		var node_id: String = node_ids[node_index]
		var reaction: Vector3 = reactions.get(node_id, Vector3.ZERO)
		if local_dof == 0:
			reaction.x = internal_force[int(dof)] - load_vector[int(dof)]
		elif local_dof == 1:
			reaction.y = internal_force[int(dof)] - load_vector[int(dof)]
		else:
			reaction.z = internal_force[int(dof)] - load_vector[int(dof)]
		reactions[node_id] = reaction

	var element_results: Dictionary = {}
	for data in element_cache:
		var local_displacement := _local_displacement(displacement_vector, data["dofs"], data["transform"])
		var local_end_forces := _matrix_vector(data["local_stiffness"], local_displacement)
		for local_dof in range(6):
			local_end_forces[local_dof] -= float(data["local_applied_load"][local_dof])
		var axial_i := -float(local_end_forces[0])
		var axial_j := float(local_end_forces[3])
		var shear_i := float(local_end_forces[1])
		var shear_j := float(local_end_forces[4])
		var moment_i := float(local_end_forces[2])
		var moment_j := float(local_end_forces[5])
		var area_m2: float = data["area_m2"]
		var inertia_m4: float = data["inertia_m4"]
		var half_depth: float = float(data["depth_m"]) * 0.5
		var elastic_modulus_pa: float = data["elastic_modulus_pa"]
		var stress_i_top := axial_i / area_m2 - moment_i * half_depth / inertia_m4
		var stress_i_bottom := axial_i / area_m2 + moment_i * half_depth / inertia_m4
		var stress_j_top := axial_j / area_m2 - moment_j * half_depth / inertia_m4
		var stress_j_bottom := axial_j / area_m2 + moment_j * half_depth / inertia_m4
		var average_axial_force := (axial_i + axial_j) * 0.5
		var axial_strain := average_axial_force / (elastic_modulus_pa * area_m2)
		var maximum_normal_strain := maxf(
			maxf(absf(stress_i_top), absf(stress_i_bottom)),
			maxf(absf(stress_j_top), absf(stress_j_bottom))
		) / elastic_modulus_pa
		var internal_deflection := _maximum_internal_deflection(local_displacement, float(data["length_m"]))
		var material_evaluation := _evaluate_material_limits(
			data["material_properties"],
			[stress_i_top, stress_i_bottom, stress_j_top, stress_j_bottom],
			[shear_i, shear_j], area_m2, maximum_normal_strain
		)
		element_results[data["id"]] = {
			"material_id": data["material_id"],
			"node_i": data["node_i"],
			"node_j": data["node_j"],
			"length_m": data["length_m"],
			"local_displacements_m_rad": local_displacement,
			"axial_force_i_n": axial_i,
			"axial_force_j_n": axial_j,
			"shear_force_i_n": shear_i,
			"shear_force_j_n": shear_j,
			"bending_moment_i_nm": moment_i,
			"bending_moment_j_nm": moment_j,
			"normal_stress_i_top_pa": stress_i_top,
			"normal_stress_i_bottom_pa": stress_i_bottom,
			"normal_stress_j_top_pa": stress_j_top,
			"normal_stress_j_bottom_pa": stress_j_bottom,
			"axial_strain": axial_strain,
			"maximum_normal_strain": maximum_normal_strain,
			"maximum_internal_deflection_m": internal_deflection,
			"thermal_strain": data["thermal_strain"],
			"material_limit_evaluation": material_evaluation
		}

	var connection_results: Dictionary = {}
	for data in connection_cache:
		var displacement_a: Vector3 = node_displacements[data["node_a"]]
		var displacement_b: Vector3 = node_displacements[data["node_b"]]
		var relative_translation := Vector2(displacement_b.x - displacement_a.x, displacement_b.y - displacement_a.y)
		var axis: Vector2 = data["axis"]
		var normal_axis := Vector2(-axis.y, axis.x)
		var axial_force := float(data["translational_stiffness_n_m"]) * relative_translation.dot(axis)
		var shear_force := float(data["translational_stiffness_n_m"]) * relative_translation.dot(normal_axis)
		var moment := float(data["rotational_stiffness_nm_rad"]) * (displacement_b.z - displacement_a.z)
		connection_results[data["id"]] = {
			"source": "linear_static_structural_solver",
			"axial_force_n": axial_force,
			"tensile_force_n": maxf(axial_force, 0.0),
			"compression_force_n": maxf(-axial_force, 0.0),
			"shear_force_n": absf(shear_force),
			"signed_shear_force_n": shear_force,
			"moment_nm": absf(moment),
			"signed_moment_nm": moment,
			"relative_translation_m": relative_translation.length(),
			"relative_rotation_rad": displacement_b.z - displacement_a.z
		}

	return {
		"valid": true,
		"error": "",
		"units": {"length": "m", "force": "N", "moment": "N·m", "stress": "Pa", "strain": "1", "rotation": "rad"},
		"material_model_note": "Poisson ratio is stored with the material but is not used by this 2D Euler-Bernoulli frame formulation. Shear stress demand is |V|/A and is an average-section proxy.",
		"node_ids": node_ids,
		"global_stiffness_matrix_n_m": global_stiffness,
		"load_vector_si": load_vector,
		"displacement_vector_si": displacement_vector,
		"node_displacements": node_displacements,
		"support_reactions": reactions,
		"element_results": element_results,
		"connection_results": connection_results
	}


func _evaluate_material_limits(material: Dictionary, normal_stresses: Array, shear_forces: Array, area_m2: float, maximum_strain: float) -> Dictionary:
	var max_tension_pa := 0.0
	var max_compression_pa := 0.0
	for stress_variant in normal_stresses:
		var stress_pa := float(stress_variant)
		max_tension_pa = maxf(max_tension_pa, stress_pa)
		max_compression_pa = maxf(max_compression_pa, -stress_pa)
	var max_shear_stress_pa := maxf(absf(float(shear_forces[0])), absf(float(shear_forces[1]))) / area_m2
	var utilization := 0.0
	var ratios: Dictionary = {}
	for entry in [
		["tensile", "tensile_strength_pa", max_tension_pa],
		["compressive", "compressive_strength_pa", max_compression_pa],
		["shear", "shear_strength_pa", max_shear_stress_pa]
	]:
		var key: String = entry[0]
		var capacity_key: String = entry[1]
		if material.has(capacity_key) and material[capacity_key] != null:
			var capacity_pa := float(material[capacity_key])
			if capacity_pa > 0.0:
				var ratio := float(entry[2]) / capacity_pa
				ratios[key] = ratio
				utilization = maxf(utilization, ratio)
	var yield_ratio: Variant = null
	if material.has("yield_strength_pa") and material["yield_strength_pa"] != null:
		var yield_strength_pa := float(material["yield_strength_pa"])
		if yield_strength_pa > 0.0:
			yield_ratio = maxf(max_tension_pa, max_compression_pa) / yield_strength_pa
			ratios["yield"] = yield_ratio
			utilization = maxf(utilization, float(yield_ratio))
	var fracture_ratio := 0.0
	if material.has("fracture_limit_strain") and float(material["fracture_limit_strain"]) > 0.0:
		fracture_ratio = maximum_strain / float(material["fracture_limit_strain"])
		ratios["fracture_strain"] = fracture_ratio
		utilization = maxf(utilization, fracture_ratio)
	return {
		"source": "linear_static_structural_solver",
		"tensile_demand_pa": max_tension_pa,
		"compressive_demand_pa": max_compression_pa,
		"average_shear_demand_proxy_pa": max_shear_stress_pa,
		"maximum_normal_strain": maximum_strain,
		"yield_utilization": yield_ratio,
		"utilization_by_limit": ratios,
		"maximum_utilization": utilization,
		"exceeds_provided_limits": utilization > 1.0,
		"failure_prediction_note": "선형 정적 해석 수요와 제공된 대표 한계의 비교값이며, 동적 파괴 예측이나 인증 판정이 아님."
	}


func _validate_connection(connection: Variant, node_index_by_id: Dictionary, seen_ids: Dictionary) -> String:
	if not connection is Dictionary:
		return "접합 입력은 Dictionary여야 해."
	for key in ["id", "node_a", "node_b", "translational_stiffness_n_m", "rotational_stiffness_nm_rad"]:
		if not connection.has(key):
			return "접합에 %s 값이 없어." % key
	var connection_id := str(connection["id"])
	if connection_id.is_empty() or seen_ids.has(connection_id):
		return "접합 ID가 비었거나 중복돼: %s" % connection_id
	seen_ids[connection_id] = true
	var node_a := str(connection["node_a"])
	var node_b := str(connection["node_b"])
	if node_a == node_b or not node_index_by_id.has(node_a) or not node_index_by_id.has(node_b):
		return "접합 %s의 절점 참조가 잘못됐어." % connection_id
	for key in ["translational_stiffness_n_m", "rotational_stiffness_nm_rad"]:
		var stiffness := float(connection[key])
		if not is_finite(stiffness) or stiffness < 0.0:
			return "접합 %s의 %s는 유한한 0 이상 값이어야 해." % [connection_id, key]
	var axis: Vector2 = connection.get("local_axis", Vector2.RIGHT)
	if not axis.is_finite() or axis.length_squared() <= 1.0e-12:
		return "접합 %s의 local_axis는 유효한 방향이어야 해." % connection_id
	return ""


func _validate_element(element: Variant, node_index_by_id: Dictionary, materials: Dictionary, seen_ids: Dictionary) -> String:
	if not element is Dictionary:
		return "요소 입력은 Dictionary여야 해."
	for key in ["id", "node_i", "node_j", "material_id", "area_m2", "inertia_m4", "depth_m"]:
		if not element.has(key):
			return "프레임 요소에 %s 값이 없어." % key
	var element_id := str(element["id"])
	if element_id.is_empty() or seen_ids.has(element_id):
		return "요소 ID가 비었거나 중복돼: %s" % element_id
	seen_ids[element_id] = true
	var node_i := str(element["node_i"])
	var node_j := str(element["node_j"])
	if not node_index_by_id.has(node_i) or not node_index_by_id.has(node_j):
		return "요소 %s가 알 수 없는 절점을 참조해." % element_id
	if node_i == node_j:
		return "요소 양 끝에 같은 절점 ID가 지정됐어: %s" % element_id
	var material_id := str(element["material_id"])
	if not materials.has(material_id) or not materials[material_id] is Dictionary:
		return "요소 %s의 재료를 찾을 수 없어: %s" % [element_id, material_id]
	var material: Dictionary = materials[material_id]
	if not material.has("elastic_modulus_pa"):
		return "재료 %s에 elastic_modulus_pa가 없어." % material_id
	if float(material["elastic_modulus_pa"]) <= 0.0:
		return "재료 %s의 탄성계수는 양수여야 해." % material_id
	for key in ["area_m2", "inertia_m4", "depth_m"]:
		if float(element[key]) <= 0.0:
			return "요소 %s의 %s는 양수여야 해." % [element_id, key]
	return ""


func _local_stiffness(elastic_modulus_pa: float, area_m2: float, inertia_m4: float, length_m: float) -> Array:
	var axial := elastic_modulus_pa * area_m2 / length_m
	var bend_12 := 12.0 * elastic_modulus_pa * inertia_m4 / pow(length_m, 3.0)
	var bend_6 := 6.0 * elastic_modulus_pa * inertia_m4 / pow(length_m, 2.0)
	var bend_4 := 4.0 * elastic_modulus_pa * inertia_m4 / length_m
	var bend_2 := 2.0 * elastic_modulus_pa * inertia_m4 / length_m
	var matrix := _zero_matrix(6, 6)
	matrix[0][0] = axial
	matrix[0][3] = -axial
	matrix[3][0] = -axial
	matrix[3][3] = axial
	matrix[1][1] = bend_12
	matrix[1][2] = bend_6
	matrix[1][4] = -bend_12
	matrix[1][5] = bend_6
	matrix[2][1] = bend_6
	matrix[2][2] = bend_4
	matrix[2][4] = -bend_6
	matrix[2][5] = bend_2
	matrix[4][1] = -bend_12
	matrix[4][2] = -bend_6
	matrix[4][4] = bend_12
	matrix[4][5] = -bend_6
	matrix[5][1] = bend_6
	matrix[5][2] = bend_2
	matrix[5][4] = -bend_6
	matrix[5][5] = bend_4
	return matrix


func _transformation(cosine: float, sine: float) -> Array:
	var transform := _zero_matrix(6, 6)
	for offset in [0, 3]:
		transform[offset][offset] = cosine
		transform[offset][offset + 1] = sine
		transform[offset + 1][offset] = -sine
		transform[offset + 1][offset + 1] = cosine
		transform[offset + 2][offset + 2] = 1.0
	return transform


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


func _assemble_matrix(global_matrix: Array, element_matrix: Array, dofs: Array[int]) -> void:
	for row in range(6):
		for column in range(6):
			global_matrix[dofs[row]][dofs[column]] += element_matrix[row][column]


func _zero_matrix(row_count: int, column_count: int) -> Array:
	var matrix: Array = []
	for row_index in range(row_count):
		var row: Array[float] = []
		row.resize(column_count)
		for column_index in range(column_count):
			row[column_index] = 0.0
		matrix.append(row)
	return matrix


func _zero_vector(size: int) -> Array[float]:
	var vector: Array[float] = []
	vector.resize(size)
	for index in range(size):
		vector[index] = 0.0
	return vector


func _reduce_matrix(matrix: Array, free_dofs: Array[int]) -> Array:
	var reduced := _zero_matrix(free_dofs.size(), free_dofs.size())
	for row in range(free_dofs.size()):
		for column in range(free_dofs.size()):
			reduced[row][column] = matrix[free_dofs[row]][free_dofs[column]]
	return reduced


func _reduce_vector(vector: Array[float], free_dofs: Array[int]) -> Array[float]:
	var reduced := _zero_vector(free_dofs.size())
	for index in range(free_dofs.size()):
		reduced[index] = vector[free_dofs[index]]
	return reduced


func _solve(matrix: Array, right_hand_side: Array[float]) -> Dictionary:
	var size := right_hand_side.size()
	if size == 0:
		return {"valid": true, "solution": []}
	var augmented := _zero_matrix(size, size + 1)
	var matrix_scale := 0.0
	for row in range(size):
		for column in range(size):
			var value := float(matrix[row][column])
			if not is_finite(value):
				return {"valid": false, "error": "강성 행렬에 비유한 값이 있어."}
			augmented[row][column] = value
			matrix_scale = maxf(matrix_scale, absf(value))
		augmented[row][size] = right_hand_side[row]
	if matrix_scale == 0.0:
		return {"valid": false, "error": "강성 행렬이 영행렬이야. 경계조건을 확인해."}
	var pivot_tolerance := matrix_scale * SINGULAR_TOLERANCE
	for pivot_index in range(size):
		var best_row := pivot_index
		var best_value := absf(float(augmented[pivot_index][pivot_index]))
		for candidate in range(pivot_index + 1, size):
			var candidate_value := absf(float(augmented[candidate][pivot_index]))
			if candidate_value > best_value:
				best_value = candidate_value
				best_row = candidate
		if best_value <= pivot_tolerance:
			return {"valid": false, "error": "강성 행렬이 특이하거나 수치적으로 불안정해 (pivot %d). 지지조건과 형상을 확인해." % pivot_index}
		if best_row != pivot_index:
			var swap: Array = augmented[pivot_index]
			augmented[pivot_index] = augmented[best_row]
			augmented[best_row] = swap
		var pivot := float(augmented[pivot_index][pivot_index])
		for column in range(pivot_index, size + 1):
			augmented[pivot_index][column] = float(augmented[pivot_index][column]) / pivot
		for row in range(size):
			if row == pivot_index:
				continue
			var factor := float(augmented[row][pivot_index])
			for column in range(pivot_index, size + 1):
				augmented[row][column] = float(augmented[row][column]) - factor * float(augmented[pivot_index][column])
	var solution := _zero_vector(size)
	for index in range(size):
		solution[index] = float(augmented[index][size])
	return {"valid": true, "solution": solution}


func _local_displacement(global_displacement: Array[float], dofs: Array[int], transform: Array) -> Array[float]:
	var local := _zero_vector(6)
	for row in range(6):
		for column in range(6):
			local[row] += transform[row][column] * global_displacement[dofs[column]]
	return local


func _matrix_vector(matrix: Array, vector: Array[float]) -> Array[float]:
	var result := _zero_vector(vector.size())
	for row in range(vector.size()):
		for column in range(vector.size()):
			result[row] += matrix[row][column] * vector[column]
	return result


func _maximum_internal_deflection(local_displacement: Array[float], length_m: float) -> float:
	var maximum := 0.0
	for step in range(1, 20):
		var ratio := float(step) / 20.0
		var ratio2 := ratio * ratio
		var ratio3 := ratio2 * ratio
		var h1 := 1.0 - 3.0 * ratio2 + 2.0 * ratio3
		var h2 := ratio - 2.0 * ratio2 + ratio3
		var h3 := 3.0 * ratio2 - 2.0 * ratio3
		var h4 := -ratio2 + ratio3
		var interpolated := (
			h1 * local_displacement[1]
			+ h2 * length_m * local_displacement[2]
			+ h3 * local_displacement[4]
			+ h4 * length_m * local_displacement[5]
		)
		var chord := (1.0 - ratio) * local_displacement[1] + ratio * local_displacement[4]
		maximum = maxf(maximum, absf(interpolated - chord))
	return maximum


func _error(message: String) -> Dictionary:
	return {"valid": false, "error": message}
