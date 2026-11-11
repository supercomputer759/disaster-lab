extends Node2D

const FLUID = preload("res://scripts/physics/fluid_flood_model.gd")
const MATERIAL_DB = preload("res://scripts/structure/material_database.gd")
const SOLVER = preload("res://scripts/structure/linear_frame_solver.gd")

@export var test_summary: String = "대기"
var _checks := 0
var _failures: Array[String] = []


func _ready() -> void:
	_test_pressure_and_resultant()
	_test_buoyancy()
	_test_time_dependent_flooding()
	_test_solver_pressure_deflection()
	test_summary = "%s · checks=%d · failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()]
	print("[FLUID_FLOOD_TEST] %s" % test_summary)
	for failure in _failures:
		push_error("[FLUID_FLOOD_TEST] %s" % failure)


func _test_pressure_and_resultant() -> void:
	var model = FLUID.new()
	var at_one: Dictionary = model.pressure_at_depth(1.0)
	var at_two: Dictionary = model.pressure_at_depth(2.0)
	_expect(bool(at_one["valid"]) and bool(at_two["valid"]), "수심별 게이지압 계산")
	_expect(_near(float(at_one["gauge_pressure_pa"]), 9806.65), "1m 수심 압력이 ρgh와 일치")
	_expect(_near(float(at_two["gauge_pressure_pa"]), 19613.3), "2m 수심 압력이 1m 수심의 두 배")
	var wall: Dictionary = model.vertical_wall_resultant(2.0, 3.0)
	_expect(_near(float(wall["resultant_force_n"]), 58839.9), "2m 높이·3m 폭 수압 합력이 삼각분포 적분과 일치")
	_expect(_near(float(wall["centroid_above_bottom_m"]), 2.0 / 3.0), "삼각 수압 합력 작용점이 바닥에서 H/3")


func _test_buoyancy() -> void:
	var model = FLUID.new()
	var result: Dictionary = model.buoyancy_force(0.02)
	_expect(bool(result["valid"]), "변위 체적 부력 계산")
	_expect(_near(float(result["buoyant_force_n"]), 196.133), "0.02m³ 담수 변위의 부력이 ρgV와 일치")
	var partial: Dictionary = model.buoyancy_force(0.005, 800.0)
	_expect(_near(float(partial["buoyant_force_n"]), 39.2266), "부분 침수 체적과 사용자 유체 밀도 반영")
	_expect(Vector2(result["force_xy_n"]).y > 0.0, "SI 구조 좌표계에서 부력 방향이 위쪽")
	var nodal: Dictionary = model.add_buoyancy_to_solver_loads({}, "top", 0.02)
	_expect(_near(Vector3(nodal["loads"]["top"]).y, 196.133), "아르키메데스 부력이 솔버의 수직 절점하중으로 변환")


func _test_time_dependent_flooding() -> void:
	var model = FLUID.new()
	_expect(bool(model.configure_flood(0.0, 3.0, 0.5)["valid"]), "수위와 상승률 설정")
	var first: Dictionary = model.advance_flood(4.0)
	var member: Dictionary = model.submerged_state_for_vertical_member(0.0, 3.0)
	_expect(_near(float(first["water_level_m"]), 2.0) and bool(first["flood_active"]), "시간 경과에 따라 수위가 상승")
	_expect(_near(float(member["submerged_fraction"]), 2.0 / 3.0), "부분 침수된 수직 부재 높이 산정")
	var last: Dictionary = model.advance_flood(4.0)
	_expect(_near(float(last["water_level_m"]), 3.0) and not bool(last["flood_active"]), "목표 수위에서 상승 정지")
	_expect(_near(float(model.submerged_state_for_vertical_member(0.0, 3.0)["submerged_fraction"]), 1.0), "목표 수위에서 부재 완전 침수")


func _test_solver_pressure_deflection() -> void:
	var fluid = FLUID.new()
	fluid.configure_flood(0.0, 3.0, 0.5)
	fluid.advance_flood(6.0)
	var nodes := [{"id":"base","x_m":0.0,"y_m":0.0},{"id":"top","x_m":0.0,"y_m":3.0}]
	var elements: Array[Dictionary] = [_element()]
	var exposed_surfaces := {"wall":{"width_m":1.0,"normal_global":Vector2.RIGHT}}
	var loads: Dictionary = fluid.build_current_hydrostatic_frame_loads(nodes, elements, exposed_surfaces)
	_expect(bool(loads["valid"]), "정수압을 프레임 요소하중으로 변환")
	if not bool(loads["valid"]):
		return
	var expected_resultant := 0.5 * 1000.0 * 9.80665 * 3.0 * 3.0
	_expect(_near(Vector2(loads["resultant_force_xy_n"]).x, expected_resultant, 1.0e-6), "요소 등가하중 적분 합력이 정수압 적분과 일치")
	var steel: Dictionary = MATERIAL_DB.solver_materials([MATERIAL_DB.get_material("structural_steel")])["structural_steel"]
	var result: Dictionary = SOLVER.new().analyze(
		nodes, elements, {"steel":steel}, {}, {"base":[true,true,true]}, [], {}, loads["element_loads_local_by_id"]
	)
	_expect(bool(result["valid"]), "분포 수압하중 선형 정적 구조해석 수렴")
	if not bool(result["valid"]):
		return
	var tip: Vector3 = result["node_displacements"]["top"]
	var q_bottom := 1000.0 * 9.80665 * 3.0
	var expected_deflection := q_bottom * pow(3.0, 4.0) / (30.0 * 200.0e9 * float(elements[0]["inertia_m4"]))
	_expect(_near(tip.x, expected_deflection, 2.0e-5), "선형 삼각 수압에서 캔틸레버 처짐이 이론해와 일치")
	var buoyancy_model = FLUID.new()
	var buoyancy_loads: Dictionary = buoyancy_model.add_buoyancy_to_solver_loads({}, "top", 0.02)
	var axial_nodes := [{"id":"base","x_m":0.0,"y_m":0.0},{"id":"top","x_m":0.0,"y_m":3.0}]
	var axial_elements: Array[Dictionary] = [_element()]
	var uplift: Dictionary = SOLVER.new().analyze(
		axial_nodes, axial_elements, {"steel":steel}, buoyancy_loads["loads"], {"base":[true,true,true],"top":[true,false,true]}
	)
	var expected_uplift := 196.133 * 3.0 / (200.0e9 * float(axial_elements[0]["area_m2"]))
	_expect(bool(uplift["valid"]) and _near(Vector3(uplift["node_displacements"]["top"]).y, expected_uplift, 1.0e-6), "부력 절점하중이 구조 솔버 축변형에 반영")
	fluid.configure_flood(0.0, 1.5, 0.5)
	fluid.advance_flood(3.0)
	var partial: Dictionary = fluid.build_current_hydrostatic_frame_loads(nodes, elements, exposed_surfaces)
	_expect(_near(Vector2(partial["resultant_force_xy_n"]).x, 0.5 * 1000.0 * 9.80665 * 1.5 * 1.5, 2.0e-5), "수면이 요소 중간을 지나는 부분 침수 하중")


func _element() -> Dictionary:
	return {"id":"wall","node_i":"base","node_j":"top","material_id":"steel","area_m2":0.01,"inertia_m4":8.333333333333333e-6,"depth_m":0.1}


func _near(actual: float, expected: float, tolerance: float = 1.0e-7) -> bool:
	return is_finite(actual) and absf(actual - expected) <= maxf(absf(expected) * tolerance, 1.0e-8)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)
