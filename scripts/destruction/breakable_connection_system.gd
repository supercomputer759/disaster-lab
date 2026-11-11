extends Node2D
class_name BreakableConnectionSystem

signal connection_failed(event: Dictionary)

const FAILURE_MARKER_SCRIPT := preload("res://scripts/destruction/connection_failure_marker.gd")

var _connections: Dictionary = {}
var _failure_log: Array[Dictionary] = []


func register_connection(
	connection_id: String,
	joint: Joint2D,
	body_a: PhysicsBody2D,
	body_b: PhysicsBody2D,
	node_a: String,
	node_b: String,
	world_position: Vector2,
	local_axis: Vector2,
	capacities: Dictionary,
	translational_stiffness_n_m: float,
	rotational_stiffness_nm_rad: float
) -> Dictionary:
	if connection_id.is_empty() or _connections.has(connection_id):
		return {"success": false, "error": "접합 ID가 비었거나 이미 등록돼."}
	if not is_instance_valid(joint) or not is_instance_valid(body_a) or not is_instance_valid(body_b):
		return {"success": false, "error": "실제 Joint와 양쪽 RigidBody2D가 필요해."}
	if node_a.is_empty() or node_b.is_empty() or node_a == node_b:
		return {"success": false, "error": "구조해석 절점 ID가 서로 달라야 해."}
	if not local_axis.is_finite() or local_axis.length_squared() <= 1.0e-12:
		return {"success": false, "error": "local_axis 방향이 유효하지 않아."}
	var normalized_capacities := {}
	for key in ["tensile_capacity_n", "compression_capacity_n", "shear_capacity_n", "moment_capacity_nm"]:
		var capacity := float(capacities.get(key, -1.0))
		if not is_finite(capacity) or capacity < 0.0:
			return {"success": false, "error": "%s는 유한한 0 이상 값이어야 해." % key}
		normalized_capacities[key] = capacity
	for value in [translational_stiffness_n_m, rotational_stiffness_nm_rad]:
		if not is_finite(value) or value < 0.0:
			return {"success": false, "error": "접합 강성은 유한한 0 이상 값이어야 해."}
	_connections[connection_id] = {
		"joint": joint,
		"body_a": body_a,
		"body_b": body_b,
		"node_a": node_a,
		"node_b": node_b,
		"world_position": world_position,
		"local_axis": local_axis.normalized(),
		"capacities": normalized_capacities,
		"translational_stiffness_n_m": translational_stiffness_n_m,
		"rotational_stiffness_nm_rad": rotational_stiffness_nm_rad,
		"failed": false
	}
	return {"success": true, "connection_id": connection_id}


func solver_inputs() -> Array[Dictionary]:
	var inputs: Array[Dictionary] = []
	for connection_id in _connections:
		var connection: Dictionary = _connections[connection_id]
		if connection["failed"]:
			continue
		inputs.append({
			"id": connection_id,
			"node_a": connection["node_a"],
			"node_b": connection["node_b"],
			"local_axis": connection["local_axis"],
			"translational_stiffness_n_m": connection["translational_stiffness_n_m"],
			"rotational_stiffness_nm_rad": connection["rotational_stiffness_nm_rad"]
		})
	return inputs


func evaluate_solver_result(solver_result: Dictionary) -> Array[Dictionary]:
	var failed_events: Array[Dictionary] = []
	if not bool(solver_result.get("valid", false)):
		return failed_events
	var connection_results: Dictionary = solver_result.get("connection_results", {})
	for connection_id in _connections.keys():
		var connection: Dictionary = _connections[connection_id]
		if connection["failed"] or not connection_results.has(connection_id):
			continue
		var demand: Dictionary = connection_results[connection_id]
		if str(demand.get("source", "")) != "linear_static_structural_solver":
			continue
		var capacities: Dictionary = connection["capacities"]
		var exceeded: Array[String] = []
		if float(demand.get("tensile_force_n", 0.0)) > capacities["tensile_capacity_n"]:
			exceeded.append("인장")
		if float(demand.get("compression_force_n", 0.0)) > capacities["compression_capacity_n"]:
			exceeded.append("압축")
		if float(demand.get("shear_force_n", 0.0)) > capacities["shear_capacity_n"]:
			exceeded.append("전단")
		if float(demand.get("moment_nm", 0.0)) > capacities["moment_capacity_nm"]:
			exceeded.append("모멘트")
		if exceeded.is_empty():
			continue
		connection["failed"] = true
		_connections[connection_id] = connection
		var joint := connection["joint"] as Joint2D
		if is_instance_valid(joint):
			joint.queue_free()
		for body_key in ["body_a", "body_b"]:
			var body := connection[body_key] as PhysicsBody2D
			if is_instance_valid(body) and body is RigidBody2D:
				var rigid_body := body as RigidBody2D
				rigid_body.sleeping = false
		var marker := FAILURE_MARKER_SCRIPT.new() as Node2D
		add_child(marker)
		marker.global_position = connection["world_position"]
		var event := {
			"connection_id": connection_id,
			"source": "linear_static_structural_solver",
			"failure_modes": exceeded,
			"solver_demands": demand.duplicate(true),
			"capacities": capacities.duplicate(true),
			"world_position": connection["world_position"]
		}
		_failure_log.append(event)
		print("[접합 파괴] %s | 모드: %s | 힘 출처: 선형 정적 구조해석" % [connection_id, ", ".join(exceeded)])
		connection_failed.emit(event)
		failed_events.append(event)
	return failed_events


func get_failure_log() -> Array[Dictionary]:
	return _failure_log.duplicate(true)


func get_connection_state(connection_id: String) -> Dictionary:
	if not _connections.has(connection_id):
		return {}
	var connection: Dictionary = _connections[connection_id]
	return {
		"failed": connection["failed"],
		"capacities": connection["capacities"].duplicate(true),
		"translational_stiffness_n_m": connection["translational_stiffness_n_m"],
		"rotational_stiffness_nm_rad": connection["rotational_stiffness_nm_rad"]
	}
