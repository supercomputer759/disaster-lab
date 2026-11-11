extends Node2D

const LinearSolverScript := preload("res://scripts/structure/linear_frame_solver.gd")
const BreakableSystemScript := preload("res://scripts/destruction/breakable_connection_system.gd")

var test_summary := {"passed": 0, "failed": 0, "details": []}


func _ready() -> void:
	await _run_suite()
	print("[TASK05_TEST_RESULT] %s" % JSON.stringify(test_summary))


func _run_suite() -> void:
	for scenario in [
		{"name": "인장", "load": Vector3(500.0, 0.0, 0.0), "axis": Vector2.RIGHT},
		{"name": "압축", "load": Vector3(-500.0, 0.0, 0.0), "axis": Vector2.RIGHT},
		{"name": "전단", "load": Vector3(0.0, 500.0, 0.0), "axis": Vector2.RIGHT},
		{"name": "모멘트", "load": Vector3(0.0, 0.0, 100.0), "axis": Vector2.RIGHT}
	]:
		_run_capacity_case(scenario)
	_run_strength_comparison()
	await _run_release_and_cascade()


func _run_capacity_case(scenario: Dictionary) -> void:
	var ids := ["fixed_%s" % scenario["name"], "joint_%s" % scenario["name"], "tip_%s" % scenario["name"]]
	var model := _solve_model(ids[0], ids[1], ids[2], scenario["load"], scenario["axis"], "case_%s" % scenario["name"])
	_expect(bool(model.get("valid", false)), "%s 구조해석 성공" % scenario["name"])
	if not bool(model.get("valid", false)):
		return
	var demand: Dictionary = model["connection_results"]["case_%s" % scenario["name"]]
	var mode_keys := {
		"인장": "tensile_force_n",
		"압축": "compression_force_n",
		"전단": "shear_force_n",
		"모멘트": "moment_nm"
	}
	var mode_key: String = mode_keys[scenario["name"]]
	_expect(float(demand[mode_key]) > 1.0, "%s 단부력/모멘트 계산" % scenario["name"])
	var setup := _make_joint_connection("case_%s" % scenario["name"], 1.0, false)
	var capacity := _capacities(1.0e12)
	match scenario["name"]:
		"인장": capacity["tensile_capacity_n"] = float(demand["tensile_force_n"]) * 0.5
		"압축": capacity["compression_capacity_n"] = float(demand["compression_force_n"]) * 0.5
		"전단": capacity["shear_capacity_n"] = float(demand["shear_force_n"]) * 0.5
		"모멘트": capacity["moment_capacity_nm"] = float(demand["moment_nm"]) * 0.5
	setup.system.register_connection(
		setup.id, setup.joint, setup.body_a, setup.body_b, ids[0], ids[1], setup.world_position,
		scenario["axis"], capacity, 1.0e7, 2.0e6
	)
	var result_events: Array[Dictionary] = setup.system.evaluate_solver_result(model)
	_expect(result_events.size() == 1, "%s 허용강도 초과로 접합 파괴" % scenario["name"])
	if not result_events.is_empty():
		_expect(result_events[0]["failure_modes"].has(scenario["name"]), "%s 파괴 이벤트 모드 기록" % scenario["name"])
		_expect(result_events[0]["source"] == "linear_static_structural_solver", "물리엔진 반력이 아닌 구조해석 출처 표시")
		_expect(setup.joint.is_queued_for_deletion(), "파괴 시 실제 Godot Joint 제거 예약")
		_expect(setup.system.get_failure_log().size() == 1, "파괴 이벤트 로그 기록")
	_expect(setup.system.get_child_count() >= 1, "파괴 위치 표시 생성")


func _run_strength_comparison() -> void:
	var node_fixed := "strength_fixed"
	var node_joint := "strength_joint"
	var node_tip := "strength_tip"
	var model := _solve_model(node_fixed, node_joint, node_tip, Vector3(500.0, 0.0, 0.0), Vector2.RIGHT, "weak_and_strong")
	_expect(bool(model.get("valid", false)), "서로 다른 강도 비교 구조해석 성공")
	if not bool(model.get("valid", false)):
		return
	var weak := _make_joint_connection("weak", 1.0, false)
	var strong := _make_joint_connection("strong", 1.0, false)
	var weak_capacity := _capacities(1.0e12)
	weak_capacity["tensile_capacity_n"] = 0.01
	var strong_capacity := _capacities(1.0e12)
	strong_capacity["tensile_capacity_n"] = 1.0e12
	weak.system.register_connection("weak_and_strong", weak.joint, weak.body_a, weak.body_b, node_fixed, node_joint, weak.world_position, Vector2.RIGHT, weak_capacity, 1.0e7, 2.0e6)
	weak.system.register_connection("strong_and_strong", strong.joint, strong.body_a, strong.body_b, node_fixed, node_joint, strong.world_position, Vector2.RIGHT, strong_capacity, 1.0e7, 2.0e6)
	var shared_model: Dictionary = model.duplicate(true)
	var shared_demands: Dictionary = shared_model["connection_results"].duplicate(true)
	shared_demands["weak_and_strong"] = model["connection_results"]["weak_and_strong"].duplicate(true)
	shared_demands["strong_and_strong"] = model["connection_results"]["weak_and_strong"].duplicate(true)
	shared_model["connection_results"] = shared_demands
	var events: Array[Dictionary] = weak.system.evaluate_solver_result(shared_model)
	_expect(events.size() == 1, "낮은 강도의 접합부만 파괴")
	_expect(bool(weak.system.get_connection_state("weak_and_strong").get("failed", false)), "약한 접합부 파괴 상태")
	_expect(not bool(weak.system.get_connection_state("strong_and_strong").get("failed", true)), "강한 접합부 유지")


func _run_release_and_cascade() -> void:
	_make_floor()
	var root_body := _make_dynamic_body(Vector2(1100.0, 90.0), 1.0)
	var middle_body := _make_dynamic_body(Vector2(1100.0, 145.0), 1.0)
	var lower_body := _make_dynamic_body(Vector2(1100.0, 200.0), 1.0)
	var connector := _make_pin_joint(root_body, middle_body)
	var downstream := _make_pin_joint(middle_body, lower_body)
	var system := BreakableSystemScript.new()
	add_child(system)
	var capacity := _capacities(1.0)
	var registered: Dictionary = system.register_connection(
		"collapse_support", connector, root_body, middle_body, "collapse_a", "collapse_b", Vector2(1100.0, 120.0),
		Vector2.RIGHT, capacity, 2.0e7, 1.0e6
	)
	_expect(bool(registered.get("success", false)), "실제 물리 붕괴 접합 등록")
	var model := _solve_model("collapse_a", "collapse_b", "collapse_tip", Vector3(500.0, 0.0, 0.0), Vector2.RIGHT, "collapse_support")
	_expect(bool(model.get("valid", false)), "실제 파괴 구동용 구조해석 성공")
	var events: Array[Dictionary] = system.evaluate_solver_result(model)
	_expect(events.size() == 1 and connector.is_queued_for_deletion(), "계산된 초과하중으로 실제 Joint 연결 해제")
	await get_tree().create_timer(2.5).timeout
	var moved := root_body.global_position.y > 100.0 and middle_body.global_position.y > 150.0 and lower_body.global_position.y > 205.0
	_expect(moved, "분리 후 연결된 부재가 중력으로 낙하")
	var contact_count := root_body.get_contact_count() + middle_body.get_contact_count() + lower_body.get_contact_count()
	_expect(contact_count > 0, "낙하 부재가 바닥과 실제 충돌 (접촉 %d, y %.1f/%.1f/%.1f)" % [contact_count, root_body.global_position.y, middle_body.global_position.y, lower_body.global_position.y])
	_expect(is_instance_valid(downstream) and not downstream.is_queued_for_deletion(), "하류 접합은 유지되어 연쇄 움직임 전달")


func _solve_model(node_a: String, node_b: String, node_c: String, load_b: Vector3, axis: Vector2, connection_id: String) -> Dictionary:
	var solver = LinearSolverScript.new()
	var nodes := [
		{"id": node_a, "x_m": 0.0, "y_m": 0.0},
		{"id": node_b, "x_m": 0.0, "y_m": 0.0},
		{"id": node_c, "x_m": 1.0, "y_m": 0.0}
	]
	var elements := [{
		"id": "member_%s" % connection_id,
		"node_i": node_b,
		"node_j": node_c,
		"material_id": "steel",
		"area_m2": 0.01,
		"inertia_m4": 0.000001,
		"depth_m": 0.1
	}]
	var materials := {"steel": {"elastic_modulus_pa": 2.0e11}}
	var loads := {node_b: load_b}
	var supports := {node_a: [true, true, true], node_c: [true, true, true]}
	var connections := [{
		"id": connection_id,
		"node_a": node_a,
		"node_b": node_b,
		"local_axis": axis,
		"translational_stiffness_n_m": 1.0e7,
		"rotational_stiffness_nm_rad": 2.0e6
	}]
	return solver.analyze(nodes, elements, materials, loads, supports, connections)


func _make_joint_connection(connection_id: String, _gravity: float, _collide: bool) -> Dictionary:
	var body_a := _make_dynamic_body(Vector2(100.0, 80.0), 0.0)
	var body_b := _make_dynamic_body(Vector2(140.0, 80.0), 0.0)
	var joint := _make_pin_joint(body_a, body_b)
	var system = BreakableSystemScript.new()
	add_child(system)
	return {"id": connection_id, "body_a": body_a, "body_b": body_b, "joint": joint, "system": system, "world_position": (body_a.global_position + body_b.global_position) * 0.5}


func _make_dynamic_body(at: Vector2, gravity: float) -> RigidBody2D:
	var body := RigidBody2D.new()
	body.position = at
	body.gravity_scale = gravity
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.collision_layer = 1
	body.collision_mask = 1
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = 12.0
	shape.shape = circle
	body.add_child(shape)
	add_child(body)
	return body


func _make_pin_joint(body_a: RigidBody2D, body_b: RigidBody2D) -> PinJoint2D:
	var joint := PinJoint2D.new()
	joint.position = (body_a.global_position + body_b.global_position) * 0.5
	add_child(joint)
	joint.node_a = joint.get_path_to(body_a)
	joint.node_b = joint.get_path_to(body_b)
	return joint


func _capacities(value: float) -> Dictionary:
	return {
		"tensile_capacity_n": value,
		"compression_capacity_n": value,
		"shear_capacity_n": value,
		"moment_capacity_nm": value
	}


func _make_floor() -> void:
	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(1100.0, 440.0)
	var floor_shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(300.0, 20.0)
	floor_shape.shape = rectangle
	floor_body.add_child(floor_shape)
	add_child(floor_body)


func _expect(condition: bool, description: String) -> void:
	if condition:
		test_summary["passed"] += 1
	else:
		test_summary["failed"] += 1
		test_summary["details"].append(description)
	print("[TASK05_TEST_%s] %s" % ["PASS" if condition else "FAIL", description])
