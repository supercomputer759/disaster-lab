extends CanvasLayer
class_name DisasterDashboard

signal pause_requested
signal reset_requested
signal quake_toggled(active: bool)
signal settings_changed(floors: int, density_kg_m3: float, braces_enabled: bool)
signal disconnect_requested
signal pga_changed(value: float)
signal frequency_changed(value: float)

const PANEL_WIDTH: float = 326.0

var floor_spin: SpinBox
var material_option: OptionButton
var braces_toggle: CheckButton
var pga_slider: HSlider
var pga_value_label: Label
var frequency_slider: HSlider
var frequency_value_label: Label
var pause_button: Button
var quake_button: Button
var disconnect_button: Button
var selection_label: Label
var status_label: Label
var event_log: RichTextLabel
var _settings_note: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()


func density_kg_m3() -> float:
	return 7850.0 if material_option.selected == 0 else 2700.0


func floor_count() -> int:
	return int(floor_spin.value)


func braces_enabled() -> bool:
	return braces_toggle.button_pressed


func set_pause_label(paused: bool) -> void:
	pause_button.text = "계속" if paused else "일시정지"


func set_quake_active(active: bool) -> void:
	quake_button.set_pressed_no_signal(active)
	quake_button.text = "지진 입력 중지" if active else "지진 입력 시작"


func set_selected_member(member_id: String, connection_count: int, disconnected: bool) -> void:
	if member_id.is_empty():
		selection_label.text = "선택된 부재 없음"
		disconnect_button.disabled = true
		return
	var state := "연결 해제됨 · 자유 낙하" if disconnected else "연결 %d개" % connection_count
	selection_label.text = "%s\n%s" % [member_id, state]
	disconnect_button.disabled = disconnected


func set_status(message: String) -> void:
	status_label.text = message


func update_live_state(time_s: float, acceleration_g: float, member_count: int, joint_count: int, quake_active: bool) -> void:
	var mode := "지진 입력" if quake_active else "대기"
	status_label.text = "%s  ·  부재 %d  ·  핀 연결 %d\n시간 %.2f s  ·  기초 등가 가속도 %+.2f g" % [
		mode, member_count, joint_count, time_s, acceleration_g
	]


func add_event(message: String) -> void:
	if not is_instance_valid(event_log):
		return
	var timestamp := Time.get_time_string_from_system()
	event_log.append_text("[color=#8aa0b5]%s[/color]  %s\n" % [timestamp, message])
	event_log.scroll_to_line(maxi(0, event_log.get_line_count() - 1))


func _build_ui() -> void:
	var overlay := Control.new()
	overlay.name = "DashboardOverlay"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.name = "ControlPanel"
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = 14.0
	panel.offset_top = 14.0
	panel.offset_right = PANEL_WIDTH
	panel.offset_bottom = -14.0
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color("#111a25")
	panel_style.border_color = Color("#293a4b")
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(12)
	panel_style.content_margin_left = 12.0
	panel_style.content_margin_right = 12.0
	panel_style.content_margin_top = 10.0
	panel_style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", panel_style)
	overlay.add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.name = "PanelScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)

	var content := VBoxContainer.new()
	content.name = "PanelContent"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 9)
	scroll.add_child(content)

	var title := _label("DISASTER LAB", 22, Color("#e7f0f7"))
	content.add_child(title)
	var subtitle := _label("구조 프레임 · 동역학 프로토타입", 12, Color("#8ea4b8"))
	content.add_child(subtitle)
	_add_separator(content)

	content.add_child(_section_label("설계 조건"))
	var floor_row := HBoxContainer.new()
	floor_row.add_child(_label("층수", 14, Color("#c6d4df")))
	floor_spin = SpinBox.new()
	floor_spin.min_value = 1
	floor_spin.max_value = 8
	floor_spin.step = 1
	floor_spin.value = 5
	floor_spin.custom_minimum_size.x = 112.0
	floor_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	floor_spin.value_changed.connect(_on_design_setting_changed)
	floor_row.add_child(floor_spin)
	content.add_child(floor_row)

	material_option = OptionButton.new()
	material_option.add_item("구조용 강재 · 7,850 kg/m³", 0)
	material_option.add_item("경량 합금 · 2,700 kg/m³", 1)
	material_option.select(0)
	material_option.item_selected.connect(_on_design_setting_changed)
	content.add_child(material_option)

	braces_toggle = CheckButton.new()
	braces_toggle.text = "X형 가새 적용"
	braces_toggle.button_pressed = true
	braces_toggle.toggled.connect(_on_design_setting_changed)
	content.add_child(braces_toggle)
	_settings_note = _label("설계 조건 변경 시 프레임을 다시 구성해.", 11, Color("#8195a7"))
	content.add_child(_settings_note)
	_add_separator(content)

	content.add_child(_section_label("지진 입력"))
	_add_slider_row(content, "PGA", 0.0, 1.2, 0.05, 0.40, true)
	_add_slider_row(content, "주파수", 0.5, 8.0, 0.1, 2.0, false)
	var quake_note := _label("고정 기초 기준 등가 입력: F = −m·a₍g₎\n1 m = 30 px · 중력 9.80665 m/s²", 11, Color("#8195a7"))
	content.add_child(quake_note)

	quake_button = Button.new()
	quake_button.text = "지진 입력 시작"
	quake_button.toggle_mode = true
	quake_button.custom_minimum_size.y = 38.0
	quake_button.add_theme_color_override("font_color", Color("#f3f7fb"))
	quake_button.add_theme_stylebox_override("normal", _button_style(Color("#176c87"), Color("#258eaa")))
	quake_button.add_theme_stylebox_override("hover", _button_style(Color("#2085a1"), Color("#37a4c1")))
	quake_button.toggled.connect(_on_quake_toggled)
	content.add_child(quake_button)

	_add_separator(content)
	content.add_child(_section_label("시뮬레이션"))
	status_label = _label("초기화 중…", 12, Color("#b8c9d7"))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(status_label)
	var action_row := HBoxContainer.new()
	pause_button = Button.new()
	pause_button.text = "일시정지"
	pause_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pause_button.pressed.connect(func(): pause_requested.emit())
	action_row.add_child(pause_button)
	var reset_button := Button.new()
	reset_button.text = "초기화"
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_button.pressed.connect(func(): reset_requested.emit())
	action_row.add_child(reset_button)
	content.add_child(action_row)

	_add_separator(content)
	content.add_child(_section_label("부재 선택"))
	selection_label = _label("선택된 부재 없음", 12, Color("#b8c9d7"))
	selection_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(selection_label)
	disconnect_button = Button.new()
	disconnect_button.text = "선택 부재 연결 해제"
	disconnect_button.disabled = true
	disconnect_button.pressed.connect(func(): disconnect_requested.emit())
	content.add_child(disconnect_button)

	_add_separator(content)
	content.add_child(_section_label("이벤트 로그"))
	event_log = RichTextLabel.new()
	event_log.custom_minimum_size = Vector2(0.0, 125.0)
	event_log.bbcode_enabled = true
	event_log.fit_content = false
	event_log.scroll_active = true
	event_log.add_theme_color_override("default_color", Color("#c7d4df"))
	event_log.add_theme_font_size_override("normal_font_size", 11)
	content.add_child(event_log)

	var footer := _label("응력·탄성·자동 파손 판정은 아직 계산하지 않아.", 10, Color("#718397"))
	footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(footer)


func _add_slider_row(parent: VBoxContainer, title_text: String, min_value: float, max_value: float, step_value: float, initial: float, is_pga: bool) -> void:
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var heading := HBoxContainer.new()
	heading.add_child(_label(title_text, 13, Color("#c6d4df")))
	var value_label := _label("", 12, Color("#5fd0dc"))
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(value_label)
	row.add_child(heading)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step_value
	slider.value = initial
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)
	parent.add_child(row)

	if is_pga:
		pga_slider = slider
		pga_value_label = value_label
		slider.value_changed.connect(_on_pga_changed)
		_on_pga_changed(slider.value)
	else:
		frequency_slider = slider
		frequency_value_label = value_label
		slider.value_changed.connect(_on_frequency_changed)
		_on_frequency_changed(slider.value)


func _on_design_setting_changed(_value = null) -> void:
	if is_instance_valid(floor_spin) and is_instance_valid(material_option) and is_instance_valid(braces_toggle):
		settings_changed.emit(floor_count(), density_kg_m3(), braces_enabled())


func _on_quake_toggled(active: bool) -> void:
	quake_button.text = "지진 입력 중지" if active else "지진 입력 시작"
	quake_toggled.emit(active)


func _on_pga_changed(value: float) -> void:
	if is_instance_valid(pga_value_label):
		pga_value_label.text = "%.2f g" % value
	pga_changed.emit(value)


func _on_frequency_changed(value: float) -> void:
	if is_instance_valid(frequency_value_label):
		frequency_value_label.text = "%.1f Hz" % value
	frequency_changed.emit(value)


func _add_separator(parent: VBoxContainer) -> void:
	var separator := HSeparator.new()
	separator.add_theme_color_override("separator", Color("#293a4b"))
	parent.add_child(separator)


func _section_label(text_value: String) -> Label:
	return _label(text_value, 15, Color("#e1ebf3"))


func _label(text_value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button_style(base_color: Color, border_color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = base_color
	style.border_color = border_color
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = 8.0
	style.content_margin_right = 8.0
	style.content_margin_top = 5.0
	style.content_margin_bottom = 5.0
	return style
