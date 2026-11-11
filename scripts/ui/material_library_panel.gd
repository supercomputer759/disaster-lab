extends VBoxContainer
class_name MaterialLibraryPanel

const MaterialDB = preload("res://scripts/structure/material_database.gd")

var material_option: OptionButton
var details: RichTextLabel
var editor_fields: Dictionary = {}
var status: Label
var assignment_button: Button
var _target_member: RigidBody2D
var _target_area_m2: float = 0.0
var _target_length_m: float = 0.0
var _materials_by_id: Dictionary = {}


func _ready() -> void:
	_build_ui()
	_refresh_materials()


func selected_material() -> Dictionary:
	var selected_id: Variant = material_option.get_item_metadata(material_option.selected)
	return (_materials_by_id.get(str(selected_id), {}) as Dictionary).duplicate(true)


func assign_selected_material(member: RigidBody2D, area_m2: float, length_m: float) -> Dictionary:
	return MaterialDB.assign_to_member(member, selected_material(), area_m2, length_m)


func set_member_target(member: RigidBody2D, area_m2: float, length_m: float) -> void:
	_target_member = member
	_target_area_m2 = area_m2
	_target_length_m = length_m
	if is_instance_valid(assignment_button):
		assignment_button.disabled = not is_instance_valid(member) or area_m2 <= 0.0 or length_m <= 0.0


func _build_ui() -> void:
	add_theme_constant_override("separation", 8)
	var title := Label.new()
	title.text = "재료 라이브러리 · SI 단위"
	title.add_theme_font_size_override("font_size", 18)
	add_child(title)
	material_option = OptionButton.new()
	material_option.item_selected.connect(_on_material_selected)
	add_child(material_option)
	assignment_button = Button.new()
	assignment_button.text = "선택 재료를 지정 부재에 적용"
	assignment_button.disabled = true
	assignment_button.pressed.connect(_assign_to_target)
	add_child(assignment_button)
	details = RichTextLabel.new()
	details.bbcode_enabled = true
	details.fit_content = true
	details.custom_minimum_size.y = 185.0
	add_child(details)
	var form_title := Label.new()
	form_title.text = "사용자 정의 재료 추가"
	form_title.add_theme_font_size_override("font_size", 15)
	add_child(form_title)
	var grid := GridContainer.new()
	grid.columns = 2
	add_child(grid)
	_add_field(grid, "ID", "id", "custom_material")
	_add_field(grid, "이름", "name", "사용자 정의")
	_add_field(grid, "밀도 (kg/m³)", "density_kg_m3", "7850")
	_add_field(grid, "영률 (Pa)", "young_modulus_pa", "200000000000")
	_add_field(grid, "포아송비 (1)", "poisson_ratio", "0.3")
	_add_field(grid, "항복강도 (Pa, 선택)", "yield_strength_pa", "250000000")
	_add_field(grid, "인장강도 (Pa)", "tensile_strength_pa", "400000000")
	_add_field(grid, "압축강도 (Pa)", "compressive_strength_pa", "250000000")
	_add_field(grid, "전단강도 (Pa)", "shear_strength_pa", "150000000")
	_add_field(grid, "파괴한계 변형률 (1)", "fracture_limit_strain", "0.2")
	_add_field(grid, "출처", "source", "사용자 입력")
	_add_field(grid, "출처 URL (선택)", "source_url", "")
	_add_field(grid, "가정", "assumptions", "사용자 제공값 · 별도 검증 필요")
	var save_button := Button.new()
	save_button.text = "사용자 재료 저장"
	save_button.pressed.connect(_save_custom_material)
	add_child(save_button)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(status)


func _add_field(parent: GridContainer, label_text: String, key: String, default_text: String) -> void:
	var label := Label.new()
	label.text = label_text
	parent.add_child(label)
	var input := LineEdit.new()
	input.text = default_text
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(input)
	editor_fields[key] = input


func _refresh_materials() -> void:
	material_option.clear()
	_materials_by_id.clear()
	var materials: Array[Dictionary] = MaterialDB.get_all_materials()
	materials.append_array(MaterialDB.load_custom_materials())
	for material in materials:
		var material_id := str(material["id"])
		_materials_by_id[material_id] = material
		material_option.add_item(str(material["name"]))
		material_option.set_item_metadata(material_option.item_count - 1, material_id)
	if material_option.item_count > 0:
		material_option.select(0)
		_show_material(0)


func _on_material_selected(index: int) -> void:
	_show_material(index)


func _show_material(index: int) -> void:
	if index < 0 or index >= material_option.item_count:
		return
	var material_id := str(material_option.get_item_metadata(index))
	var material: Dictionary = _materials_by_id[material_id]
	var yield_text := "없음 · 항복모델 미적용" if material["yield_strength_pa"] == null else "%.2f MPa" % (float(material["yield_strength_pa"]) / 1.0e6)
	details.text = "[b]%s[/b]\n밀도 %.1f kg/m³ · 영률 %.2f GPa · 포아송비 %.3f\n항복 %s · 인장 %.2f MPa · 압축 %.2f MPa · 전단 %.2f MPa\n파괴한계 변형률 %.6f (1)\n출처: %s\n가정: %s" % [
		material["name"], material["density_kg_m3"], float(material["young_modulus_pa"]) / 1.0e9,
		material["poisson_ratio"], yield_text, float(material["tensile_strength_pa"]) / 1.0e6,
		float(material["compressive_strength_pa"]) / 1.0e6, float(material["shear_strength_pa"]) / 1.0e6,
		material["fracture_limit_strain"], material["source"], material["assumptions"]
	]
	if not str(material.get("source_url", "")).is_empty():
		details.append_text("\n출처 URL: %s" % str(material["source_url"]))


func _save_custom_material() -> void:
	var material: Dictionary = {}
	for key in ["id", "name", "source", "source_url", "assumptions"]:
		material[key] = (editor_fields[key] as LineEdit).text.strip_edges()
	for key in ["density_kg_m3", "young_modulus_pa", "poisson_ratio", "tensile_strength_pa", "compressive_strength_pa", "shear_strength_pa", "fracture_limit_strain"]:
		var input_text := (editor_fields[key] as LineEdit).text.strip_edges()
		if not input_text.is_valid_float():
			status.text = "%s 값을 숫자로 입력해." % key
			return
		material[key] = float(input_text)
	var yield_text := (editor_fields["yield_strength_pa"] as LineEdit).text.strip_edges()
	material["yield_strength_pa"] = null if yield_text.is_empty() or yield_text == "0" else float(yield_text)
	var result: Dictionary = MaterialDB.save_custom_material(material)
	if not bool(result.get("valid", false)):
		status.text = str(result.get("error", "저장 실패"))
		return
	_refresh_materials()
	status.text = "사용자 재료를 user://custom_materials.json에 저장했어. 물성 출처와 가정은 별도 검증이 필요해."


func _assign_to_target() -> void:
	var result := assign_selected_material(_target_member, _target_area_m2, _target_length_m)
	status.text = "%s 재료 적용 · 질량 %.3f kg" % [str(result.get("material_id", "오류")), float(result.get("mass_kg", 0.0))] if bool(result.get("valid", false)) else str(result.get("error", "재료 적용 실패"))
