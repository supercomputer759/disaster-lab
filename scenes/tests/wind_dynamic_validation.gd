extends Node2D

const WIND = preload("res://scripts/physics/wind_load_model.gd")
const DYNAMIC_SOLVER = preload("res://scripts/structure/frame_dynamic_solver.gd")
const STATIC_SOLVER = preload("res://scripts/structure/linear_frame_solver.gd")
const MATERIAL_DB = preload("res://scripts/structure/material_database.gd")

@export var test_summary: String = "대기"
var _checks := 0
var _failures: Array[String] = []


func _ready() -> void:
	_test_pressure_profile_and_direction()
	_test_gust_time_history()
	_test_braced_static_response()
	_test_dynamic_vibration_and_load_superposition()
	test_summary = "%s · checks=%d · failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()]
	print("[WIND_DYNAMIC_TEST] %s" % test_summary)
	for failure in _failures:
		push_error("[WIND_DYNAMIC_TEST] %s" % failure)


func _test_pressure_profile_and_direction() -> void:
	var wind = WIND.new()
	wind.configure(10.0, 10.0, 0.0, 1.225, 0.0)
	_expect(_near(wind.wind_speed_at_height(20.0), 10.0), "0 지수의 균일 풍속 분포")
	_expect(_near(wind.dynamic_pressure_pa(10.0), 61.25), "10m·10m/s 정압이 1/2ρV²와 일치")
	wind.configure(10.0, 10.0, 0.0, 1.225, 0.14)
	_expect(wind.wind_speed_at_height(20.0) > wind.wind_speed_at_height(10.0), "높이가 증가하면 풍속 power-law 프로파일이 증가")
	_expect(_near(wind.dynamic_pressure_pa(20.0) / wind.dynamic_pressure_pa(10.0), pow(2.0, 0.28)), "풍압이 높이별 풍속 제곱에 반영")
	var nodes := [{"id":"base","x_m":0.0,"y_m":0.0},{"id":"top","x_m":0.0,"y_m":10.0}]
	var elements: Array[Dictionary] = [_element("wall","base","top",0.01,8.333333333333333e-6)]
	wind.configure(10.0, 10.0, 0.0, 1.225, 0.0)
	var surface := {"wall":{"width_m":1.0,"outward_normal_global":Vector2.LEFT,"pressure_coefficient":1.0}}
	var force: Dictionary = wind.build_frame_nodal_loads(nodes,elements,surface)
	_expect(bool(force["valid"]) and _near(Vector2(force["resultant_force_xy_n"]).x, 612.5, 1.0e-6), "일정한 10m/s 풍속의 10m² 면 풍력")
	wind.set_wind_direction(90.0)
	var side_load: Dictionary = wind.build_frame_nodal_loads(nodes,elements,surface)
	_expect(Vector2(side_load["resultant_force_xy_n"]).length() < 1.0e-7, "풍향이 벽과 평행하면 정면 풍압이 발생하지 않음")
	var horizontal_nodes := [{"id":"left","x_m":0.0,"y_m":5.0},{"id":"right","x_m":4.0,"y_m":5.0}]
	var horizontal_elements: Array[Dictionary] = [_element("roof","left","right",0.01,1.0e-6)]
	var roof: Dictionary = wind.build_frame_nodal_loads(horizontal_nodes,horizontal_elements,{"roof":{"width_m":1.0,"outward_normal_global":Vector2.UP}})
	_expect(Vector2(roof["resultant_force_xy_n"]).y > 0.0, "90도 풍향 전환 시 표면별 하중이 수직 방향으로 변경")


func _test_gust_time_history() -> void:
	var wind = WIND.new()
	wind.configure(10.0,10.0,0.0,1.225,0.0)
	wind.set_gust(1.0,1.0,20.0)
	var speed_start := wind.wind_speed_at_height(10.0,1.0)
	var speed_peak := wind.wind_speed_at_height(10.0,1.5)
	var speed_end := wind.wind_speed_at_height(10.0,2.0)
	_expect(_near(speed_start,10.0) and _near(speed_peak,30.0) and _near(speed_end,10.0), "반사인 돌풍이 시작·정점·종료 시각에 풍속 변화")
	_expect(_near(wind.dynamic_pressure_pa(10.0,1.5) / wind.dynamic_pressure_pa(10.0,1.0),9.0), "30m/s 돌풍의 동압이 10m/s 기준의 9배")
	var step: Dictionary = wind.advance_time(0.25)
	_expect(bool(step["valid"]) and _near(float(step["time_s"]),0.25), "풍속 입력 시간이 증가")


func _test_braced_static_response() -> void:
	var wind = WIND.new()
	wind.configure(15.0,10.0,0.0,1.225,0.14)
	var model := _portal_model(false)
	var braced := _portal_model(true)
	var wind_load: Dictionary = wind.build_frame_nodal_loads(model["nodes"],model["elements"],{"left_column":{"width_m":1.0,"outward_normal_global":Vector2.LEFT}})
	var brace_load: Dictionary = wind.build_frame_nodal_loads(braced["nodes"],braced["elements"],{"left_column":{"width_m":1.0,"outward_normal_global":Vector2.LEFT}})
	var base_result: Dictionary = STATIC_SOLVER.new().analyze(model["nodes"],model["elements"],model["materials"],wind_load["nodal_loads"],model["supports"])
	var brace_result: Dictionary = STATIC_SOLVER.new().analyze(braced["nodes"],braced["elements"],braced["materials"],brace_load["nodal_loads"],braced["supports"])
	_expect(bool(base_result["valid"]) and bool(brace_result["valid"]), "가새 유무 프레임 모두 정적 풍하중 해석 수렴")
	if not bool(base_result["valid"]) or not bool(brace_result["valid"]):
		return
	var unbraced_top: Vector3 = base_result["node_displacements"]["L1"]
	var braced_top: Vector3 = brace_result["node_displacements"]["L1"]
	_expect(absf(braced_top.x) < absf(unbraced_top.x), "같은 풍하중에서 X형 가새가 1층 포털 변위를 줄임")
	_expect(Vector2(wind_load["resultant_force_xy_n"]).x > 0.0, "풍압 resultant가 바람 이동 방향으로 작용")


func _test_dynamic_vibration_and_load_superposition() -> void:
	var nodes := [{"id":"base","x_m":0.0,"y_m":0.0},{"id":"top","x_m":0.0,"y_m":3.0}]
	var elements: Array[Dictionary] = [_element("column","base","top",0.01,8.333333333333333e-6)]
	var materials := _steel_materials()
	var supports := {"base":[true,true,true]}
	var wind = WIND.new()
	wind.configure(0.0,10.0,0.0,1.225,0.14)
	wind.set_gust(0.05,0.2,20.0)
	var dt := 0.005
	var loads_by_step: Array[Dictionary] = []
	for step in range(200):
		var load: Dictionary = wind.build_frame_nodal_loads(nodes,elements,{"column":{"width_m":1.0,"outward_normal_global":Vector2.LEFT}},float(step+1)*dt)
		loads_by_step.append(load["nodal_loads"])
	var dynamics = DYNAMIC_SOLVER.new()
	var response: Dictionary = dynamics.simulate(nodes,elements,materials,supports,loads_by_step,dt,0.01,4.0)
	_expect(bool(response["valid"]), "돌풍 nodal load time-history Newmark 동적 응답")
	if not bool(response["valid"]):
		push_error("[WIND_DYNAMIC_TEST] Newmark error: %s" % str(response.get("error","")))
		return
	_expect(float(response["peak_lateral_displacement_m"]) > 0.0 and int(response["sample_count"]) == 201, "돌풍 응답 최대 횡변위와 시간표본 기록")
	var late_min := INF
	var late_max := -INF
	for sample in response["time_history"]:
		if float(sample["time_s"]) < 0.30:
			continue
		var tip: Vector3 = sample["node_displacements_m_rad"]["top"]
		late_min = minf(late_min, tip.x)
		late_max = maxf(late_max, tip.x)
	_expect(late_max - late_min > 1.0e-6, "돌풍 종료 후 시간 이력에 구조물 자유진동이 남음")
	var static_wind: Dictionary = wind.build_frame_nodal_loads(nodes,elements,{"column":{"width_m":1.0,"outward_normal_global":Vector2.LEFT}},0.15)
	var mass: Dictionary = response["nodal_lumped_mass_kg"]
	var quake: Dictionary = dynamics.base_excitation_loads(mass,Vector2(0.1,0.0))
	var combined: Dictionary = dynamics.combine_nodal_loads(static_wind["nodal_loads"],quake["loads"])
	_expect(bool(quake["valid"]) and bool(combined["valid"]), "등가 지진 관성하중과 풍하중을 같은 SI 노달 하중에 합산")
	var wind_only: Dictionary = STATIC_SOLVER.new().analyze(nodes,elements,materials,static_wind["nodal_loads"],supports)
	var quake_only: Dictionary = STATIC_SOLVER.new().analyze(nodes,elements,materials,quake["loads"],supports)
	var both: Dictionary = STATIC_SOLVER.new().analyze(nodes,elements,materials,combined["loads"],supports)
	_expect(bool(wind_only["valid"]) and bool(quake_only["valid"]) and bool(both["valid"]), "풍하중·지진하중 개별/동시 해석")
	if bool(wind_only["valid"]) and bool(quake_only["valid"]) and bool(both["valid"]):
		var superposed := float(wind_only["node_displacements"]["top"].x) + float(quake_only["node_displacements"]["top"].x)
		_expect(_near(float(both["node_displacements"]["top"].x),superposed,1.0e-5), "선형 해석에서 동시 풍·지진 변위가 개별 해석 합과 일치")


func _portal_model(with_braces: bool) -> Dictionary:
	var nodes := [
		{"id":"L0","x_m":0.0,"y_m":0.0},{"id":"R0","x_m":4.0,"y_m":0.0},
		{"id":"L1","x_m":0.0,"y_m":3.0},{"id":"R1","x_m":4.0,"y_m":3.0}
	]
	var elements: Array[Dictionary] = [
		_element("left_column","L0","L1",0.01,8.333333333333333e-6),
		_element("right_column","R0","R1",0.01,8.333333333333333e-6),
		_element("beam","L1","R1",0.01,8.333333333333333e-6)
	]
	if with_braces:
		elements.append(_element("brace_a","L0","R1",0.001,1.0e-7))
		elements.append(_element("brace_b","R0","L1",0.001,1.0e-7))
	return {
		"nodes":nodes,"elements":elements,"materials":_steel_materials(),
		"supports":{"L0":[true,true,true],"R0":[true,true,true],"L1":[false,false,true],"R1":[false,false,true]}
	}


func _steel_materials() -> Dictionary:
	return MATERIAL_DB.solver_materials([MATERIAL_DB.get_material("structural_steel")])


func _element(id: String, node_i: String, node_j: String, area: float, inertia: float) -> Dictionary:
	return {"id":id,"node_i":node_i,"node_j":node_j,"material_id":"structural_steel","area_m2":area,"inertia_m4":inertia,"depth_m":0.1}


func _near(actual: float, expected: float, tolerance: float = 1.0e-7) -> bool:
	return is_finite(actual) and absf(actual-expected) <= maxf(absf(expected)*tolerance,1.0e-8)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(label)
