extends RefCounted
class_name EarthquakeController

const GRAVITY_M_S2: float = 9.80665
const PIXELS_PER_METER: float = 30.0


func apply_frame_loads(
	members: Array,
	time_s: float,
	pga_g: float,
	frequency_hz: float,
	active: bool
) -> float:
	if not active:
		return 0.0
	var rise := clampf(time_s / 0.35, 0.0, 1.0)
	var ground_acceleration_g := pga_g * rise * sin(TAU * frequency_hz * time_s)
	var acceleration_px_s2 := -ground_acceleration_g * GRAVITY_M_S2 * PIXELS_PER_METER
	for member in members:
		if not is_instance_valid(member) or member.freeze:
			continue
		member.apply_central_force(Vector2(acceleration_px_s2 * member.mass, 0.0))
	return acceleration_px_s2
