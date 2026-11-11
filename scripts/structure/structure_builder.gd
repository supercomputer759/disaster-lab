extends RefCounted
class_name StructureBuilder

const MEMBER_SCRIPT = preload("res://scripts/physics/structural_member.gd")

const COLUMN_AREA_M2: float = 0.008
const BEAM_AREA_M2: float = 0.006
const BRACE_AREA_M2: float = 0.0025


func build(
	owner: Node2D,
	floor_count: int,
	bracing_enabled: bool,
	density_kg_m3: float,
	center_x: float,
	base_y: float,
	bay_width: float,
	story_height: float
) -> Dictionary:
	var container := Node2D.new()
	container.name = "Structure"
	owner.add_child(container)

	var members: Array[RigidBody2D] = []
	var braces: Array[RigidBody2D] = []
	var joints: Array[PinJoint2D] = []
	var joints_by_member: Dictionary = {}
	var joint_endpoints: Dictionary = {}
	var columns_by_story: Array = []
	var beams_by_floor: Array = []
	var levels: Array[float] = []

	for level_index in range(floor_count + 1):
		levels.append(base_y - level_index * story_height)

	var x_positions := [
		center_x - bay_width,
		center_x,
		center_x + bay_width
	]
	var ground := _create_foundation(container, center_x, base_y)
	var left_ground := Vector2(x_positions[0], base_y)
	var middle_ground := Vector2(x_positions[1], base_y)
	var right_ground := Vector2(x_positions[2], base_y)

	for story in range(floor_count):
		var row: Array[RigidBody2D] = []
		var top_y: float = levels[story + 1]
		var bottom_y: float = levels[story]
		for column_index in range(3):
			var x: float = x_positions[column_index]
			var id := "C%d-%s" % [story + 1, _column_label(column_index)]
			var column := _create_member(
				container, id, "column",
				Vector2(x, (top_y + bottom_y) * 0.5),
				Vector2(x, top_y) - Vector2(x, bottom_y),
				22.0, COLUMN_AREA_M2, density_kg_m3
			)
			row.append(column)
			members.append(column)
		columns_by_story.append(row)

		var floor_beams: Array[RigidBody2D] = []
		for bay in range(2):
			var beam := _create_member(
				container,
				"B%d-B%d" % [story + 1, bay + 1],
				"beam",
				Vector2((x_positions[bay] + x_positions[bay + 1]) * 0.5, top_y),
				Vector2(x_positions[bay + 1] - x_positions[bay], 0.0),
				16.0, BEAM_AREA_M2, density_kg_m3
			)
			floor_beams.append(beam)
			members.append(beam)
			_create_joint(
				container, beam, row[bay], Vector2(x_positions[bay], top_y),
				joints, joints_by_member, joint_endpoints
			)
			_create_joint(
				container, beam, row[bay + 1], Vector2(x_positions[bay + 1], top_y),
				joints, joints_by_member, joint_endpoints
			)
		beams_by_floor.append(floor_beams)

		if bracing_enabled:
			for bay in range(2):
				var bottom_left := Vector2(x_positions[bay], bottom_y)
				var bottom_right := Vector2(x_positions[bay + 1], bottom_y)
				var top_left := Vector2(x_positions[bay], top_y)
				var top_right := Vector2(x_positions[bay + 1], top_y)
				var left_column: RigidBody2D = row[bay]
				var right_column: RigidBody2D = row[bay + 1]
				var diagonal_a := _create_member(
					container,
					"X%d-B%d-A" % [story + 1, bay + 1],
					"brace", (bottom_left + top_right) * 0.5,
					top_right - bottom_left,
					9.0, BRACE_AREA_M2, density_kg_m3
				)
				var diagonal_b := _create_member(
					container,
					"X%d-B%d-B" % [story + 1, bay + 1],
					"brace", (bottom_right + top_left) * 0.5,
					top_left - bottom_right,
					9.0, BRACE_AREA_M2, density_kg_m3
				)
				members.append(diagonal_a)
				members.append(diagonal_b)
				braces.append(diagonal_a)
				braces.append(diagonal_b)
				_create_joint(
					container, diagonal_a, left_column, bottom_left,
					joints, joints_by_member, joint_endpoints
				)
				_create_joint(
					container, diagonal_a, right_column, top_right,
					joints, joints_by_member, joint_endpoints
				)
				_create_joint(
					container, diagonal_b, right_column, bottom_right,
					joints, joints_by_member, joint_endpoints
				)
				_create_joint(
					container, diagonal_b, left_column, top_left,
					joints, joints_by_member, joint_endpoints
				)

	for story in range(1, floor_count):
		for column_index in range(3):
			var lower: RigidBody2D = columns_by_story[story - 1][column_index]
			var upper: RigidBody2D = columns_by_story[story][column_index]
			var point := Vector2(x_positions[column_index], levels[story])
			_create_joint(
				container, lower, upper, point,
				joints, joints_by_member, joint_endpoints
			)

	var first_row: Array = columns_by_story[0]
	for column_index in range(3):
		var point := Vector2(x_positions[column_index], base_y)
		_create_joint(
			container, ground, first_row[column_index], point,
			joints, joints_by_member, joint_endpoints
		)

	return {
		"container": container,
		"ground": ground,
		"members": members,
		"braces": braces,
		"joints": joints,
		"joints_by_member": joints_by_member,
		"joint_endpoints": joint_endpoints,
		"levels": levels,
		"floor_count": floor_count
	}


func _create_foundation(parent: Node2D, center_x: float, base_y: float) -> StaticBody2D:
	var foundation := StaticBody2D.new()
	foundation.name = "Foundation"
	foundation.collision_layer = 1
	foundation.collision_mask = 0
	parent.add_child(foundation)
	foundation.position = Vector2(center_x, base_y + 18.0)

	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size = Vector2(2000.0, 36.0)
	collision.shape = shape
	foundation.add_child(collision)

	var visual := Polygon2D.new()
	visual.name = "FoundationVisual"
	visual.polygon = PackedVector2Array([
		Vector2(-1000.0, -18.0),
		Vector2(1000.0, -18.0),
		Vector2(1000.0, 18.0),
		Vector2(-1000.0, 18.0)
	])
	visual.color = Color("#536476")
	visual.z_index = 1
	foundation.add_child(visual)
	return foundation


func _create_member(
	parent: Node2D,
	id: String,
	kind: String,
	center: Vector2,
	axis: Vector2,
	width_px: float,
	area_m2: float,
	density_kg_m3: float
) -> StructuralMember:
	var member := MEMBER_SCRIPT.new() as StructuralMember
	member.name = id
	parent.add_child(member)
	var length_px := axis.length()
	member.position = center
	member.rotation = atan2(axis.y, axis.x) - PI * 0.5
	member.configure(id, kind, length_px, width_px, area_m2, density_kg_m3)
	return member


func _create_joint(
	parent: Node2D,
	body_a: Node2D,
	body_b: Node2D,
	point: Vector2,
	joints: Array[PinJoint2D],
	joints_by_member: Dictionary,
	joint_endpoints: Dictionary
) -> PinJoint2D:
	var joint := PinJoint2D.new()
	joint.name = "PinJoint_%02d" % (joints.size() + 1)
	parent.add_child(joint)
	joint.position = point
	joint.node_a = body_a.get_path()
	joint.node_b = body_b.get_path()
	joint.disable_collision = true
	joint.angular_limit_enabled = true
	joint.angular_limit_lower = -0.08
	joint.angular_limit_upper = 0.08
	joints.append(joint)
	if not joints_by_member.has(body_a):
		joints_by_member[body_a] = []
	if not joints_by_member.has(body_b):
		joints_by_member[body_b] = []
	joints_by_member[body_a].append(joint)
	joints_by_member[body_b].append(joint)
	joint_endpoints[joint] = [body_a, body_b]
	return joint


func _column_label(index: int) -> String:
	match index:
		0:
			return "L"
		1:
			return "M"
		_:
			return "R"
