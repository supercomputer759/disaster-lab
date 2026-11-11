extends Node2D

const FRACTURE_COLOR := Color("#ff4268")


func _ready() -> void:
	z_index = 100
	queue_redraw()
	get_tree().create_timer(2.5).timeout.connect(queue_free)


func _draw() -> void:
	draw_circle(Vector2.ZERO, 5.0, FRACTURE_COLOR)
	draw_arc(Vector2.ZERO, 10.0, 0.0, TAU, 32, Color.WHITE, 2.0)
	draw_line(Vector2(-7.0, 0.0), Vector2(7.0, 0.0), Color.WHITE, 2.0)
	draw_line(Vector2(0.0, -7.0), Vector2(0.0, 7.0), Color.WHITE, 2.0)
