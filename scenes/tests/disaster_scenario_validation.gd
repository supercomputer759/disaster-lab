extends Node2D

const MANAGER = preload("res://scripts/structure/disaster_scenario_manager.gd")

@export var test_summary: String = "대기"
var _checks := 0
var _failures: Array[String] = []


func _ready() -> void:
	_test_single_disaster()
	_test_sequential_events()
	_test_simultaneous_events()
	_test_composite_and_replay()
	_test_save_load_compare()
	test_summary = "%s · checks=%d · failures=%d" % ["PASS" if _failures.is_empty() else "FAIL", _checks, _failures.size()]
	print("[DISASTER_SCENARIO_TEST] %s" % test_summary)
	for failure in _failures:
		push_error("[DISASTER_SCENARIO_TEST] %s" % failure)


func _test_single_disaster() -> void:
	var manager = MANAGER.new()
	var configured: Dictionary = manager.configure_scenario("단일 지진", [_event("quake", "earthquake", 0.5, 1.0, {"pga_g":0.2})], {"random_seed":17})
	_expect(bool(configured["valid"]) and manager.scenario_kind == "single", "단일 재난 입력과 종류 설정")
	_expect(bool(manager.start()["valid"]) and manager.get_active_events().is_empty(), "미래 시작 이벤트는 시작 전 비활성")
	manager.advance(0.49)
	_expect(manager.get_active_events().is_empty(), "시작 시각 직전 비활성")
	var started: Dictionary = manager.advance(0.02)
	_expect(started["started_events"].size() == 1 and manager.get_active_events()[0]["type"] == "earthquake", "지진 입력이 예약 시각에 활성화")
	_expect(manager.get_active_inputs_by_type().has("earthquake"), "재난 유형별 활성 입력 조회")
	var paused_at: float = manager.current_time_s
	manager.pause()
	manager.advance(0.5)
	_expect(is_equal_approx(manager.current_time_s, paused_at), "일시정지 중 시나리오 시간 고정")
	manager.resume()
	manager.advance(0.99)
	_expect(manager.get_active_events().is_empty() and manager.get_event_timeline()[0]["state"] == "completed", "지속시간 종료 후 이벤트 종료 및 타임라인 반영")
	_expect(bool(manager.record_results({"roof_displacement_m":0.03})["valid"]), "시뮬레이션 결과 표본 기록")


func _test_sequential_events() -> void:
	var manager = MANAGER.new()
	var events := [_event("wind_1", "typhoon", 0.0, 1.0, {"wind_speed_m_s":30.0}), _event("wind_2", "typhoon", 1.5, 2.0, {"wind_speed_m_s":35.0})]
	var configured: Dictionary = manager.configure_scenario("순차 재난", events)
	manager.start()
	manager.advance(1.0)
	_expect(bool(configured["valid"]) and manager.scenario_kind == "sequential", "순차 재난 종류 판정")
	_expect(manager.get_active_events().is_empty(), "첫 이벤트 종료 후 다음 이벤트 전 간격")
	manager.advance(0.5)
	_expect(manager.get_active_inputs_by_type().has("typhoon"), "순차 두 번째 태풍 입력 시작 시점 활성화")
	manager.advance(2.0)
	var timeline: Array[Dictionary] = manager.get_event_timeline()
	_expect(timeline[0]["state"] == "completed" and timeline[1]["state"] == "completed", "순차 재난 완료 상태 기록")
	var log: Array = manager.run_record()["event_log"]
	_expect(log.size() == 4 and log[0]["event_id"] == "wind_1" and log[3]["event_id"] == "wind_2", "시간순 시작/종료 이벤트 로그")


func _test_simultaneous_events() -> void:
	var manager = MANAGER.new()
	var events := [_event("quake", "earthquake", 2.0, 4.0, {"pga_g":0.4}), _event("fire", "fire", 2.0, 3.0, {"gas_temperature_c":600.0}), _event("surge", "flood", 2.0, 5.0, {"water_level_m":1.5})]
	var configured: Dictionary = manager.configure_scenario("동시 재난", events)
	manager.start()
	manager.advance(2.0)
	var grouped: Dictionary = manager.get_active_inputs_by_type()
	_expect(bool(configured["valid"]) and manager.scenario_kind == "simultaneous", "동시 재난 종류 판정")
	_expect(grouped.size() == 3 and manager.get_active_events().size() == 3, "세 재난의 동시 활성화")
	manager.advance(3.0)
	grouped = manager.get_active_inputs_by_type()
	_expect(not grouped.has("fire") and grouped.has("earthquake") and grouped.has("flood"), "동시 이벤트별 지속시간 독립 처리")


func _test_composite_and_replay() -> void:
	var manager = MANAGER.new()
	var events := [
		_event("quake", "earthquake", 0.0, 1.0, {"pga_g":0.7}),
		_event("wind", "typhoon", 0.0, 2.0, {"wind_speed_m_s":40.0}),
		_event("fire", "fire", 1.0, 1.0, {"gas_temperature_c":700.0}),
		_event("flood", "flood", 2.0, 2.0, {"water_level_m":3.0})
	]
	var configured: Dictionary = manager.configure_scenario("복합재난", events, {"time_step_s":1.0/120.0,"physics_ticks_per_second":120,"random_seed":2026})
	manager.start()
	manager.advance(4.0)
	var first_log: Array = manager.run_record()["event_log"]
	var replayed: Dictionary = manager.replay()
	manager.advance(4.0)
	_expect(bool(configured["valid"]) and manager.scenario_kind == "composite", "복수 재난 유형을 복합 시나리오로 분류")
	_expect(bool(replayed["valid"]) and first_log == manager.run_record()["event_log"], "리플레이 입력과 시간순 이벤트 로그 재현")
	_expect(manager.run_record()["scenario_complete"] and manager.get_active_events().is_empty(), "전체 복합 시나리오 완료")


func _test_save_load_compare() -> void:
	var manager = MANAGER.new()
	var config: Dictionary = manager.configure_scenario("저장 재현", [_event("quake", "earthquake", 0.0, 1.0, {"pga_g":0.1})], {"random_seed":77})
	manager.start()
	manager.advance(0.5)
	manager.record_results({"roof_displacement_m":0.01,"base_acceleration_m_s2":0.2})
	manager.advance(0.5)
	manager.record_results({"roof_displacement_m":0.04,"base_acceleration_m_s2":0.4})
	var saved_scenario: Dictionary = manager.save_scenario("task14_validation")
	var saved_run: Dictionary = manager.save_run("task14_validation")
	var loaded_manager = MANAGER.new()
	var loaded_scenario: Dictionary = loaded_manager.load_scenario("task14_validation")
	var loaded_run: Dictionary = loaded_manager.load_run("task14_validation")
	_expect(bool(config["valid"]) and bool(saved_scenario["valid"]) and bool(saved_run["valid"]), "입력 설정과 실험 기록을 user://에 저장")
	_expect(bool(loaded_scenario["valid"]) and loaded_manager.input_hash == manager.input_hash, "시나리오 불러오기 및 입력 해시 검증")
	_expect(bool(loaded_run["valid"]) and loaded_run["run"]["result_samples"].size() == 2, "결과 표본·이벤트 로그가 포함된 실험 기록 불러오기")
	var replay_result: Dictionary = loaded_manager.replay_run(loaded_run["run"])
	_expect(bool(replay_result["valid"]) and loaded_manager.input_hash == manager.input_hash, "저장 실험에서 동일 입력 재생")
	var other_run: Dictionary = loaded_run["run"].duplicate(true)
	other_run["result_samples"][1]["metrics"]["roof_displacement_m"] = 0.06
	var comparison: Dictionary = MANAGER.compare_runs(loaded_run["run"], other_run)
	_expect(bool(comparison["valid"]) and is_equal_approx(float(comparison["compared_metrics"]["roof_displacement_m"]["final_delta_b_minus_a"]), 0.02), "두 실험 결과의 최종/최대 절대값 비교")
	_expect(not manager.configure_scenario("잘못된 강도", [_event("bad", "earthquake", 0.0, 1.0, {"pga_g":INF})])["valid"], "비유한 재난 강도 입력 거부")
	_expect(not manager.configure_scenario("잘못된 시간 간격", [_event("valid", "earthquake", 0.0, 1.0, {})], {"time_step_s":INF})["valid"], "비유한 물리 시간 간격 입력 거부")


func _event(event_id: String, event_type: String, start_s: float, duration_s: float, intensity: Dictionary) -> Dictionary:
	return {"id":event_id,"type":event_type,"start_time_s":start_s,"duration_s":duration_s,"intensity":intensity}


func _expect(condition: bool, description: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(description)
