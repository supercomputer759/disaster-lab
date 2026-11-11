extends Node2D

const THERMAL = preload("res://scripts/physics/thermal_fire_model.gd")
const MATERIAL_DB = preload("res://scripts/structure/material_database.gd")
const SOLVER = preload("res://scripts/structure/linear_frame_solver.gd")
const FAILURE = preload("res://scripts/structure/failure_mechanics.gd")

@export var test_summary: String = "대기"
var _checks := 0
var _failures: Array[String] = []


func _ready() -> void:
	_test_single_member_heating_and_duration()
	_test_material_response()
	_test_conduction_energy_balance()
	_test_free_thermal_expansion()
	_test_hot_strength_and_failure_mechanics()
	test_summary = "%s · checks=%d · failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()]
	print("[THERMAL_FIRE_TEST] %s" % test_summary)
	for failure in _failures:
		push_error("[THERMAL_FIRE_TEST] %s" % failure)


func _test_single_member_heating_and_duration() -> void:
	var model = THERMAL.new()
	var member: Dictionary = MATERIAL_DB.get_material("structural_steel")
	_expect(bool(model.register_member("steel", member, 0.01, 1.0)["valid"]), "강재 부재 열용량 등록")
	_expect(bool(model.configure_fire(600.0, 2.0, ["steel"], 20.0, 25.0)["valid"]), "일정 온도 화재와 지속시간 설정")
	var result: Dictionary = model.advance(1.0)
	var state: Dictionary = model.get_member_state("steel")
	_expect(bool(result["valid"]) and float(state["temperature_c"]) > 20.0 and float(state["temperature_c"]) < 600.0, "대류·복사 열유속으로 부재 가열")
	_expect(float(state["heat_flux_w"]["convection_w"]) > 0.0 and float(state["heat_flux_w"]["radiation_w"]) > 0.0, "대류와 Stefan-Boltzmann 복사열을 별도 계산")
	_expect(bool(state["fire_active"]) and model.get_temperature_history().size() > 0, "화재 중 상태와 시간별 온도 기록")
	model.advance(1.5)
	state = model.get_member_state("steel")
	_expect(not bool(state["fire_active"]) and float(model.get_time_s()) >= 2.0, "설정한 화재 지속시간 종료 후 냉각 경계로 전환")
	_expect(float(state["peak_temperature_c"]) >= float(state["temperature_c"]), "최대 온도와 현재 온도 분리 기록")


func _test_material_response() -> void:
	var model = THERMAL.new()
	for material_id in ["structural_steel", "reinforced_concrete", "timber", "glass"]:
		var material: Dictionary = MATERIAL_DB.get_material(material_id)
		_expect(bool(model.register_member(material_id, material, 0.01, 1.0)["valid"]), "%s 열물성 등록" % material_id)
	model.configure_fire(600.0, 100.0, ["structural_steel", "reinforced_concrete", "timber", "glass"])
	model.advance(60.0)
	var temperatures: Dictionary = model.advance(60.0)["temperatures_c"]
	_expect(float(temperatures["timber"]) > float(temperatures["structural_steel"]), "목재와 강재의 체적 열용량 차이가 온도 응답에 반영")
	_expect(float(temperatures["reinforced_concrete"]) != float(temperatures["glass"]), "콘크리트와 유리의 재료 열응답이 구분")
	var wood: Dictionary = model.get_member_state("timber")
	_expect(float(wood["specific_heat_j_kg_k"]) == 1600.0 and float(wood["free_expansion_per_m"]) > 0.0, "목재 비열과 자유 열팽창 추정값 제공")


func _test_conduction_energy_balance() -> void:
	var model = THERMAL.new()
	var steel: Dictionary = MATERIAL_DB.get_material("structural_steel")
	model.register_member("hot", steel, 0.01, 0.0, 200.0)
	model.register_member("cold", steel, 0.02, 0.0, 20.0)
	var link: Dictionary = model.connect_members("hot", "cold", 0.01, 0.1)
	_expect(bool(link["valid"]), "부재 사이 전도 경로 구성")
	model.configure_fire(20.0, 0.0, [], 20.0)
	var before_hot: Dictionary = model.get_member_state("hot")
	var before_cold: Dictionary = model.get_member_state("cold")
	var initial_energy := float(before_hot["heat_capacity_j_k"]) * float(before_hot["temperature_c"]) + float(before_cold["heat_capacity_j_k"]) * float(before_cold["temperature_c"])
	model.advance(20.0)
	var after_hot: Dictionary = model.get_member_state("hot")
	var after_cold: Dictionary = model.get_member_state("cold")
	var final_energy := float(after_hot["heat_capacity_j_k"]) * float(after_hot["temperature_c"]) + float(after_cold["heat_capacity_j_k"]) * float(after_cold["temperature_c"])
	_expect(float(after_hot["temperature_c"]) < 200.0 and float(after_cold["temperature_c"]) > 20.0, "전도열이 고온 부재에서 저온 부재로 흐름")
	_expect(absf(final_energy - initial_energy) / initial_energy < 1.0e-5, "단열된 두 부재 전도에서 열에너지 보존")


func _test_free_thermal_expansion() -> void:
	var model = THERMAL.new()
	var steel: Dictionary = MATERIAL_DB.get_material("structural_steel")
	model.register_member("bar", steel, 0.01, 0.0, 120.0)
	var thermal_model: Dictionary = model.thermalize_structural_model(_bar_solver_model())
	_expect(bool(thermal_model["valid"]), "열 상태를 구조해석 모델로 변환")
	if not bool(thermal_model["valid"]):
		return
	var source: Dictionary = thermal_model["model"]
	var result: Dictionary = SOLVER.new().analyze(source["nodes"], source["elements"], source["materials"], source["loads"], source["supports"], [], source["thermal_strains_by_element"])
	_expect(bool(result["valid"]), "열팽창 포함 선형 정적 솔버 수렴")
	if not bool(result["valid"]):
		return
	var expected := float(steel["thermal_expansion_per_k"]) * 100.0 * 2.0
	var displacement: Vector3 = result["node_displacements"]["B"]
	var element_result: Dictionary = result["element_results"]["bar"]
	_expect(_near(displacement.x, expected, 1.0e-7), "자유 부재 축변위가 αΔTL과 일치")
	_expect(absf(float(element_result["axial_force_i_n"])) < 0.1, "자유 열팽창에서 가짜 축력 없음")


func _test_hot_strength_and_failure_mechanics() -> void:
	var model = THERMAL.new()
	var steel: Dictionary = MATERIAL_DB.get_material("structural_steel")
	model.register_member("column", steel, 0.001, 0.0, 500.0)
	var state: Dictionary = model.get_member_state("column")
	_expect(_near(float(state["strength_retention"]), 0.78, 1.0e-8), "강재 500°C 강도 계수가 NIST 표 참조값 0.78")
	var thermalized: Dictionary = model.thermalize_structural_model(_column_solver_model())
	_expect(bool(thermalized["valid"]), "고온 재료가 구조해석 모델에 적용")
	if not bool(thermalized["valid"]):
		return
	var hot: Dictionary = thermalized["model"]
	var hot_result: Dictionary = SOLVER.new().analyze(hot["nodes"], hot["elements"], hot["materials"], hot["loads"], hot["supports"], [], hot["thermal_strains_by_element"])
	var ambient_model: Dictionary = _column_solver_model()
	var ambient_result: Dictionary = SOLVER.new().analyze(ambient_model["nodes"], ambient_model["elements"], ambient_model["materials"], ambient_model["loads"], ambient_model["supports"])
	_expect(bool(hot_result["valid"]) and bool(ambient_result["valid"]), "상온 및 고온 기둥 해석 수렴")
	if not bool(hot_result["valid"]) or not bool(ambient_result["valid"]):
		return
	var hot_ratio := float(hot_result["element_results"]["column"]["material_limit_evaluation"]["maximum_utilization"])
	var ambient_ratio := float(ambient_result["element_results"]["column"]["material_limit_evaluation"]["maximum_utilization"])
	_expect(ambient_ratio < 1.0 and hot_ratio > 1.0, "동일 축하중에서 온도 상승으로 재료 한계 초과")
	var collapse: Dictionary = FAILURE.progressive_reanalysis(hot, [], 3)
	_expect(bool(collapse["valid"]) and bool(collapse["collapsed"]), "Failure Mechanics가 열화된 용량으로 연쇄 제거를 판정")


func _bar_solver_model() -> Dictionary:
	return {
		"nodes":[{"id":"A","x_m":0.0,"y_m":0.0},{"id":"B","x_m":2.0,"y_m":0.0}],
		"elements":[_element("bar","A","B","steel",0.01)],
		"materials":{"steel":MATERIAL_DB.solver_materials([MATERIAL_DB.get_material("structural_steel")])["structural_steel"]},
		"loads":{},"supports":{"A":[true,true,true],"B":[false,true,true]}
	}


func _column_solver_model() -> Dictionary:
	return {
		"nodes":[{"id":"base","x_m":0.0,"y_m":0.0},{"id":"top","x_m":0.0,"y_m":3.0}],
		"elements":[_element("column","base","top","steel",0.001)],
		"materials":{"steel":MATERIAL_DB.solver_materials([MATERIAL_DB.get_material("structural_steel")])["structural_steel"]},
		"loads":{"top":Vector3(0.0,-230000.0,0.0)},"supports":{"base":[true,true,true],"top":[true,false,true]}
	}


func _element(element_id: String, node_i: String, node_j: String, material_id: String, area_m2: float) -> Dictionary:
	return {"id":element_id,"node_i":node_i,"node_j":node_j,"material_id":material_id,"area_m2":area_m2,"inertia_m4":8.333333333333333e-6,"depth_m":0.1}


func _near(actual: float, expected: float, relative_tolerance: float = 1.0e-7) -> bool:
	return is_finite(actual) and absf(actual - expected) <= maxf(absf(expected) * relative_tolerance, 1.0e-9)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)
