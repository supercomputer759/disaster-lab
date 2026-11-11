extends Node2D

const MARKER_COLOR := Color(1.0, 0.22, 0.12, 0.95)
const MARKER_RADIUS := 11.0


func _ready() -> void:
	z_index = 100
	queue_redraw()
	var timer := get_tree().create_timer(2.5)
	timer.timeout.connect(queue_free)


func _draw() -> void:
	draw_circle(Vector2.ZERO, MARKER_RADIUS, MARKER_COLOR)
	draw_arc(Vector2.ZERO, MARKER_RADIUS + 5.0, 0.0, TAU, 32, Color.WHITE, 2.0)
	draw_line(Vector2(-5.0, -5.0), Vector2(5.0, 5.0), Color.WHITE, 2.5)
	draw_line(Vector2(-5.0, 5.0), Vector2(5.0, -5.0), Color.WHITE, 2.5)
