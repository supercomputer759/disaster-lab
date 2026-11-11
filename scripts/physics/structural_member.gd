extends RigidBody2D
class_name StructuralMember

var member_id: String = ""
var member_kind: String = "member"
var section_area_m2: float = 0.0
var material_density_kg_m3: float = 7850.0
var member_length_m: float = 0.0
var disconnected: bool = false

var _visual: Polygon2D
var _base_color: Color = Color("#78a9cf")


func configure(
	p_id: String,
	p_kind: String,
	p_length_px: float,
	p_width_px: float,
	p_section_area_m2: float,
	p_density_kg_m3: float
) -> void:
	member_id = p_id
	member_kind = p_kind
	section_area_m2 = p_section_area_m2
	material_density_kg_m3 = p_density_kg_m3
	member_length_m = p_length_px / 30.0
	mass = maxf(0.5, material_density_kg_m3 * section_area_m2 * member_length_m)
	gravity_scale = 1.0
	freeze_mode = RigidBody2D.FREEZE_MODE_KINEMATIC
	freeze = true
	linear_damp = 0.08
	angular_damp = 0.12
	collision_layer = 2
	collision_mask = 5
	input_pickable = true
	add_to_group("structural_members")

	var material := PhysicsMaterial.new()
	material.friction = 0.72
	material.bounce = 0.025
	physics_material_override = material

	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(p_width_px, p_length_px)
	collision.shape = rectangle
	add_child(collision)

	_visual = Polygon2D.new()
	_visual.name = "Visual"
	var half_width := p_width_px * 0.5
	var half_length := p_length_px * 0.5
	_visual.polygon = PackedVector2Array([
		Vector2(-half_width, -half_length),
		Vector2(half_width, -half_length),
		Vector2(half_width, half_length),
		Vector2(-half_width, half_length)
	])
	_base_color = _color_for_kind(member_kind)
	_visual.color = _base_color
	_visual.z_index = 2
	add_child(_visual)


func set_selected(selected: bool) -> void:
	if not is_instance_valid(_visual):
		return
	if disconnected:
		_visual.color = Color("#dc5968")
	else:
		_visual.color = Color("#ffd166") if selected else _base_color


func mark_disconnected() -> void:
	disconnected = true
	collision_layer = 4
	collision_mask = 7
	if is_instance_valid(_visual):
		_visual.color = Color("#dc5968")


func physical_mass_kg() -> float:
	return mass


func _color_for_kind(kind: String) -> Color:
	match kind:
		"column":
			return Color("#7db4d8")
		"beam":
			return Color("#91c7dc")
		"brace":
			return Color("#e0a84f")
		_:
			return Color("#9ab4c7")
