extends Node2D

const SOLVER_SCRIPT = preload("res://scripts/structure/linear_frame_solver.gd")
const ELASTIC_STEEL := {"elastic_modulus_pa": 200.0e9}
const AREA_M2 := 0.01
const INERTIA_M4 := 8.333333333333333e-6
const DEPTH_M := 0.1

@export var test_summary: String = "대기"
var _failures: Array[String] = []
var _assertion_count: int = 0


func _ready() -> void:
	_run_simple_beam()
	_run_cantilever()
	_run_axial_column()
	_run_2d_frame()
	_run_singular_matrix_check()
	test_summary = "%s · checks=%d · failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _assertion_count, _failures.size()]
	print("[FRAME_SOLVER_TEST] %s · 5 cases" % test_summary)


func _run_simple_beam() -> void:
	var span_m := 5.0
	var load_n := 10000.0
	var nodes := [
		_node("A", 0.0, 0.0),
		_node("M", span_m * 0.5, 0.0),
		_node("B", span_m, 0.0)
	]
	var elements := [
		_element("AB1", "A", "M"),
		_element("AB2", "M", "B")
	]
	var supports := {"A": [true, true, false], "B": [false, true, false]}
	var result: Dictionary = _solver().analyze(nodes, elements, {"steel": ELASTIC_STEEL}, {"M": Vector3(0.0, -load_n, 0.0)}, supports)
	var expected_deflection := load_n * pow(span_m, 3.0) / (48.0 * ELASTIC_STEEL["elastic_modulus_pa"] * INERTIA_M4)
	_check(result, "simple beam")
	if bool(result.get("valid", false)):
		var actual: Vector3 = result["node_displacements"]["M"]
		_check_near("단순보 중앙 처짐", actual.y, -expected_deflection, 1.0e-7)
		_check_near("단순보 왼쪽 반력", (result["support_reactions"]["A"] as Vector3).y, load_n * 0.5, 1.0e-7)
		_check_near("단순보 오른쪽 반력", (result["support_reactions"]["B"] as Vector3).y, load_n * 0.5, 1.0e-7)
		var first_element: Dictionary = result["element_results"]["AB1"]
		_check_near("단순보 단부모멘트", float(first_element["bending_moment_i_nm"]), 0.0, 1.0e-7)
		_check_near("단순보 중앙 모멘트", absf(float(first_element["bending_moment_j_nm"])), load_n * span_m * 0.25, 1.0e-7)
		_check_near("단순보 휨응력 출력", absf(float(first_element["normal_stress_j_bottom_pa"])), load_n * span_m * 0.25 * (DEPTH_M * 0.5) / INERTIA_M4, 1.0e-7)
		print("[FRAME_SOLVER_TEST] 단순보 PASS · 중앙처짐=%.9f m 이론=%.9f m" % [actual.y, -expected_deflection])


func _run_cantilever() -> void:
	var span_m := 3.0
	var load_n := 1000.0
	var nodes := [_node("F", 0.0, 0.0), _node("T", span_m, 0.0)]
	var supports := {"F": [true, true, true]}
	var result: Dictionary = _solver().analyze(
		nodes, [_element("Cantilever", "F", "T")], {"steel": ELASTIC_STEEL},
		{"T": Vector3(0.0, -load_n, 0.0)}, supports
	)
	var expected_deflection := load_n * pow(span_m, 3.0) / (3.0 * ELASTIC_STEEL["elastic_modulus_pa"] * INERTIA_M4)
	_check(result, "cantilever")
	if bool(result.get("valid", false)):
		var tip: Vector3 = result["node_displacements"]["T"]
		var root_reaction: Vector3 = result["support_reactions"]["F"]
		var element_result: Dictionary = result["element_results"]["Cantilever"]
		_check_near("외팔보 끝 처짐", tip.y, -expected_deflection, 1.0e-7)
		_check_near("외팔보 고정단 모멘트", absf(float(element_result["bending_moment_i_nm"])), load_n * span_m, 1.0e-7)
		_check_near("외팔보 지점 반력", root_reaction.y, load_n, 1.0e-7)
		_check_near("외팔보 반력 모멘트", absf(root_reaction.z), load_n * span_m, 1.0e-7)
		print("[FRAME_SOLVER_TEST] 외팔보 PASS · 끝처짐=%.9f m 이론=%.9f m" % [tip.y, -expected_deflection])


func _run_axial_column() -> void:
	var length_m := 3.0
	var load_n := 100000.0
	var nodes := [_node("Base", 0.0, 0.0), _node("Top", 0.0, length_m)]
	var supports := {"Base": [true, true, true], "Top": [true, false, true]}
	var result: Dictionary = _solver().analyze(
		nodes, [_element("Column", "Base", "Top")], {"steel": ELASTIC_STEEL},
		{"Top": Vector3(0.0, -load_n, 0.0)}, supports
	)
	var expected_displacement := load_n * length_m / (ELASTIC_STEEL["elastic_modulus_pa"] * AREA_M2)
	var expected_stress := load_n / AREA_M2
	_check(result, "axial column")
	if bool(result.get("valid", false)):
		var top: Vector3 = result["node_displacements"]["Top"]
		var element_result: Dictionary = result["element_results"]["Column"]
		_check_near("축기둥 변위", top.y, -expected_displacement, 1.0e-7)
		_check_near("축기둥 축력", float(element_result["axial_force_i_n"]), -load_n, 1.0e-7)
		_check_near("축기둥 응력", float(element_result["normal_stress_i_top_pa"]), -expected_stress, 1.0e-7)
		_check_near("축기둥 변형률", float(element_result["axial_strain"]), -expected_stress / ELASTIC_STEEL["elastic_modulus_pa"], 1.0e-7)
		print("[FRAME_SOLVER_TEST] 축하중 기둥 PASS · 축변위=%.9f m 이론=%.9f m" % [top.y, -expected_displacement])


func _run_2d_frame() -> void:
	var column_height_m := 3.0
	var lateral_load_each_n := 500.0
	var nodes := [
		_node("L0", 0.0, 0.0), _node("R0", 4.0, 0.0),
		_node("L1", 0.0, column_height_m), _node("R1", 4.0, column_height_m)
	]
	var elements := [
		_element("LeftColumn", "L0", "L1"),
		_element("RightColumn", "R0", "R1"),
		_element("TopBeam", "L1", "R1")
	]
	var supports := {
		"L0": [true, true, true], "R0": [true, true, true],
		"L1": [false, false, true], "R1": [false, false, true]
	}
	var loads := {
		"L1": Vector3(lateral_load_each_n, 0.0, 0.0),
		"R1": Vector3(lateral_load_each_n, 0.0, 0.0)
	}
	var result: Dictionary = _solver().analyze(nodes, elements, {"steel": ELASTIC_STEEL}, loads, supports)
	var expected_drift := lateral_load_each_n * pow(column_height_m, 3.0) / (12.0 * ELASTIC_STEEL["elastic_modulus_pa"] * INERTIA_M4)
	_check(result, "2D frame")
	if bool(result.get("valid", false)):
		var left_top: Vector3 = result["node_displacements"]["L1"]
		var right_top: Vector3 = result["node_displacements"]["R1"]
		_check_near("2D 프레임 좌우 층변위 일치", left_top.x, right_top.x, 1.0e-7)
		_check_near("2D 프레임 고정-가이드 기둥 변위", left_top.x, expected_drift, 1.0e-7)
		var reaction_sum_x := 0.0
		for reaction in result["support_reactions"].values():
			reaction_sum_x += (reaction as Vector3).x
		_check_near("2D 프레임 수평 평형", reaction_sum_x, -lateral_load_each_n * 2.0, 1.0e-7)
		print("[FRAME_SOLVER_TEST] 2D 프레임 PASS · 층변위=%.9f m 이론=%.9f m" % [left_top.x, expected_drift])


func _run_singular_matrix_check() -> void:
	var result: Dictionary = _solver().analyze(
		[_node("A", 0.0, 0.0), _node("B", 2.0, 0.0)],
		[_element("E", "A", "B")], {"steel": ELASTIC_STEEL}, {}, {}
	)
	if bool(result.get("valid", true)) or not str(result.get("error", "")).contains("특이"):
		_failures.append("불안정한 경계조건을 오류로 알리지 않았어.")
		push_error("[FRAME_SOLVER_TEST] 특이행렬 검사 FAIL · %s" % str(result.get("error", "")))
	else:
		_assertion_count += 1
		print("[FRAME_SOLVER_TEST] 특이행렬 명시 오류 PASS · %s" % str(result["error"]))


func _solver():
	return SOLVER_SCRIPT.new()


func _node(node_id: String, x_m: float, y_m: float) -> Dictionary:
	return {"id": node_id, "x_m": x_m, "y_m": y_m}


func _element(element_id: String, node_i: String, node_j: String) -> Dictionary:
	return {
		"id": element_id,
		"node_i": node_i,
		"node_j": node_j,
		"material_id": "steel",
		"area_m2": AREA_M2,
		"inertia_m4": INERTIA_M4,
		"depth_m": DEPTH_M
	}


func _check(result: Dictionary, case_name: String) -> void:
	if not bool(result.get("valid", false)):
		_failures.append("%s: %s" % [case_name, str(result.get("error", "no error detail"))])
		push_error("[FRAME_SOLVER_TEST] %s FAIL · %s" % [case_name, str(result.get("error", "no error detail"))])
	else:
		_assertion_count += 1


func _check_near(label: String, actual: float, expected: float, relative_tolerance: float) -> void:
	var allowed := maxf(absf(expected) * relative_tolerance, 1.0e-10)
	if not is_finite(actual) or absf(actual - expected) > allowed:
		_failures.append("%s: actual=%.12g expected=%.12g" % [label, actual, expected])
		push_error("[FRAME_SOLVER_TEST] %s FAIL · actual=%.12g expected=%.12g" % [label, actual, expected])
	else:
		_assertion_count += 1
