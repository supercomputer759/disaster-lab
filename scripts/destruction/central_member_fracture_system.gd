extends Node2D
class_name CentralMemberFractureSystem

signal member_fractured(event: Dictionary)

const FAILURE_MARKER_SCRIPT := preload("res://scripts/destruction/member_fracture_marker.gd")
const CENTER_TOLERANCE_PX := 0.01

var _fracture_log: Array[Dictionary] = []


func fracture_member(member: RigidBody2D, local_fracture_position: Vector2 = Vector2.ZERO) -> Dictionary:
	if not is_instance_valid(member) or not is_zero_approx(local_fracture_position.length()):
		return {"success": false, "error": "초기 버전은 유효한 부재의 중앙 파단만 지원해."}
	var shape_node := _get_member_shape(member)
	if shape_node == null or not shape_node.shape is RectangleShape2D:
		return {"success": false, "error": "부재에는 CollisionShape2D 직사각형 하나가 필요해."}
	if shape_node.position.length() > CENTER_TOLERANCE_PX or not is_zero_approx(shape_node.rotation):
		return {"success": false, "error": "중앙 파단은 부재 중심에 정렬된 충돌 형상만 지원해."}
	var rectangle := shape_node.shape as RectangleShape2D
	var source_size := rectangle.size
	if not source_size.is_finite() or source_size.x <= 0.0 or source_size.y <= 0.0:
		return {"success": false, "error": "부재 충돌 형상의 크기가 올바르지 않아."}
	var split_on_y := source_size.y >= source_size.x
	var split_length := source_size.y if split_on_y else source_size.x
	if split_length < 4.0 or (member.global_scale - Vector2.ONE).length() > CENTER_TOLERANCE_PX or (shape_node.scale - Vector2.ONE).length() > CENTER_TOLERANCE_PX:
		return {"success": false, "error": "부재 크기가 너무 작거나 전역 배율이 1이 아니야."}
	if not is_finite(member.mass) or member.mass <= 0.0 or not member.linear_velocity.is_finite() or not is_finite(member.angular_velocity):
		return {"success": false, "error": "부재의 질량 또는 운동 상태가 유효하지 않아."}
	var parent := member.get_parent()
	if parent == null:
		return {"success": false, "error": "부재를 씬 트리에 추가한 뒤 파단해야 해."}
	var fragment_size := source_size
	if split_on_y:
		fragment_size.y *= 0.5
	else:
		fragment_size.x *= 0.5
	var local_axis := Vector2.DOWN if split_on_y else Vector2.RIGHT
	var global_axis := local_axis.rotated(member.global_rotation)
	var source_position := member.global_position
	var source_rotation := member.global_rotation
	var source_mass := member.mass
	var source_velocity := member.linear_velocity
	var source_angular_velocity := member.angular_velocity
	var calculated_source_inertia := _rectangle_inertia(source_mass, source_size)
	var source_inertia := member.inertia if member.inertia > 0.0 else calculated_source_inertia
	if absf(source_inertia - calculated_source_inertia) > maxf(calculated_source_inertia * 1.0e-5, 0.0001):
		return {"success": false, "error": "부재 관성모멘트가 충돌 형상의 균일 직사각형 계산과 달라 파단을 중단했어."}
	var quarter_length := split_length * 0.25
	var negative_offset := -global_axis * quarter_length
	var positive_offset := global_axis * quarter_length
	var negative_piece := _create_fragment(member, parent, "A", source_position + negative_offset, source_rotation, fragment_size, source_mass * 0.5)
	var positive_piece := _create_fragment(member, parent, "B", source_position + positive_offset, source_rotation, fragment_size, source_mass * 0.5)
	if negative_piece == null or positive_piece == null:
		if is_instance_valid(negative_piece):
			negative_piece.queue_free()
		if is_instance_valid(positive_piece):
			positive_piece.queue_free()
		return {"success": false, "error": "파편 강체 생성에 실패했어."}
	var piece_inertia := _rectangle_inertia(source_mass * 0.5, fragment_size)
	negative_piece.inertia = piece_inertia
	positive_piece.inertia = piece_inertia
	negative_piece.linear_velocity = source_velocity + _rotational_velocity(negative_offset, source_angular_velocity)
	positive_piece.linear_velocity = source_velocity + _rotational_velocity(positive_offset, source_angular_velocity)
	negative_piece.angular_velocity = source_angular_velocity
	positive_piece.angular_velocity = source_angular_velocity
	var remapped_joint_count := _remap_joint_endpoints(member, negative_piece, positive_piece, local_axis)
	var linear_momentum_before := source_velocity * source_mass
	var linear_momentum_after := negative_piece.linear_velocity * negative_piece.mass + positive_piece.linear_velocity * positive_piece.mass
	var angular_momentum_before := source_inertia * source_angular_velocity
	var angular_momentum_after := _angular_momentum_about_source(
		negative_piece, source_position, piece_inertia
	) + _angular_momentum_about_source(positive_piece, source_position, piece_inertia)
	shape_node.queue_free()
	member.queue_free()
	var marker := FAILURE_MARKER_SCRIPT.new() as Node2D
	marker.name = "%s-FractureMarker" % member.name
	add_child(marker)
	marker.global_position = source_position
	var event := {
		"member_name": member.name,
		"fracture_world_position": source_position,
		"piece_names": [negative_piece.name, positive_piece.name],
		"source_mass_kg": source_mass,
		"fragment_mass_kg": source_mass * 0.5,
		"source_inertia_kg_px2": source_inertia,
		"fragment_inertia_kg_px2": piece_inertia,
		"linear_momentum_error_kg_px_s": (linear_momentum_before - linear_momentum_after).length(),
		"angular_momentum_error_kg_px2_s": absf(angular_momentum_before - angular_momentum_after),
		"remapped_joint_count": remapped_joint_count
	}
	_fracture_log.append(event)
	print("[부재 파단] %s 중앙 | 파편 2개 | 운동량 보존 오차 %.6f" % [member.name, event["linear_momentum_error_kg_px_s"]])
	member_fractured.emit(event)
	return {"success": true, "pieces": [negative_piece, positive_piece], "event": event}


func get_fracture_log() -> Array[Dictionary]:
	return _fracture_log.duplicate(true)


func _get_member_shape(member: RigidBody2D) -> CollisionShape2D:
	var collision_shapes: Array[CollisionShape2D] = []
	for child in member.get_children():
		if child is CollisionShape2D and not child.disabled:
			collision_shapes.append(child as CollisionShape2D)
	if collision_shapes.size() != 1:
		return null
	return collision_shapes[0]


func _create_fragment(
	source: RigidBody2D,
	parent: Node,
	suffix: String,
	world_position: Vector2,
	world_rotation: float,
	shape_size: Vector2,
	fragment_mass: float
) -> RigidBody2D:
	var fragment := RigidBody2D.new()
	fragment.name = "%s-fragment-%s" % [source.name, suffix]
	fragment.mass = fragment_mass
	fragment.gravity_scale = source.gravity_scale
	fragment.linear_damp = source.linear_damp
	fragment.angular_damp = source.angular_damp
	fragment.can_sleep = source.can_sleep
	fragment.contact_monitor = source.contact_monitor
	fragment.max_contacts_reported = source.max_contacts_reported
	fragment.collision_layer = source.collision_layer
	fragment.collision_mask = source.collision_mask
	fragment.collision_priority = source.collision_priority
	fragment.continuous_cd = source.continuous_cd
	fragment.lock_rotation = source.lock_rotation
	fragment.physics_material_override = source.physics_material_override
	var fragment_shape := CollisionShape2D.new()
	var half_rectangle := RectangleShape2D.new()
	half_rectangle.size = shape_size
	fragment_shape.shape = half_rectangle
	fragment.add_child(fragment_shape)
	var source_visual: Polygon2D
	for child in source.get_children():
		if child is Polygon2D:
			source_visual = child as Polygon2D
			break
	var half_visual := Polygon2D.new()
	half_visual.name = "Visual"
	var half_width := shape_size.x * 0.5
	var half_height := shape_size.y * 0.5
	half_visual.polygon = PackedVector2Array([
		Vector2(-half_width, -half_height),
		Vector2(half_width, -half_height),
		Vector2(half_width, half_height),
		Vector2(-half_width, half_height)
	])
	if is_instance_valid(source_visual):
		half_visual.color = source_visual.color
		half_visual.z_index = source_visual.z_index
		half_visual.texture = source_visual.texture
		half_visual.material = source_visual.material
	else:
		half_visual.color = Color("#91c7dc")
	fragment.add_child(half_visual)
	fragment.inertia = _rectangle_inertia(fragment_mass, shape_size)
	parent.add_child(fragment)
	fragment.global_position = world_position
	fragment.global_rotation = world_rotation
	fragment.linear_velocity = source.linear_velocity
	fragment.angular_velocity = source.angular_velocity
	fragment.sleeping = false
	return fragment


func _remap_joint_endpoints(
	source: RigidBody2D,
	negative_piece: RigidBody2D,
	positive_piece: RigidBody2D,
	local_axis: Vector2
) -> int:
	var joints: Array[Joint2D] = []
	_collect_joints(get_tree().root, joints)
	var remapped_count := 0
	for joint in joints:
		for endpoint_key in ["node_a", "node_b"]:
			var endpoint_path: NodePath = joint.get(endpoint_key)
			if endpoint_path.is_empty() or joint.get_node_or_null(endpoint_path) != source:
				continue
			var anchor_local := source.to_local(joint.global_position)
			var side_coordinate := anchor_local.dot(local_axis)
			var replacement := negative_piece if side_coordinate < 0.0 else positive_piece
			joint.set(endpoint_key, joint.get_path_to(replacement))
			remapped_count += 1
	return remapped_count


func _collect_joints(node: Node, joints: Array[Joint2D]) -> void:
	if node is Joint2D:
		joints.append(node as Joint2D)
	for child in node.get_children():
		_collect_joints(child, joints)


func _rectangle_inertia(mass: float, size: Vector2) -> float:
	return mass * (size.x * size.x + size.y * size.y) / 12.0


func _rotational_velocity(offset: Vector2, angular_velocity: float) -> Vector2:
	return Vector2(-offset.y, offset.x) * angular_velocity


func _angular_momentum_about_source(piece: RigidBody2D, source_position: Vector2, piece_inertia: float) -> float:
	var offset := piece.global_position - source_position
	var orbital_momentum := offset.x * piece.linear_velocity.y * piece.mass - offset.y * piece.linear_velocity.x * piece.mass
	return piece_inertia * piece.angular_velocity + orbital_momentum
