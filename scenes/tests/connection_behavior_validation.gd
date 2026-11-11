extends Node2D

const CONNECTION_SCRIPT = preload("res://scripts/structure/structural_connection.gd")

var test_summary := {"passed": 0, "failed": 0, "details": []}
var _hinge_body: RigidBody2D
var _rigid_body: RigidBody2D


func _ready() -> void:
	var hinge_anchor := Vector2(400.0, 180.0)
	var rigid_anchor := Vector2(700.0, 180.0)
	_hinge_body = _create_bar("HingeBar", hinge_anchor, 0.0)
	_rigid_body = _create_bar("RigidBar", rigid_anchor, 0.8)
	_create_support_and_joint("Hinge", hinge_anchor, _hinge_body, CONNECTION_SCRIPT.ConnectionKind.HINGE)
	_create_support_and_joint("Rigid", rigid_anchor, _rigid_body, CONNECTION_SCRIPT.ConnectionKind.RIGID)
	_hinge_body.angular_velocity = 2.0
	_rigid_body.angular_velocity = 2.0
	await get_tree().create_timer(3.0).timeout
	_record(_hinge_body.global_position.is_finite() and _rigid_body.global_position.is_finite(), "두 접합 강체가 유한한 위치를 유지")
	_record(absf(wrapf(_hinge_body.global_rotation, -PI, PI)) > 0.15, "힌지 접합은 상대 회전을 허용")
	_record(absf(wrapf(_rigid_body.global_rotation - 0.8, -PI, PI)) < 0.1, "강접합은 초기 상대 회전을 억제")
	var hinge_joint := get_node("HingeJoint") as StructuralConnection
	var rigid_joint := get_node("RigidJoint") as StructuralConnection
	_record(hinge_joint.connection_kind == CONNECTION_SCRIPT.ConnectionKind.HINGE, "힌지 접합 유형을 저장")
	_record(rigid_joint.connection_kind == CONNECTION_SCRIPT.ConnectionKind.RIGID, "강접합 유형을 저장")
	print("[CONNECTION_VALIDATION_RESULT] %s" % JSON.stringify(test_summary))
	get_tree().quit(0 if int(test_summary["failed"]) == 0 else 1)


func _create_bar(node_name: String, anchor: Vector2, initial_rotation: float) -> RigidBody2D:
	var body := RigidBody2D.new()
	body.name = node_name
	body.position = anchor + Vector2(0.0, 100.0)
	body.rotation = initial_rotation
	body.mass = 10.0
	body.gravity_scale = 0.0
	body.collision_layer = 2
	body.collision_mask = 0
	add_child(body)
	var shape_node := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(18.0, 200.0)
	shape_node.shape = shape
	body.add_child(shape_node)
	return body


func _create_support_and_joint(
	label: String,
	anchor: Vector2,
	body: RigidBody2D,
	kind: int
) -> void:
	var support := StaticBody2D.new()
	support.name = "%sSupport" % label
	support.position = anchor
	add_child(support)
	var joint := CONNECTION_SCRIPT.new() as StructuralConnection
	joint.name = "%sJoint" % label
	add_child(joint)
	joint.configure(support, body, anchor, kind)


func _record(condition: bool, label: String) -> void:
	if condition:
		test_summary["passed"] += 1
	else:
		test_summary["failed"] += 1
		test_summary["details"].append(label)
	print("[CONNECTION_VALIDATION_%s] %s" % ["PASS" if condition else "FAIL", label])
