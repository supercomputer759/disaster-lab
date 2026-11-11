extends Node2D

const BUILDER_SCRIPT = preload("res://scripts/structure/structure_builder.gd")
const EARTHQUAKE_SCRIPT = preload("res://scripts/physics/earthquake_controller.gd")
const DESTRUCTION_SCRIPT = preload("res://scripts/destruction/destruction_controller.gd")

@export var configured_floor_count: int = 5
@export var structural_member_count: int = 0
@export var pin_joint_count: int = 0
@export var earthquake_active: bool = false
@export var earthquake_elapsed_s: float = 0.0
@export var selected_member_id: String = ""
@export var selected_connection_count: int = 0
@export var last_acceleration_g: float = 0.0

const DEFAULT_DENSITY_KG_M3: float = 7850.0
const PX_PER_METER: float = 30.0

var _world: Node2D
var _dashboard: DisasterDashboard
var _builder: StructureBuilder
var _earthquake: EarthquakeController
var _destruction: DestructionController
var _structure: Dictionary = {}
var _members: Array[RigidBody2D] = []
var _joints: Array[PinJoint2D] = []
var _joints_by_member: Dictionary = {}
var _joint_endpoints: Dictionary = {}
var _selected_member: RigidBody2D
var _density_kg_m3: float = DEFAULT_DENSITY_KG_M3
var _braces_enabled: bool = true
var _pga_g: float = 0.40
var _frequency_hz: float = 2.0
var _paused: bool = false
var _last_acceleration_px_s2: float = 0.0


func _ready() -> void:
	_builder = BUILDER_SCRIPT.new()
	_earthquake = EARTHQUAKE_SCRIPT.new()
	_destruction = DESTRUCTION_SCRIPT.new()

	_world = Node2D.new()
	_world.name = "World"
	add_child(_world)

	_build_structure()
	_create_dashboard()
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	queue_redraw()


func _physics_process(delta: float) -> void:
	if earthquake_active:
		earthquake_elapsed_s += delta
	_last_acceleration_px_s2 = _earthquake.apply_frame_loads(
		_members, earthquake_elapsed_s, _pga_g, _frequency_hz, earthquake_active
	)
	last_acceleration_g = _last_acceleration_px_s2 / (9.80665 * PX_PER_METER)
	if is_instance_valid(_dashboard):
		_dashboard.update_live_state(
			earthquake_elapsed_s, last_acceleration_g, _members.size(), _live_joint_count(), earthquake_active
		)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_select_member_at_mouse()
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			_toggle_pause()


func _draw() -> void:
	var view_size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, view_size), Color("#0b1118"))
	var grid_color := Color(0.22, 0.31, 0.40, 0.28)
	var left_edge := 340
	for x in range(left_edge, int(view_size.x), 40):
		draw_line(Vector2(x, 0), Vector2(x, view_size.y), grid_color, 1.0)
	for y in range(0, int(view_size.y), 40):
		draw_line(Vector2(left_edge, y), Vector2(view_size.x, y), grid_color, 1.0)
	draw_line(Vector2(left_edge, view_size.y - 42.0), Vector2(view_size.x, view_size.y - 42.0), Color("#4c6175"), 1.0)


func _create_dashboard() -> void:
	var dashboard_script = load("res://scripts/ui/disaster_dashboard.gd")
	_dashboard = dashboard_script.new() as DisasterDashboard
	_dashboard.name = "Dashboard"
	add_child(_dashboard)
	_dashboard.pause_requested.connect(_toggle_pause)
	_dashboard.reset_requested.connect(_reset_simulation)
	_dashboard.quake_toggled.connect(_on_quake_toggled)
	_dashboard.settings_changed.connect(_on_settings_changed)
	_dashboard.disconnect_requested.connect(_disconnect_selected)
	_dashboard.pga_changed.connect(_on_pga_changed)
	_dashboard.frequency_changed.connect(_on_frequency_changed)
	_dashboard.set_pause_label(_paused)
	_dashboard.set_quake_active(earthquake_active)
	_dashboard.add_event("5층 철골 프레임 준비 · 응력/탄성 파손 해석은 제외")


func _build_structure() -> void:
	if is_instance_valid(_structure.get("container")):
		var old_container: Node = _structure["container"]
		_world.remove_child(old_container)
		old_container.queue_free()
	_members.clear()
	_joints.clear()
	_joints_by_member.clear()
	_joint_endpoints.clear()
	_selected_member = null
	selected_member_id = ""
	selected_connection_count = 0

	var view_size := get_viewport_rect().size
	var panel_width := 340.0
	var right_width := maxf(360.0, view_size.x - panel_width - 24.0)
	var center_x := panel_width + right_width * 0.5
	var bay_width := clampf((right_width - 72.0) * 0.5, 120.0, 180.0)
	var base_y := view_size.y - 60.0
	var story_height := clampf((view_size.y - 130.0) / float(configured_floor_count), 72.0, 90.0)
	_structure = _builder.build(
		_world, configured_floor_count, _braces_enabled, _density_kg_m3,
		center_x, base_y, bay_width, story_height
	)
	_members = _structure["members"]
	_joints = _structure["joints"]
	_joints_by_member = _structure["joints_by_member"]
	_joint_endpoints = _structure["joint_endpoints"]
	structural_member_count = _members.size()
	pin_joint_count = _live_joint_count()
	_release_members_after_physics_sync()
	queue_redraw()


func _release_members_after_physics_sync() -> void:
	await get_tree().physics_frame
	for member in _members:
		if is_instance_valid(member):
			member.freeze = false


func _select_member_at_mouse() -> void:
	var query := PhysicsPointQueryParameters2D.new()
	query.position = get_global_mouse_position()
	query.collision_mask = 2
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var hits := get_world_2d().direct_space_state.intersect_point(query, 16)
	for hit in hits:
		var candidate := hit.get("collider") as RigidBody2D
		if is_instance_valid(candidate) and candidate.is_in_group("structural_members"):
			_set_selected_member(candidate)
			return
	_set_selected_member(null)


func _set_selected_member(member: RigidBody2D) -> void:
	if is_instance_valid(_selected_member) and _selected_member.has_method("set_selected"):
		_selected_member.set_selected(false)
	_selected_member = member
	selected_member_id = ""
	selected_connection_count = 0
	if is_instance_valid(_selected_member):
		if _selected_member.has_method("set_selected"):
			_selected_member.set_selected(true)
		selected_member_id = str(_selected_member.get("member_id"))
		selected_connection_count = _joints_by_member.get(_selected_member, []).size()
	if is_instance_valid(_dashboard):
		var disconnected := is_instance_valid(_selected_member) and bool(_selected_member.get("disconnected"))
		_dashboard.set_selected_member(selected_member_id, selected_connection_count, disconnected)


func _disconnect_selected() -> void:
	if not is_instance_valid(_selected_member):
		return
	var member_id := selected_member_id
	var detached_count := _destruction.disconnect_member(_selected_member, _joints_by_member, _joint_endpoints)
	selected_connection_count = 0
	pin_joint_count = _live_joint_count()
	if is_instance_valid(_dashboard):
		_dashboard.set_selected_member(member_id, 0, true)
		_dashboard.add_event("%s 연결 %d개 해제 · 부재는 강체로 낙하/충돌" % [member_id, detached_count])
	print("[DISASTER] disconnected %s; detached_joints=%d" % [member_id, detached_count])


func _on_settings_changed(floors: int, density_kg_m3: float, braces_enabled: bool) -> void:
	configured_floor_count = clampi(floors, 1, 8)
	_density_kg_m3 = density_kg_m3
	_braces_enabled = braces_enabled
	_reset_simulation("설계 조건 변경으로 프레임 재구성")


func _on_pga_changed(value: float) -> void:
	_pga_g = clampf(value, 0.0, 1.2)


func _on_frequency_changed(value: float) -> void:
	_frequency_hz = clampf(value, 0.5, 8.0)


func _on_quake_toggled(active: bool) -> void:
	earthquake_active = active
	if active:
		earthquake_elapsed_s = 0.0
		_report_event("PGA %.2f g · 주파수 %.1f Hz 지진 입력 시작" % [_pga_g, _frequency_hz])
	else:
		_report_event("지진 입력 중지")
	if is_instance_valid(_dashboard):
		_dashboard.set_quake_active(active)


func _toggle_pause() -> void:
	_paused = not _paused
	get_tree().paused = _paused
	if is_instance_valid(_dashboard):
		_dashboard.set_pause_label(_paused)
	_report_event("물리 시뮬레이션 일시정지" if _paused else "물리 시뮬레이션 재개")


func _reset_simulation(reason: String = "사용자 초기화") -> void:
	get_tree().paused = false
	_paused = false
	earthquake_active = false
	earthquake_elapsed_s = 0.0
	last_acceleration_g = 0.0
	_last_acceleration_px_s2 = 0.0
	if is_instance_valid(_dashboard):
		_dashboard.set_pause_label(false)
		_dashboard.set_quake_active(false)
	_build_structure()
	if is_instance_valid(_dashboard):
		_dashboard.set_selected_member("", 0, false)
		_dashboard.update_live_state(0.0, 0.0, _members.size(), _live_joint_count(), false)
		_dashboard.add_event("%s · %d층 · 부재 %d · 핀 연결 %d" % [
			reason, configured_floor_count, _members.size(), _live_joint_count()
		])
	print("[DISASTER] reset floors=%d members=%d pin_joints=%d braces=%s density=%.0f kg/m3" % [
		configured_floor_count, _members.size(), _live_joint_count(), str(_braces_enabled), _density_kg_m3
	])


func _live_joint_count() -> int:
	var count := 0
	for joint in _joints:
		if is_instance_valid(joint) and not joint.is_queued_for_deletion():
			count += 1
	return count


func _report_event(message: String) -> void:
	if is_instance_valid(_dashboard):
		_dashboard.add_event(message)
	print("[DISASTER] " + message)


func _on_viewport_size_changed() -> void:
	queue_redraw()
