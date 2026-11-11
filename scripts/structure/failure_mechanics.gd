extends RefCounted
class_name FailureMechanics

## 단순화 구조 실패 모델. SI 입력과 계산된 선형 정적 요소력을 사용해.
const SOLVER = preload("res://scripts/structure/linear_frame_solver.gd")
const PI_SQUARED := PI * PI

var _damage_by_member: Dictionary = {}
var _damage_events: Array[Dictionary] = []


static func euler_buckling(
	compressive_force_n: float,
	young_modulus_pa: float,
	second_moment_m4: float,
	length_m: float,
	effective_length_factor: float,
	compressive_yield_strength_pa: float = INF,
	area_m2: float = 0.0
) -> Dictionary:
	for value in [compressive_force_n, young_modulus_pa, second_moment_m4, length_m, effective_length_factor]:
		if not is_finite(value):
			return _error("좌굴 입력값은 유한해야 해.")
	if young_modulus_pa <= 0.0 or second_moment_m4 <= 0.0 or length_m <= 0.0 or effective_length_factor <= 0.0 or compressive_force_n < 0.0:
		return _error("E, I, L, K는 양수이고 압축하중은 0 이상이어야 해.")
	var effective_length_m := effective_length_factor * length_m
	var euler_critical_load_n := PI_SQUARED * young_modulus_pa * second_moment_m4 / pow(effective_length_m, 2.0)
	var yield_limit_n := INF
	if is_finite(compressive_yield_strength_pa) and area_m2 > 0.0:
		yield_limit_n = compressive_yield_strength_pa * area_m2
	var governing_limit_n := minf(euler_critical_load_n, yield_limit_n)
	var buckling_utilization := compressive_force_n / euler_critical_load_n
	return {
		"valid": true,
		"source": "euler_elastic_column_model",
		"compressive_force_n": compressive_force_n,
		"effective_length_factor": effective_length_factor,
		"effective_length_m": effective_length_m,
		"euler_critical_load_n": euler_critical_load_n,
		"yield_limit_n": yield_limit_n,
		"governing_compressive_limit_n": governing_limit_n,
		"buckling_utilization": buckling_utilization,
		"exceeds_euler_buckling": buckling_utilization >= 1.0,
		"assumptions": "이상적인 직선·프리즘 기둥의 탄성 Euler 좌굴. 초기 휨, 잔류응력, 비탄성 좌굴, 국부/비틀림 좌굴은 미포함."
	}


static func sn_life_cycles(stress_amplitude_pa: float, fatigue_strength_pa: float, exponent: float) -> Dictionary:
	if not is_finite(stress_amplitude_pa) or not is_finite(fatigue_strength_pa) or not is_finite(exponent):
		return _error("S-N 모델 입력은 유한해야 해.")
	if stress_amplitude_pa < 0.0 or fatigue_strength_pa <= 0.0 or exponent <= 0.0:
		return _error("응력 진폭은 0 이상, 피로 기준강도와 지수는 양수여야 해.")
	if stress_amplitude_pa == 0.0:
		return {"valid": true, "life_cycles": INF, "source": "user_supplied_power_law_sn_curve"}
	return {
		"valid": true,
		"life_cycles": pow(fatigue_strength_pa / stress_amplitude_pa, exponent),
		"source": "user_supplied_power_law_sn_curve",
		"assumptions": "사용자가 제공한 단일 구간 S-N 멱법칙. 평균응력 보정, 산포, 환경·주파수 효과는 미포함."
	}


func record_fatigue_cycles(
	member_id: String,
	stress_amplitude_pa: float,
	cycles: float,
	fatigue_strength_pa: float,
	exponent: float,
	crack_initiation_damage: float = 0.5,
	crack_position_fraction: float = 0.5
) -> Dictionary:
	if member_id.is_empty() or not is_finite(cycles) or cycles < 0.0:
		return _error("부재 ID와 유효한 0 이상 반복횟수가 필요해.")
	if crack_initiation_damage <= 0.0 or crack_initiation_damage > 1.0:
		return _error("균열 개시 손상 기준은 0 초과 1 이하야.")
	var life := sn_life_cycles(stress_amplitude_pa, fatigue_strength_pa, exponent)
	if not bool(life.get("valid", false)):
		return life
	var old_state: Dictionary = _damage_by_member.get(member_id, {"damage": 0.0, "cracked": false, "failed": false, "crack_position_fraction": -1.0})
	var increment := 0.0
	if cycles > 0.0 and is_finite(float(life["life_cycles"])):
		increment = cycles / float(life["life_cycles"])
	var updated_damage := float(old_state["damage"]) + increment
	var was_cracked := bool(old_state["cracked"])
	var is_cracked := was_cracked or updated_damage >= crack_initiation_damage
	var is_failed := bool(old_state["failed"]) or updated_damage >= 1.0
	var crack_position := float(old_state["crack_position_fraction"])
	if is_cracked and not was_cracked:
		crack_position = clampf(crack_position_fraction, 0.0, 1.0)
	var state := {
		"member_id": member_id,
		"damage": updated_damage,
		"damage_increment": increment,
		"cycle_count": float(old_state.get("cycle_count", 0.0)) + cycles,
		"stress_amplitude_pa": stress_amplitude_pa,
		"estimated_life_cycles_at_current_amplitude": life["life_cycles"],
		"cracked": is_cracked,
		"failed": is_failed,
		"crack_position_fraction": crack_position,
		"model": "Palmgren-Miner linear damage with user-supplied power-law S-N curve"
	}
	_damage_by_member[member_id] = state
	if is_cracked and not was_cracked:
		var event := {"type": "crack_initiated", "member_id": member_id, "damage": updated_damage, "position_fraction": crack_position, "source": "calculated_fatigue_damage"}
		_damage_events.append(event)
		print("[피로 균열] %s | D=%.4f | 위치비율=%.3f" % [member_id, updated_damage, crack_position])
	if is_failed and not bool(old_state["failed"]):
		_damage_events.append({"type": "fatigue_failure", "member_id": member_id, "damage": updated_damage, "source": "calculated_fatigue_damage"})
	return {"valid": true, "state": state.duplicate(true)}


func record_solver_crack(member_id: String, element_result: Dictionary, tensile_strength_pa: float, length_m: float) -> Dictionary:
	if member_id.is_empty() or tensile_strength_pa <= 0.0 or length_m <= 0.0:
		return _error("균열 계산에 유효한 ID, 강도, 길이가 필요해.")
	var end_i_stress := maxf(float(element_result.get("normal_stress_i_top_pa", 0.0)), float(element_result.get("normal_stress_i_bottom_pa", 0.0)))
	var end_j_stress := maxf(float(element_result.get("normal_stress_j_top_pa", 0.0)), float(element_result.get("normal_stress_j_bottom_pa", 0.0)))
	var peak_stress := maxf(end_i_stress, end_j_stress)
	var ratio := peak_stress / tensile_strength_pa
	var fraction := 0.0 if end_i_stress >= end_j_stress else 1.0
	var state: Dictionary = _damage_by_member.get(member_id, {"damage": 0.0, "cracked": false, "failed": false, "crack_position_fraction": -1.0, "cycle_count": 0.0})
	if ratio >= 1.0:
		state["damage"] = maxf(float(state["damage"]), ratio)
		state["cracked"] = true
		state["failed"] = true
		state["crack_position_fraction"] = fraction
		state["crack_position_m"] = fraction * length_m
		state["initiation_source"] = "linear_static_solver_tensile_stress"
		_damage_by_member[member_id] = state
		_damage_events.append({"type": "strength_exceeded_crack", "member_id": member_id, "stress_pa": peak_stress, "limit_pa": tensile_strength_pa, "position_m": fraction * length_m})
	return {"valid": true, "member_id": member_id, "peak_tensile_stress_pa": peak_stress, "tensile_utilization": ratio, "crack_position_fraction": fraction, "crack_position_m": fraction * length_m, "cracked": ratio >= 1.0, "failed": ratio >= 1.0}


func get_damage_state(member_id: String) -> Dictionary:
	return (_damage_by_member.get(member_id, {}) as Dictionary).duplicate(true)


func get_damage_events() -> Array[Dictionary]:
	return _damage_events.duplicate(true)


static func progressive_reanalysis(model: Dictionary, initially_removed_ids: Array[String] = [], max_removals: int = 20, buckling_by_element: Dictionary = {}) -> Dictionary:
	for key in ["nodes", "elements", "materials", "loads", "supports"]:
		if not model.has(key):
			return _error("progressive_reanalysis 모델에 %s 값이 없어." % key)
	var active_elements: Array = (model["elements"] as Array).duplicate(true)
	var removed: Array[String] = []
	for element_id in initially_removed_ids:
		removed.append(element_id)
	var steps: Array[Dictionary] = []
	var failure_cause := ""
	for element_id in removed:
		active_elements = _without_element(active_elements, element_id)
	var first_solve := true
	while steps.size() <= max_removals:
		if active_elements.is_empty():
			failure_cause = "모든 요소가 제거됐어."
			break
		var solver_result: Dictionary = SOLVER.new().analyze(
			model["nodes"], active_elements, model["materials"], model["loads"], model["supports"], model.get("connections", []),
			model.get("thermal_strains_by_element", {})
		)
		if not bool(solver_result.get("valid", false)):
			failure_cause = str(solver_result.get("error", "강성행렬 해석 실패"))
			steps.append({"step": steps.size(), "valid": false, "removed_member_ids": removed.duplicate(), "solver_error": failure_cause})
			break
		var element_results: Dictionary = solver_result["element_results"]
		var worst_id := ""
		var worst_ratio := 1.0
		var demands: Dictionary = {}
		for element in active_elements:
			var element_id := str(element["id"])
			var result: Dictionary = element_results[element_id]
			var evaluation: Dictionary = result.get("material_limit_evaluation", {})
			var ratio := float(evaluation.get("maximum_utilization", 0.0))
			var mode := "material_strength_or_strain"
			if buckling_by_element.has(element_id):
				var buckling: Dictionary = buckling_by_element[element_id]
				var material: Dictionary = model["materials"][str(element["material_id"])]
				var compression_force := maxf(0.0, maxf(-float(result["axial_force_i_n"]), -float(result["axial_force_j_n"])))
				var buckling_check := euler_buckling(
					compression_force, float(material.get("elastic_modulus_pa", material.get("young_modulus_pa", 0.0))),
					float(buckling["second_moment_m4"]), float(result["length_m"]), float(buckling.get("effective_length_factor", 1.0)),
					float(material.get("compressive_strength_pa", INF)), float(element["area_m2"])
				)
				if bool(buckling_check.get("valid", false)) and float(buckling_check["buckling_utilization"]) > ratio:
					ratio = float(buckling_check["buckling_utilization"])
					mode = "euler_buckling"
			demands[element_id] = {"utilization": ratio, "mode": mode, "result": result}
			if ratio > worst_ratio:
				worst_ratio = ratio
				worst_id = element_id
		steps.append({
			"step": steps.size(), "valid": true, "removed_member_ids": removed.duplicate(),
			"active_member_ids": _member_ids(active_elements), "demands": demands,
			"worst_member_id": worst_id, "worst_utilization": worst_ratio,
			"trigger": "initial_member_removal" if first_solve else "solver_calculated_capacity_exceedance"
		})
		first_solve = false
		if worst_id.is_empty():
			break
		if removed.size() >= max_removals:
			failure_cause = "최대 제거 횟수에 도달했어."
			break
		removed.append(worst_id)
		active_elements = _without_element(active_elements, worst_id)
	var collapsed := not failure_cause.is_empty()
	return {
		"valid": true,
		"source": "linear_static_solver_iterative_member_removal",
		"collapsed": collapsed,
		"status": "collapse" if collapsed else "stable_after_reanalysis",
		"failure_cause": failure_cause,
		"removed_member_ids": removed,
		"steps": steps,
		"assumptions": "매 요소 제거 후 같은 하중으로 선형 정적 구조해석을 다시 풀고 용량 초과 요소를 한 번에 하나씩 제거한다. 제거 순간의 동적 증폭·비선형 재료·접촉은 포함하지 않는다."
	}


static func _without_element(elements: Array, removed_id: String) -> Array:
	var active: Array = []
	for element in elements:
		if str(element.get("id", "")) != removed_id:
			active.append(element)
	return active


static func _member_ids(elements: Array) -> Array[String]:
	var ids: Array[String] = []
	for element in elements:
		ids.append(str(element["id"]))
	return ids


static func _error(message: String) -> Dictionary:
	return {"valid": false, "error": message}
