extends Node2D

const FAILURE_MODEL = preload("res://scripts/structure/failure_mechanics.gd")
const SOLVER = preload("res://scripts/structure/linear_frame_solver.gd")

@export var test_summary: String = "대기"
var _checks := 0
var _failures: Array[String] = []
var _crack_fraction := -1.0
var _buckling_ratio := 0.0


func _ready() -> void:
	_test_euler_buckling()
	_test_fatigue_and_crack()
	_test_solver_crack_location()
	_test_progressive_redistribution()
	test_summary = "%s · checks=%d · failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()]
	print("[FAILURE_MECHANICS_TEST] %s" % test_summary)
	queue_redraw()


func _test_euler_buckling() -> void:
	var pinned := FAILURE_MODEL.euler_buckling(200000.0, 200.0e9, 1.0e-6, 3.0, 1.0)
	var fixed_fixed := FAILURE_MODEL.euler_buckling(200000.0, 200.0e9, 1.0e-6, 3.0, 0.5)
	var fixed_free := FAILURE_MODEL.euler_buckling(200000.0, 200.0e9, 1.0e-6, 3.0, 2.0)
	_expect(bool(pinned["valid"]) and bool(fixed_fixed["valid"]) and bool(fixed_free["valid"]), "Euler 좌굴 세 경계조건 계산")
	_expect(_near(float(pinned["euler_critical_load_n"]), PI * PI * 200.0e9 * 1.0e-6 / 9.0), "양단 힌지 임계하중이 Euler 식과 일치")
	_expect(_near(float(fixed_fixed["euler_critical_load_n"]), float(pinned["euler_critical_load_n"]) * 4.0), "양단 고정 경계가 임계하중을 4배로 높임")
	_expect(_near(float(fixed_free["euler_critical_load_n"]), float(pinned["euler_critical_load_n"]) * 0.25), "고정-자유 경계가 임계하중을 1/4로 낮춤")
	_buckling_ratio = float(pinned["buckling_utilization"])
	var invalid := FAILURE_MODEL.euler_buckling(1.0, 2.0e11, 1.0e-6, 3.0, 0.0)
	_expect(not bool(invalid["valid"]), "잘못된 유효길이 계수 거부")


func _test_fatigue_and_crack() -> void:
	var mechanics = FAILURE_MODEL.new()
	var first: Dictionary = mechanics.record_fatigue_cycles("column-fatigue", 200.0e6, 10.0, 600.0e6, 3.0, 0.3, 0.2)
	var second: Dictionary = mechanics.record_fatigue_cycles("column-fatigue", 200.0e6, 10.0, 600.0e6, 3.0, 0.3, 0.2)
	var third: Dictionary = mechanics.record_fatigue_cycles("column-fatigue", 200.0e6, 8.0, 600.0e6, 3.0, 0.3, 0.2)
	_expect(bool(first["valid"]) and bool(second["valid"]) and bool(third["valid"]), "Miner 누적손상 입력 처리")
	_expect(_near(float(first["state"]["damage"]), 10.0 / 27.0), "Miner 첫 손상 증가량 n/Nf")
	_expect(bool(first["state"]["cracked"]), "누적 손상이 균열 개시 기준을 넘음")
	_expect(bool(third["state"]["failed"]) and float(third["state"]["damage"]) >= 1.0, "Miner 누적 손상 1에서 피로 파괴")
	_expect(_near(float(mechanics.get_damage_events()[0]["position_fraction"]), 0.2), "균열 시각화 좌표가 지정된 부재 비율을 저장")


func _test_solver_crack_location() -> void:
	var solver_result: Dictionary = SOLVER.new().analyze(
		[{"id":"base","x_m":0.0,"y_m":0.0},{"id":"tip","x_m":3.0,"y_m":0.0}],
		[_element("cantilever","base","tip","elastic",0.01)],
		{"elastic":{"elastic_modulus_pa":200.0e9}},
		{"tip":Vector3(0.0,-10000.0,0.0)}, {"base":[true,true,true]}
	)
	_expect(bool(solver_result.get("valid", false)), "균열 위치 계산용 외팔보 해석")
	if not bool(solver_result.get("valid", false)):
		return
	var result: Dictionary = solver_result["element_results"]["cantilever"]
	var mechanics = FAILURE_MODEL.new()
	var crack: Dictionary = mechanics.record_solver_crack("cantilever", result, 1.0e6, 3.0)
	_expect(bool(crack["cracked"]), "계산 인장응력이 재료 한계를 넘을 때 균열 개시")
	_expect(float(crack["peak_tensile_stress_pa"]) > 1.0e6, "균열 개시가 구조해석 정상응력에 근거")
	_crack_fraction = float(crack["crack_position_fraction"])
	_expect(float(crack["crack_position_m"]) >= 0.0 and float(crack["crack_position_m"]) <= 3.0, "균열 좌표가 요소 길이 안에 위치")


func _test_progressive_redistribution() -> void:
	var model := _portal_model(1.0e12)
	var baseline: Dictionary = SOLVER.new().analyze(model["nodes"], model["elements"], model["materials"], model["loads"], model["supports"])
	var after_left_removal_elements: Array = [model["elements"][1], model["elements"][2]]
	var redistributed: Dictionary = SOLVER.new().analyze(model["nodes"], after_left_removal_elements, model["materials"], model["loads"], model["supports"])
	_expect(bool(baseline.get("valid", false)) and bool(redistributed.get("valid", false)), "부재 제거 전후 구조해석 수렴")
	if not bool(baseline.get("valid", false)) or not bool(redistributed.get("valid", false)):
		return
	var before_stress := _max_abs_member_stress(baseline["element_results"]["right_column"])
	var after_stress := _max_abs_member_stress(redistributed["element_results"]["right_column"])
	_expect(after_stress > before_stress, "좌측 기둥 제거 후 우측 기둥 응력 재분배 증가")
	var threshold := (before_stress + after_stress) * 0.5
	model["materials"]["right"]["compressive_strength_pa"] = threshold
	model["materials"]["right"]["tensile_strength_pa"] = threshold
	var collapse: Dictionary = FAILURE_MODEL.progressive_reanalysis(model, ["left_column"], 5)
	_expect(bool(collapse["valid"]), "요소 제거 후 반복 구조 재해석 실행")
	_expect(bool(collapse["collapsed"]), "후속 한계 초과 후 불안정행렬을 전체 붕괴로 보고")
	_expect(collapse["removed_member_ids"].has("left_column") and collapse["removed_member_ids"].has("right_column"), "초기 파괴 후 용량 초과 요소 연쇄 제거")
	_expect((collapse["steps"] as Array).size() >= 2, "매 부재 제거 후 재해석 단계 저장")
	print("[FAILURE_MECHANICS_TEST] 하중 재분배 정상응력 Pa: %.3f -> %.3f · removed=%s" % [before_stress, after_stress, str(collapse["removed_member_ids"])])


func _portal_model(capacity_pa: float) -> Dictionary:
	var nodes := [
		{"id":"L0","x_m":0.0,"y_m":0.0},{"id":"R0","x_m":4.0,"y_m":0.0},
		{"id":"L1","x_m":0.0,"y_m":3.0},{"id":"R1","x_m":4.0,"y_m":3.0}
	]
	var elements: Array[Dictionary] = [
		_element("left_column","L0","L1","left",0.01),
		_element("right_column","R0","R1","right",0.01),
		_element("beam","L1","R1","beam",0.01)
	]
	var strong := {"elastic_modulus_pa":200.0e9,"tensile_strength_pa":capacity_pa,"compressive_strength_pa":capacity_pa,"shear_strength_pa":1.0e12,"fracture_limit_strain":1.0}
	return {
		"nodes":nodes,"elements":elements,
		"materials":{"left":strong.duplicate(true),"right":strong.duplicate(true),"beam":strong.duplicate(true)},
		"loads":{"L1":Vector3(5000.0,0.0,0.0),"R1":Vector3(5000.0,0.0,0.0)},
		"supports":{"L0":[true,true,true],"R0":[true,true,true],"L1":[false,false,true],"R1":[false,false,true]}
	}


func _element(element_id: String, node_i: String, node_j: String, material_id: String, area_m2: float) -> Dictionary:
	return {"id":element_id,"node_i":node_i,"node_j":node_j,"material_id":material_id,"area_m2":area_m2,"inertia_m4":8.333333333333333e-6,"depth_m":0.1}


func _max_abs_member_stress(result: Dictionary) -> float:
	var maximum := 0.0
	for key in ["normal_stress_i_top_pa","normal_stress_i_bottom_pa","normal_stress_j_top_pa","normal_stress_j_bottom_pa"]:
		maximum = maxf(maximum, absf(float(result[key])))
	return maximum


func _near(actual: float, expected: float) -> bool:
	return is_finite(actual) and absf(actual-expected) <= maxf(1.0e-7*absf(expected),1.0e-8)


func _expect(condition: bool, message: String) -> void:
	if condition:
		_checks += 1
	else:
		_failures.append(message)
		push_error("[FAILURE_MECHANICS_TEST] FAIL · %s" % message)


func _draw() -> void:
	var start := Vector2(100.0, 100.0)
	var finish := Vector2(100.0, 400.0)
	draw_line(start, finish, Color("#7a92a8"), 8.0)
	if _buckling_ratio >= 0.9:
		var amplitude := 30.0 * _buckling_ratio
		draw_polyline(PackedVector2Array([start, start.lerp(finish,0.25)+Vector2(amplitude,0.0), start.lerp(finish,0.5), start.lerp(finish,0.75)+Vector2(-amplitude,0.0), finish]), Color("#ff6262"), 3.0)
	if _crack_fraction >= 0.0:
		var crack_y := lerpf(start.y,finish.y,_crack_fraction)
		draw_line(Vector2(88.0,crack_y-6.0),Vector2(112.0,crack_y+6.0),Color("#ffbf56"),5.0)
