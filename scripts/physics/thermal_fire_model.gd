extends RefCounted
class_name ThermalFireModel

## 집중열용량 1절점 모델. 각 부재 내부 온도 구배와 화재 곡선은 계산하지 않아.
const STEFAN_BOLTZMANN: float = 5.670374419e-8
const MAX_HISTORY_SAMPLES: int = 1000

const THERMAL_PRESETS: Dictionary = {
	"structural_steel": {"specific_heat_j_kg_k": 600.0, "conductivity_w_m_k": 45.0, "expansion_per_k": 14.0e-6, "emissivity": 0.7,
		"strength_curve": [[20.0, 1.0], [400.0, 1.0], [500.0, 0.78], [600.0, 0.47], [700.0, 0.23], [800.0, 0.11], [900.0, 0.06], [1000.0, 0.04], [1100.0, 0.02], [1200.0, 0.0]],
		"modulus_curve": [[20.0, 1.0], [100.0, 1.0], [200.0, 0.9], [300.0, 0.8], [400.0, 0.7], [500.0, 0.6], [600.0, 0.31], [700.0, 0.13], [800.0, 0.09], [900.0, 0.0675], [1000.0, 0.045], [1200.0, 0.0]],
		"source": "NIST TN 1681, steel simplified heat properties and Eurocode 3 elevated-temperature strength factors."},
	"reinforced_concrete": {"specific_heat_j_kg_k": 1000.0, "conductivity_w_m_k": 1.3, "expansion_per_k": 10.0e-6, "emissivity": 0.9,
		"strength_curve": [[20.0, 1.0], [200.0, 0.9], [400.0, 0.75], [600.0, 0.45], [800.0, 0.15], [1000.0, 0.0]],
		"modulus_curve": [[20.0, 1.0], [200.0, 0.8], [400.0, 0.5], [600.0, 0.2], [800.0, 0.05], [1000.0, 0.0]],
		"source": "FHWA/NIST representative values: Cp 1000 J/kg K, conductivity 1.3 W/m K, expansion 10 microstrain/K. Fire curves are prototype assumptions."},
	"timber": {"specific_heat_j_kg_k": 1600.0, "conductivity_w_m_k": 0.13, "expansion_per_k": 38.0e-6, "emissivity": 0.9,
		"strength_curve": [[20.0, 1.0], [100.0, 0.8], [200.0, 0.5], [300.0, 0.2], [400.0, 0.0]],
		"modulus_curve": [[20.0, 1.0], [100.0, 0.8], [200.0, 0.5], [300.0, 0.2], [400.0, 0.0]],
		"source": "USDA Wood Handbook: representative dry heat-capacity/conductivity/expansion proxies. Fire retention curves are prototype assumptions."},
	"glass": {"specific_heat_j_kg_k": 720.0, "conductivity_w_m_k": 1.0, "expansion_per_k": 9.1e-6, "emissivity": 0.837,
		"strength_curve": [[20.0, 1.0], [100.0, 0.9], [200.0, 0.65], [400.0, 0.25], [600.0, 0.05], [725.0, 0.0]],
		"modulus_curve": [[20.0, 1.0], [100.0, 0.98], [200.0, 0.9], [400.0, 0.65], [600.0, 0.25], [725.0, 0.0]],
		"source": "AGC soda-lime glass technical data: Cp 720 J/kg K, conductivity about 1 W/m K, expansion 9.1 microstrain/K, corrected emissivity 0.837. Fire curves are prototype assumptions."}
}

var _members: Dictionary = {}
var _conduction_edges: Array[Dictionary] = []
var _time_s: float = 0.0
var _fire_duration_s: float = 0.0
var _fire_temperature_c: float = 20.0
var _ambient_temperature_c: float = 20.0
var _convection_coefficient_w_m2_k: float = 25.0
var _exposed_member_ids: Dictionary = {}
var _history: Array[Dictionary] = []


func register_member(member_id: String, material: Dictionary, volume_m3: float, exposed_area_m2: float, initial_temperature_c: float = 20.0) -> Dictionary:
	if member_id.is_empty() or _members.has(member_id):
		return _error("부재 ID가 비었거나 이미 등록됐어.")
	if volume_m3 <= 0.0 or exposed_area_m2 < 0.0 or not is_finite(initial_temperature_c):
		return _error("부재 체적/노출면적/초기 온도가 유효하지 않아.")
	var material_id := str(material.get("id", ""))
	var thermal: Dictionary = (THERMAL_PRESETS.get(material_id, {}) as Dictionary).duplicate(true)
	for key in ["specific_heat_j_kg_k", "conductivity_w_m_k", "expansion_per_k", "emissivity"]:
		if material.has(key):
			thermal[key] = material[key]
	if material.has("thermal_expansion_per_k"):
		thermal["expansion_per_k"] = material["thermal_expansion_per_k"]
	if thermal.is_empty():
		return _error("재료 %s의 열물성 자료가 없어." % material_id)
	var density := float(material.get("density_kg_m3", 0.0))
	var cp := float(thermal.get("specific_heat_j_kg_k", 0.0))
	if density <= 0.0 or cp <= 0.0:
		return _error("재료 밀도와 비열은 양수여야 해.")
	var mass := density * volume_m3
	_members[member_id] = {
		"material": material.duplicate(true), "thermal": thermal.duplicate(true), "mass_kg": mass,
		"heat_capacity_j_k": mass * cp, "exposed_area_m2": exposed_area_m2,
		"temperature_k": initial_temperature_c + 273.15, "peak_temperature_k": initial_temperature_c + 273.15,
		"last_flux": {"convection_w": 0.0, "radiation_w": 0.0, "conduction_w": 0.0}
	}
	return {"valid": true, "mass_kg": mass, "heat_capacity_j_k": mass * cp}


func connect_members(member_a: String, member_b: String, contact_area_m2: float, conduction_length_m: float) -> Dictionary:
	if not _members.has(member_a) or not _members.has(member_b) or member_a == member_b:
		return _error("열전도 접합의 부재 ID가 올바르지 않아.")
	if contact_area_m2 <= 0.0 or conduction_length_m <= 0.0:
		return _error("접촉 면적과 전도 길이는 양수여야 해.")
	for edge in _conduction_edges:
		if (edge["a"] == member_a and edge["b"] == member_b) or (edge["a"] == member_b and edge["b"] == member_a):
			return _error("같은 부재 쌍의 전도 경로가 중복돼.")
	var k_a := float((_members[member_a]["thermal"] as Dictionary)["conductivity_w_m_k"])
	var k_b := float((_members[member_b]["thermal"] as Dictionary)["conductivity_w_m_k"])
	var harmonic_k := 2.0 * k_a * k_b / (k_a + k_b)
	_conduction_edges.append({"a": member_a, "b": member_b, "conductance_w_k": harmonic_k * contact_area_m2 / conduction_length_m})
	return {"valid": true, "conductance_w_k": harmonic_k * contact_area_m2 / conduction_length_m}


func configure_fire(gas_temperature_c: float, duration_s: float, exposed_member_ids: Array[String], ambient_temperature_c: float = 20.0, convection_coefficient_w_m2_k: float = 25.0) -> Dictionary:
	if duration_s < 0.0 or convection_coefficient_w_m2_k < 0.0 or not is_finite(gas_temperature_c) or not is_finite(ambient_temperature_c):
		return _error("화재 온도, 지속시간 또는 대류 계수가 유효하지 않아.")
	_exposed_member_ids.clear()
	for member_id in exposed_member_ids:
		if not _members.has(member_id):
			return _error("등록되지 않은 화재 노출 부재야: %s" % member_id)
		_exposed_member_ids[member_id] = true
	_fire_temperature_c = gas_temperature_c
	_ambient_temperature_c = ambient_temperature_c
	_fire_duration_s = duration_s
	_convection_coefficient_w_m2_k = convection_coefficient_w_m2_k
	return {"valid": true, "fire_model": "constant_gas_temperature_lumped_node", "duration_s": duration_s}


func advance(delta_s: float) -> Dictionary:
	if delta_s <= 0.0 or not is_finite(delta_s):
		return _error("시간 간격은 유한한 양수여야 해.")
	if _members.is_empty():
		return _error("등록된 부재가 없어.")
	var remaining := delta_s
	while remaining > 1.0e-9:
		var step_s := minf(remaining, 1.0)
		if _time_s < _fire_duration_s:
			step_s = minf(step_s, _fire_duration_s - _time_s)
		var rates: Dictionary = {}
		var transfer_coefficients: Dictionary = {}
		for member_id in _members:
			rates[member_id] = 0.0
			transfer_coefficients[member_id] = 0.0
		for edge in _conduction_edges:
			var a: String = edge["a"]
			var b: String = edge["b"]
			var delta_k := float(_members[a]["temperature_k"]) - float(_members[b]["temperature_k"])
			var transfer_w := float(edge["conductance_w_k"]) * delta_k
			rates[a] -= transfer_w
			rates[b] += transfer_w
			transfer_coefficients[a] += float(edge["conductance_w_k"])
			transfer_coefficients[b] += float(edge["conductance_w_k"])
		for member_id in _members:
			var state: Dictionary = _members[member_id]
			var area := float(state["exposed_area_m2"])
			if area <= 0.0:
				continue
			var temp_k := float(state["temperature_k"])
			var boundary_c := _fire_temperature_c if _time_s < _fire_duration_s and _exposed_member_ids.has(member_id) else _ambient_temperature_c
			var boundary_k := boundary_c + 273.15
			var h := _convection_coefficient_w_m2_k if boundary_c == _fire_temperature_c and _time_s < _fire_duration_s and _exposed_member_ids.has(member_id) else 8.0
			var convection_w := h * area * (boundary_k - temp_k)
			var emissivity := clampf(float(state["thermal"]["emissivity"]), 0.0, 1.0)
			var radiation_w := emissivity * STEFAN_BOLTZMANN * area * (pow(boundary_k, 4.0) - pow(temp_k, 4.0))
			rates[member_id] += convection_w + radiation_w
			transfer_coefficients[member_id] += h * area + 4.0 * emissivity * STEFAN_BOLTZMANN * area * pow(maxf(boundary_k, temp_k), 3.0)
		# 양의 유한 명시적 Euler가 안정하도록 열용량과 선형화된 열전달률로 내부 간격 제한.
		var max_ratio := 0.0
		for member_id in _members:
			var capacity := float(_members[member_id]["heat_capacity_j_k"])
			max_ratio = maxf(max_ratio, float(transfer_coefficients[member_id]) / maxf(capacity, 1.0))
		if max_ratio > 0.0:
			step_s = minf(step_s, 0.2 / max_ratio)
		var fluxes: Dictionary = {}
		for member_id in _members:
			var state: Dictionary = _members[member_id]
			var current_k := float(state["temperature_k"])
			var boundary_c := _fire_temperature_c if _time_s < _fire_duration_s and _exposed_member_ids.has(member_id) else _ambient_temperature_c
			var boundary_k := boundary_c + 273.15
			var area := float(state["exposed_area_m2"])
			var h := _convection_coefficient_w_m2_k if _time_s < _fire_duration_s and _exposed_member_ids.has(member_id) else 8.0
			var convection := h * area * (boundary_k - current_k)
			var radiation := float(state["thermal"]["emissivity"]) * STEFAN_BOLTZMANN * area * (pow(boundary_k, 4.0) - pow(current_k, 4.0))
			var conduction := float(rates[member_id]) - convection - radiation
			state["temperature_k"] = maxf(1.0, current_k + float(rates[member_id]) / float(state["heat_capacity_j_k"]) * step_s)
			state["peak_temperature_k"] = maxf(float(state["peak_temperature_k"]), float(state["temperature_k"]))
			state["last_flux"] = {"convection_w": convection, "radiation_w": radiation, "conduction_w": conduction}
		_time_s += step_s
		remaining -= step_s
	if _history.is_empty() or _time_s - float(_history.back()["time_s"]) >= 0.1:
		_history.append({"time_s": _time_s, "temperatures_c": _current_temperatures_c()})
		if _history.size() > MAX_HISTORY_SAMPLES:
			_history.pop_front()
	return {"valid": true, "time_s": _time_s, "fire_active": _time_s < _fire_duration_s, "temperatures_c": _current_temperatures_c()}


func get_member_state(member_id: String) -> Dictionary:
	if not _members.has(member_id):
		return {}
	var state: Dictionary = _members[member_id]
	var material: Dictionary = state["material"]
	var thermal: Dictionary = state["thermal"]
	var temperature_c := float(state["temperature_k"]) - 273.15
	var strength_retention := _retention_factor(thermal.get("strength_curve", []), temperature_c)
	var modulus_retention := _retention_factor(thermal.get("modulus_curve", []), temperature_c)
	var expansion := float(thermal["expansion_per_k"]) * (temperature_c - 20.0)
	return {
		"member_id": member_id, "material_id": str(material.get("id", "")),
		"temperature_c": temperature_c, "peak_temperature_c": float(state["peak_temperature_k"]) - 273.15,
		"mass_kg": float(state["mass_kg"]), "heat_capacity_j_k": float(state["heat_capacity_j_k"]),
		"specific_heat_j_kg_k": float(thermal["specific_heat_j_kg_k"]),
		"thermal_strain": expansion, "free_expansion_per_m": expansion,
		"strength_retention": strength_retention, "modulus_retention": modulus_retention,
		"reduced_strengths_pa": _scaled_strengths(material, strength_retention),
		"heat_flux_w": (state["last_flux"] as Dictionary).duplicate(true),
		"fire_active": _time_s < _fire_duration_s and _exposed_member_ids.has(member_id),
		"model_note": "계산된 강체 물리 엔진 힘이 아닌 집중열용량 열전달 및 재료 강도 유지율 추정값."
	}


func thermalize_structural_model(model: Dictionary) -> Dictionary:
	for key in ["nodes", "elements", "materials", "loads", "supports"]:
		if not model.has(key):
			return _error("구조 모델에 %s 값이 없어." % key)
	var copy := model.duplicate(true)
	copy["materials"] = (model["materials"] as Dictionary).duplicate(true)
	var strains: Dictionary = {}
	for element in copy["elements"]:
		var element_id := str(element.get("id", ""))
		if not _members.has(element_id):
			return _error("열 상태가 등록되지 않은 요소야: %s" % element_id)
		var state := get_member_state(element_id)
		var base_id := str(element.get("material_id", ""))
		if not copy["materials"].has(base_id):
			return _error("요소 %s의 재료가 모델에 없어." % element_id)
		var material: Dictionary = copy["materials"][base_id].duplicate(true)
		var material_id := "%s@%s" % [base_id, element_id]
		material["id"] = material_id
		material["thermal_temperature_c"] = state["temperature_c"]
		material["thermal_strength_retention"] = state["strength_retention"]
		material["thermal_modulus_retention"] = state["modulus_retention"]
		material["thermal_model_note"] = "선형 보간 prototype material retention; 인증 화재 설계값 아님."
		material["elastic_modulus_pa"] = float(material.get("elastic_modulus_pa", material.get("young_modulus_pa", 0.0))) * float(state["modulus_retention"])
		for strength_key in ["yield_strength_pa", "tensile_strength_pa", "compressive_strength_pa", "shear_strength_pa"]:
			if material.has(strength_key) and material[strength_key] != null:
				material[strength_key] = float(material[strength_key]) * float(state["strength_retention"])
		copy["materials"][material_id] = material
		element["material_id"] = material_id
		strains[element_id] = float(state["thermal_strain"])
	copy["thermal_strains_by_element"] = strains
	copy["thermal_model_note"] = "단순화된 온도별 영률/강도 감소 및 자유 열변형률을 선형 정적 해석 입력에 적용했어."
	return {"valid": true, "model": copy, "thermal_strains_by_element": strains}


func get_temperature_history() -> Array[Dictionary]:
	return _history.duplicate(true)


func get_time_s() -> float:
	return _time_s


func _current_temperatures_c() -> Dictionary:
	var result: Dictionary = {}
	for member_id in _members:
		result[member_id] = float(_members[member_id]["temperature_k"]) - 273.15
	return result


func _retention_factor(curve: Array, temperature_c: float) -> float:
	if curve.is_empty():
		return 1.0
	if temperature_c <= float(curve[0][0]):
		return float(curve[0][1])
	for index in range(curve.size() - 1):
		var lower: Array = curve[index]
		var upper: Array = curve[index + 1]
		if temperature_c <= float(upper[0]):
			var ratio := (temperature_c - float(lower[0])) / (float(upper[0]) - float(lower[0]))
			return lerpf(float(lower[1]), float(upper[1]), ratio)
	return float(curve.back()[1])


func _scaled_strengths(material: Dictionary, factor: float) -> Dictionary:
	var result: Dictionary = {}
	for key in ["yield_strength_pa", "tensile_strength_pa", "compressive_strength_pa", "shear_strength_pa"]:
		if material.has(key) and material[key] != null:
			result[key] = float(material[key]) * factor
	return result


func _error(message: String) -> Dictionary:
	return {"valid": false, "error": message}
