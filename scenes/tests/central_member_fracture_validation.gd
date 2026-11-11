extends Node2D

const FractureSystemScript := preload("res://scripts/destruction/central_member_fracture_system.gd")

var test_summary := {"passed": 0, "failed": 0, "details": []}


func _ready() -> void:
	_run_static_fracture()
	_run_moving_fracture()
	_run_rotating_fracture()
	_run_joint_remap()
	await _run_floor_collision()
	print("[TASK06_TEST_RESULT] %s" % JSON.stringify(test_summary))


func _run_static_fracture() -> void:
	var source := _make_member("StillMember", Vector2(100.0, 100.0), Vector2(16.0, 80.0), 8.0)
	var system = _new_system()
	var result: Dictionary = system.fracture_member(source)
	_expect(bool(result.get("success", false)), "정지 상태 부재 중앙 파단 성공")
	if not bool(result.get("success", false)):
		return
	var pieces: Array = result["pieces"]
	_expect(pieces.size() == 2, "두 개의 독립 RigidBody2D 생성")
	_expect(is_zero_approx(pieces[0].linear_velocity.length()) and is_zero_approx(pieces[1].linear_velocity.length()), "정지 상태 속도 유지")
	_expect(is_equal_approx(pieces[0].mass + pieces[1].mass, 8.0), "파편 질량 합이 원래 질량과 일치")
	_expect(is_equal_approx(pieces[0].inertia, pieces[1].inertia), "파편별 직사각형 관성모멘트 재계산")
	_expect(pieces[0].get_node_or_null("Visual") is Polygon2D and pieces[1].get_node_or_null("Visual") is Polygon2D, "두 파편의 시각 형상 생성")
	_expect(_halves_meet_without_overlap(pieces[0], pieces[1], Vector2.DOWN), "파편 충돌 형상이 절단면에서 겹치지 않음")
	_expect(system.get_fracture_log().size() == 1, "정지 파단 이벤트 로그 기록")
	_expect(system.get_node_or_null("StillMember-FractureMarker") != null, "중앙 파단 위치 시각화")
	_expect(source.is_queued_for_deletion(), "기존 부재 및 전체 길이 충돌 형상 제거 예약")


func _run_moving_fracture() -> void:
	var source := _make_member("MovingMember", Vector2(300.0, 120.0), Vector2(16.0, 80.0), 10.0)
	source.linear_velocity = Vector2(75.0, -22.0)
	var system = _new_system()
	var result: Dictionary = system.fracture_member(source)
	_expect(bool(result.get("success", false)), "이동 중인 부재 중앙 파단 성공")
	if not bool(result.get("success", false)):
		return
	var pieces: Array = result["pieces"]
	var momentum: Vector2 = pieces[0].linear_velocity * pieces[0].mass + pieces[1].linear_velocity * pieces[1].mass
	_expect(momentum.distance_to(Vector2(75.0, -22.0) * 10.0) < 0.0001, "이동 중 선운동량 보존")
	_expect(pieces[0].linear_velocity.distance_to(Vector2(75.0, -22.0)) < 0.0001, "각속도 0일 때 파편 속도 연속")
	_expect(pieces[1].linear_velocity.distance_to(Vector2(75.0, -22.0)) < 0.0001, "각속도 0일 때 양쪽 속도 연속")


func _run_rotating_fracture() -> void:
	var source := _make_member("RotatingMember", Vector2(520.0, 180.0), Vector2(16.0, 80.0), 12.0)
	source.global_rotation = 0.37
	source.linear_velocity = Vector2(31.0, 17.0)
	source.angular_velocity = 1.4
	var system = _new_system()
	var result: Dictionary = system.fracture_member(source)
	_expect(bool(result.get("success", false)), "회전 중인 부재 중앙 파단 성공")
	if not bool(result.get("success", false)):
		return
	var pieces: Array = result["pieces"]
	var event: Dictionary = result["event"]
	_expect(float(event["linear_momentum_error_kg_px_s"]) < 0.0001, "회전 중 선운동량 보존")
	var angular_momentum_scale := float(event["source_inertia_kg_px2"]) * 1.4
	_expect(float(event["angular_momentum_error_kg_px2_s"]) <= angular_momentum_scale * 1.0e-6, "회전 중 원점 기준 각운동량 보존 (상대오차 %.8f)" % (float(event["angular_momentum_error_kg_px2_s"]) / angular_momentum_scale))
	_expect(is_equal_approx(pieces[0].angular_velocity, 1.4) and is_equal_approx(pieces[1].angular_velocity, 1.4), "파편 각속도 유지")
	_expect(pieces[0].linear_velocity.distance_to(pieces[1].linear_velocity) > 0.1, "회전 속도장의 좌우 차이를 선속도로 반영")
	_expect(_halves_meet_without_overlap(pieces[0], pieces[1], Vector2.DOWN.rotated(0.37)), "회전 파편도 절단면에서 겹치지 않음")


func _run_joint_remap() -> void:
	var source := _make_member("JointedMember", Vector2(700.0, 150.0), Vector2(16.0, 80.0), 8.0)
	var upper_anchor := source.to_global(Vector2(0.0, -20.0))
	var lower_anchor := source.to_global(Vector2(0.0, 20.0))
	var upper_neighbor := _make_member("UpperNeighbor", upper_anchor + Vector2(55.0, 0.0), Vector2(12.0, 20.0), 2.0)
	var lower_neighbor := _make_member("LowerNeighbor", lower_anchor + Vector2(55.0, 0.0), Vector2(12.0, 20.0), 2.0)
	var upper_joint := _make_joint(source, upper_neighbor, upper_anchor)
	var lower_joint := _make_joint(source, lower_neighbor, lower_anchor)
	var system = _new_system()
	var result: Dictionary = system.fracture_member(source)
	_expect(bool(result.get("success", false)), "접합 연결 부재 파단 성공")
	if not bool(result.get("success", false)):
		return
	var pieces: Array = result["pieces"]
	var upper_endpoint := upper_joint.get_node_or_null(upper_joint.node_a)
	var lower_endpoint := lower_joint.get_node_or_null(lower_joint.node_a)
	_expect(upper_endpoint == pieces[0] and lower_endpoint == pieces[1], "기존 Joint 끝점을 파단 위치에 맞춰 재매핑")
	_expect(int(result["event"]["remapped_joint_count"]) == 2, "파단 이벤트에 재매핑한 접합 수 기록")
	await get_tree().process_frame
	_expect(not is_instance_valid(source) and is_instance_valid(upper_joint) and is_instance_valid(lower_joint), "원 부재 제거 후 기존 접합은 유지")


func _run_floor_collision() -> void:
	var floor_body := StaticBody2D.new()
	floor_body.position = Vector2(1100.0, 420.0)
	var floor_shape := CollisionShape2D.new()
	var floor_rectangle := RectangleShape2D.new()
	floor_rectangle.size = Vector2(240.0, 20.0)
	floor_shape.shape = floor_rectangle
	floor_body.add_child(floor_shape)
	add_child(floor_body)
	var source := _make_member("FallingMember", Vector2(1100.0, 100.0), Vector2(20.0, 80.0), 8.0)
	var system = _new_system()
	var result: Dictionary = system.fracture_member(source)
	_expect(bool(result.get("success", false)), "낙하 검증용 부재 파단 성공")
	if not bool(result.get("success", false)):
		return
	await get_tree().create_timer(2.5).timeout
	var pieces: Array = result["pieces"]
	var contacts := int(pieces[0].get_contact_count()) + int(pieces[1].get_contact_count())
	_expect(contacts > 0, "분리된 파편이 중력으로 낙하해 바닥과 충돌 (접촉 %d, y %.1f/%.1f)" % [contacts, pieces[0].global_position.y, pieces[1].global_position.y])
	_expect(pieces[0].global_position.y > 100.0 and pieces[1].global_position.y > 100.0, "두 파편이 독립 강체로 이동")


func _new_system():
	var system = FractureSystemScript.new()
	add_child(system)
	return system


func _make_member(member_name: String, at: Vector2, size: Vector2, mass_kg: float) -> RigidBody2D:
	var member := RigidBody2D.new()
	member.name = member_name
	member.position = at
	member.mass = mass_kg
	member.gravity_scale = 1.0
	member.linear_damp = 0.0
	member.angular_damp = 0.0
	member.collision_layer = 1
	member.collision_mask = 1
	member.contact_monitor = true
	member.max_contacts_reported = 8
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = size
	shape.shape = rectangle
	member.add_child(shape)
	var visual := Polygon2D.new()
	visual.name = "Visual"
	visual.color = Color("#80b6d4")
	visual.polygon = PackedVector2Array([
		Vector2(-size.x * 0.5, -size.y * 0.5),
		Vector2(size.x * 0.5, -size.y * 0.5),
		Vector2(size.x * 0.5, size.y * 0.5),
		Vector2(-size.x * 0.5, size.y * 0.5)
	])
	member.add_child(visual)
	add_child(member)
	member.inertia = mass_kg * (size.x * size.x + size.y * size.y) / 12.0
	return member


func _make_joint(source: RigidBody2D, other: RigidBody2D, anchor: Vector2) -> PinJoint2D:
	var joint := PinJoint2D.new()
	joint.position = anchor
	add_child(joint)
	joint.node_a = joint.get_path_to(source)
	joint.node_b = joint.get_path_to(other)
	return joint


func _halves_meet_without_overlap(piece_a: RigidBody2D, piece_b: RigidBody2D, axis: Vector2) -> bool:
	var center_a := piece_a.global_position.dot(axis)
	var center_b := piece_b.global_position.dot(axis)
	var shape_a := piece_a.get_child(0) as CollisionShape2D
	var shape_b := piece_b.get_child(0) as CollisionShape2D
	var rectangle_a := shape_a.shape as RectangleShape2D
	var rectangle_b := shape_b.shape as RectangleShape2D
	var length_a := maxf(rectangle_a.size.x, rectangle_a.size.y)
	var length_b := maxf(rectangle_b.size.x, rectangle_b.size.y)
	var overlap := (length_a + length_b) * 0.5 - absf(center_b - center_a)
	return absf(overlap) <= 0.0001


func _expect(condition: bool, description: String) -> void:
	if condition:
		test_summary["passed"] += 1
	else:
		test_summary["failed"] += 1
		test_summary["details"].append(description)
	print("[TASK06_TEST_%s] %s" % ["PASS" if condition else "FAIL", description])
