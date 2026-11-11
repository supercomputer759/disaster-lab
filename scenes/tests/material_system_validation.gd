extends Control

const MATERIAL_DB = preload("res://scripts/structure/material_database.gd")
const SOLVER = preload("res://scripts/structure/linear_frame_solver.gd")
const MATERIAL_PANEL = preload("res://scripts/ui/material_library_panel.gd")

@export var test_summary: String = "대기"
var _failures: Array[String] = []
var _checks: int = 0
var _material_panel: Control


func _ready() -> void:
	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_material_panel = MATERIAL_PANEL.new()
	_material_panel.custom_minimum_size = Vector2(640.0, 920.0)
	scroll.add_child(_material_panel)
	add_child(scroll)
	_check_presets_and_mass()
	_compare_same_frame()
	_check_custom_material_validation()
	test_summary = "%s · checks=%d · failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()]
	print("[MATERIAL_TEST] %s" % test_summary)


func _check_presets_and_mass() -> void:
	var ids := MATERIAL_DB.preset_ids()
	_expect(ids.size() == 4, "네 가지 재료 프리셋")
	var volume_m3 := 0.01 * 3.0
	var masses: Dictionary = {}
	for material_id in ids:
		var material: Dictionary = MATERIAL_DB.get_material(material_id)
		var validation: Dictionary = MATERIAL_DB.validate_material(material)
		_expect(bool(validation["valid"]), "%s 필수 물성/단위 유효" % material_id)
		_expect(not str(material.get("source", "")).is_empty() and not str(material.get("assumptions", "")).is_empty(), "%s 출처 및 가정 기록" % material_id)
		masses[material_id] = MATERIAL_DB.mass_kg(material, 0.01, 3.0)
	_expect(float(masses["structural_steel"]) > float(masses["reinforced_concrete"]), "강재 질량이 콘크리트보다 큼")
	_expect(float(masses["reinforced_concrete"]) > float(masses["timber"]), "콘크리트 질량이 목재보다 큼")
	_expect(is_equal_approx(float(masses["structural_steel"]), 235.5), "동일 체적 강재 질량 계산")
	_expect(volume_m3 > 0.0, "SI 체적 계산")


func _compare_same_frame() -> void:
	var nodes := [
		{"id": "L0", "x_m": 0.0, "y_m": 0.0}, {"id": "R0", "x_m": 4.0, "y_m": 0.0},
		{"id": "L1", "x_m": 0.0, "y_m": 3.0}, {"id": "R1", "x_m": 4.0, "y_m": 3.0}
	]
	var supports := {"L0": [true, true, true], "R0": [true, true, true], "L1": [false, false, true], "R1": [false, false, true]}
	var loads := {"L1": Vector3(5000.0, 0.0, 0.0), "R1": Vector3(5000.0, 0.0, 0.0)}
	var deflections: Dictionary = {}
	for material_id in ["structural_steel", "reinforced_concrete", "timber"]:
		var material: Dictionary = MATERIAL_DB.get_material(material_id)
		var solver_materials: Dictionary = MATERIAL_DB.solver_materials([material])
		var elements: Array[Dictionary] = [
			_element("LeftColumn", "L0", "L1", material_id),
			_element("RightColumn", "R0", "R1", material_id),
			_element("TopBeam", "L1", "R1", material_id)
		]
		var result: Dictionary = SOLVER.new().analyze(nodes, elements, solver_materials, loads, supports)
		_expect(bool(result.get("valid", false)), "%s 같은 프레임 선형정적 해석" % material_id)
		if not bool(result.get("valid", false)):
			continue
		var displacement: Vector3 = result["node_displacements"]["L1"]
		deflections[material_id] = absf(displacement.x)
		var element_result: Dictionary = result["element_results"]["LeftColumn"]
		var limit_result: Dictionary = element_result["material_limit_evaluation"]
		_expect(str(element_result["material_id"]) == material_id, "%s 요소별 재료 ID 반영" % material_id)
		_expect(limit_result.has("utilization_by_limit") and limit_result.has("exceeds_provided_limits"), "%s 재료 강도·파괴 한계 평가 반환" % material_id)
	print("[MATERIAL_TEST] 같은 1층 프레임 횡변위 (m): steel=%.9f, concrete=%.9f, timber=%.9f" % [deflections.get("structural_steel", NAN), deflections.get("reinforced_concrete", NAN), deflections.get("timber", NAN)])
	if deflections.size() == 3:
		_expect(float(deflections["structural_steel"]) < float(deflections["reinforced_concrete"]), "강재의 높은 E가 횡변위를 낮춤")
		_expect(float(deflections["reinforced_concrete"]) < float(deflections["timber"]), "콘크리트의 높은 E가 목재보다 횡변위를 낮춤")


func _check_custom_material_validation() -> void:
	var custom := MATERIAL_DB.create_custom_material({
		"id": "sample_custom", "name": "검증 사용자 재료", "density_kg_m3": 1200.0,
		"young_modulus_pa": 12.0e9, "poisson_ratio": 0.25, "yield_strength_pa": null,
		"tensile_strength_pa": 40.0e6, "compressive_strength_pa": 60.0e6,
		"shear_strength_pa": 8.0e6, "fracture_limit_strain": 0.003,
		"source": "테스트 입력", "assumptions": "테스트에서 만든 대표값"
	})
	_expect(bool(custom["valid"]), "사용자 재료 생성 검증")
	if bool(custom["valid"]):
		var saved: Dictionary = MATERIAL_DB.save_custom_material(custom["material"])
		_expect(bool(saved.get("valid", false)), "사용자 재료 user:// 저장")
		var found := false
		for saved_material in MATERIAL_DB.load_custom_materials():
			if str(saved_material.get("id", "")) == "sample_custom":
				found = true
		_expect(found, "사용자 재료 user:// 재읽기")
	var bad := MATERIAL_DB.create_custom_material({"density_kg_m3": -1.0})
	_expect(not bool(bad["valid"]), "잘못된 재료 입력 거부")
	var member := RigidBody2D.new()
	add_child(member)
	var steel: Dictionary = MATERIAL_DB.get_material("structural_steel")
	_material_panel.call("set_member_target", member, 0.01, 3.0)
	var assignment_button: Button = _material_panel.get("assignment_button")
	_expect(not assignment_button.disabled, "선택 부재 재료 할당 UI 활성화")
	var assignment: Dictionary = MATERIAL_DB.assign_to_member(member, steel, 0.01, 3.0)
	_expect(bool(assignment["valid"]), "강체 부재 재료 할당")
	_expect(is_equal_approx(member.mass, 235.5), "부재 질량이 재료 밀도로 계산")
	member.queue_free()


func _element(element_id: String, node_i: String, node_j: String, material_id: String) -> Dictionary:
	return {
		"id": element_id, "node_i": node_i, "node_j": node_j,
		"material_id": material_id, "area_m2": 0.01,
		"inertia_m4": 8.333333333333333e-6, "depth_m": 0.1
	}


func _expect(condition: bool, label: String) -> void:
	if condition:
		_checks += 1
		return
	_failures.append(label)
	push_error("[MATERIAL_TEST] FAIL · %s" % label)
