extends RefCounted
class_name DisasterScenarioManager

## 재난 입력을 시간표로 관리한다. 해석/물리 모듈은 신호와 활성 입력을 받아 구동한다.
signal scenario_started(scenario_name: String, input_hash: String)
signal event_started(event: Dictionary)
signal event_ended(event: Dictionary)
signal timeline_advanced(time_s: float, active_events: Array)

const SCHEMA_VERSION: int = 1
const SAVE_DIRECTORY: String = "user://disaster_scenarios"
const SUPPORTED_EVENT_TYPES: Array[String] = ["earthquake", "typhoon", "flood", "fire"]
const BOUNDARY_EPSILON: float = 1.0e-9

var scenario_name: String = ""
var scenario_kind: String = "single"
var simulation_settings: Dictionary = {}
var events: Array[Dictionary] = []
var current_time_s: float = 0.0
var is_running: bool = false
var is_paused: bool = false
var input_hash: String = ""

var _active_event_ids: Dictionary = {}
var _event_log: Array[Dictionary] = []
var _result_samples: Array[Dictionary] = []


func configure_scenario(
	name: String,
	event_specs: Array,
	settings: Dictionary = {},
	kind: String = "auto"
) -> Dictionary:
	if name.strip_edges().is_empty() or event_specs.is_empty():
		return _error("시나리오 이름과 재난 이벤트 한 개 이상이 필요해.")
	var validated: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	for index in range(event_specs.size()):
		var source: Variant = event_specs[index]
		if not source is Dictionary:
			return _error("이벤트 %d는 Dictionary여야 해." % index)
		for required in ["id", "type", "start_time_s", "duration_s"]:
			if not source.has(required):
				return _error("이벤트 %d에 %s 값이 없어." % [index, required])
		var event_id := str(source["id"]).strip_edges()
		var event_type := str(source["type"])
		var start_time := float(source["start_time_s"])
		var duration := float(source["duration_s"])
		if event_id.is_empty() or seen_ids.has(event_id):
			return _error("이벤트 ID가 비었거나 중복돼: %s" % event_id)
		if not SUPPORTED_EVENT_TYPES.has(event_type):
			return _error("지원하지 않는 재난 유형이야: %s" % event_type)
		if not is_finite(start_time) or not is_finite(duration) or start_time < 0.0 or duration <= 0.0:
			return _error("이벤트 시작시각은 0 이상, 지속시간은 양수인 유한 초 값이어야 해.")
		var intensity: Variant = source.get("intensity", {})
		if not intensity is Dictionary:
			return _error("이벤트 intensity는 입력값 Dictionary여야 해.")
		for intensity_key in intensity:
			var value: Variant = intensity[intensity_key]
			if value is float or value is int:
				if not is_finite(float(value)):
					return _error("이벤트 %s의 강도 %s가 유한하지 않아." % [event_id, str(intensity_key)])
		var event: Dictionary = source.duplicate(true)
		event["id"] = event_id
		event["type"] = event_type
		event["start_time_s"] = start_time
		event["duration_s"] = duration
		event["end_time_s"] = start_time + duration
		event["order"] = int(source.get("order", index))
		event["intensity"] = intensity.duplicate(true)
		validated.append(event)
		seen_ids[event_id] = true
	validated.sort_custom(_event_less)
	var resolved_settings := settings.duplicate(true)
	resolved_settings["time_step_s"] = float(settings.get("time_step_s", 1.0 / 120.0))
	resolved_settings["physics_ticks_per_second"] = int(settings.get("physics_ticks_per_second", 120))
	resolved_settings["random_seed"] = int(settings.get("random_seed", 1))
	resolved_settings["unit_system"] = str(settings.get("unit_system", "SI"))
	if not is_finite(float(resolved_settings["time_step_s"])) or resolved_settings["time_step_s"] <= 0.0 or resolved_settings["physics_ticks_per_second"] <= 0 or resolved_settings["unit_system"] != "SI":
		return _error("시뮬레이션 설정은 양수 시간 간격/틱 빈도와 SI 단위를 사용해야 해.")
	var resolved_kind := _resolve_kind(validated, kind)
	if resolved_kind.is_empty():
		return _error("scenario kind는 auto, single, sequential, simultaneous, composite 중 하나여야 해.")
	scenario_name = name.strip_edges()
	scenario_kind = resolved_kind
	simulation_settings = resolved_settings
	events = validated
	input_hash = _calculate_input_hash()
	current_time_s = 0.0
	is_running = false
	is_paused = false
	_active_event_ids.clear()
	_event_log.clear()
	_result_samples.clear()
	return {"valid": true, "scenario_name": scenario_name, "scenario_kind": scenario_kind, "event_count": events.size(), "input_hash": input_hash, "simulation_settings": simulation_settings.duplicate(true)}


func start() -> Dictionary:
	if events.is_empty():
		return _error("먼저 유효한 시나리오를 구성해야 해.")
	current_time_s = 0.0
	is_running = true
	is_paused = false
	_active_event_ids.clear()
	_event_log.clear()
	_result_samples.clear()
	scenario_started.emit(scenario_name, input_hash)
	var started: Array[Dictionary] = []
	for event in events:
		if float(event["start_time_s"]) <= BOUNDARY_EPSILON:
			_begin_event(event, 0.0)
			started.append(event.duplicate(true))
	return {"valid": true, "time_s": current_time_s, "started_events": started, "active_events": get_active_events()}


func pause() -> Dictionary:
	if not is_running:
		return _error("실행 중인 시나리오가 없어.")
	is_paused = true
	return {"valid": true, "paused": true, "time_s": current_time_s}


func resume() -> Dictionary:
	if not is_running:
		return _error("실행 중인 시나리오가 없어.")
	is_paused = false
	return {"valid": true, "paused": false, "time_s": current_time_s}


func advance(delta_s: float) -> Dictionary:
	if not is_running:
		return _error("시나리오를 먼저 시작해야 해.")
	if not is_finite(delta_s) or delta_s <= 0.0:
		return _error("시뮬레이션 시간 간격은 양수여야 해.")
	if is_paused:
		return {"valid": true, "paused": true, "time_s": current_time_s, "started_events": [], "ended_events": [], "active_events": get_active_events()}
	var old_time := current_time_s
	var target_time := current_time_s + delta_s
	var boundaries: Array[Dictionary] = []
	for event in events:
		var event_start := float(event["start_time_s"])
		var event_end := float(event["end_time_s"])
		if event_start > old_time + BOUNDARY_EPSILON and event_start <= target_time + BOUNDARY_EPSILON:
			boundaries.append({"time_s":event_start,"phase":1,"event":event})
		if event_end > old_time + BOUNDARY_EPSILON and event_end <= target_time + BOUNDARY_EPSILON:
			boundaries.append({"time_s":event_end,"phase":0,"event":event})
	boundaries.sort_custom(_boundary_less)
	var started: Array[Dictionary] = []
	var ended: Array[Dictionary] = []
	for boundary in boundaries:
		var event: Dictionary = boundary["event"]
		var boundary_time := float(boundary["time_s"])
		if int(boundary["phase"]) == 0:
			_end_event(event, boundary_time)
			ended.append(event.duplicate(true))
		else:
			_begin_event(event, boundary_time)
			started.append(event.duplicate(true))
	current_time_s = target_time
	var active := get_active_events()
	timeline_advanced.emit(current_time_s, active)
	return {"valid": true, "time_s": current_time_s, "started_events": started, "ended_events": ended, "active_events": active, "scenario_complete": _is_complete()}


func replay() -> Dictionary:
	return start()


func get_active_events() -> Array[Dictionary]:
	var active: Array[Dictionary] = []
	for event in events:
		if _active_event_ids.has(str(event["id"])):
			active.append(event.duplicate(true))
	return active


func get_active_inputs_by_type() -> Dictionary:
	var grouped: Dictionary = {}
	for event in get_active_events():
		var event_type := str(event["type"])
		if not grouped.has(event_type):
			grouped[event_type] = []
		grouped[event_type].append(event)
	return grouped


func get_event_timeline() -> Array[Dictionary]:
	var timeline: Array[Dictionary] = []
	for event in events:
		var event_id := str(event["id"])
		var state := "scheduled"
		if _active_event_ids.has(event_id):
			state = "active"
		elif current_time_s >= float(event["end_time_s"]):
			state = "completed"
		timeline.append({
			"id":event_id,"type":event["type"],"start_time_s":event["start_time_s"],
			"end_time_s":event["end_time_s"],"state":state,"order":event["order"]
		})
	return timeline


func record_results(metrics: Dictionary) -> Dictionary:
	if not is_running:
		return _error("실험 결과는 실행 중인 시나리오에 기록해야 해.")
	var numeric_metrics: Dictionary = {}
	for metric_name in metrics:
		var value: Variant = metrics[metric_name]
		if not (value is int or value is float) or not is_finite(float(value)):
			return _error("결과 지표 %s는 유한한 숫자여야 해." % str(metric_name))
		numeric_metrics[str(metric_name)] = float(value)
	_result_samples.append({"time_s":current_time_s,"metrics":numeric_metrics})
	return {"valid": true, "sample_index":_result_samples.size()-1,"time_s":current_time_s}


func scenario_record() -> Dictionary:
	return {
		"schema_version":SCHEMA_VERSION,"scenario_name":scenario_name,"scenario_kind":scenario_kind,
		"input_hash":input_hash,"simulation_settings":simulation_settings.duplicate(true),"events":events.duplicate(true)
	}


func run_record() -> Dictionary:
	return {
		"schema_version":SCHEMA_VERSION,"scenario":scenario_record(),"current_time_s":current_time_s,
		"event_log":_event_log.duplicate(true),"result_samples":_result_samples.duplicate(true),
		"scenario_complete":_is_complete(),"replayable":true
	}


func save_scenario(file_key: String) -> Dictionary:
	var path_result := _save_json(file_key, "scenario", scenario_record())
	return path_result


func load_scenario(file_key: String) -> Dictionary:
	var loaded := _read_json(file_key, "scenario")
	if not bool(loaded.get("valid", false)):
		return loaded
	var record: Dictionary = loaded["data"]
	if int(record.get("schema_version", -1)) != SCHEMA_VERSION:
		return _error("지원하지 않는 시나리오 파일 버전이야.")
	var configured := configure_scenario(
		str(record.get("scenario_name", "")),record.get("events", []),
		record.get("simulation_settings", {}),str(record.get("scenario_kind", "auto"))
	)
	if bool(configured.get("valid", false)) and str(record.get("input_hash", "")) != input_hash:
		return _error("저장 시나리오의 입력 해시가 재계산 결과와 일치하지 않아.")
	return configured


func save_run(file_key: String) -> Dictionary:
	return _save_json(file_key, "run", run_record())


func load_run(file_key: String) -> Dictionary:
	var loaded := _read_json(file_key, "run")
	if not bool(loaded.get("valid", false)):
		return loaded
	var run: Dictionary = loaded["data"]
	if int(run.get("schema_version", -1)) != SCHEMA_VERSION or not run.get("scenario", {}) is Dictionary:
		return _error("실험 결과 파일 버전/시나리오 입력이 유효하지 않아.")
	return {"valid":true,"run":run}


func replay_run(run: Dictionary) -> Dictionary:
	if not run.has("scenario") or not run["scenario"] is Dictionary:
		return _error("재생할 실험 기록에 scenario 입력이 없어.")
	var record: Dictionary = run["scenario"]
	var loaded := configure_scenario(str(record.get("scenario_name","")),record.get("events",[]),record.get("simulation_settings",{}),str(record.get("scenario_kind","auto")))
	if not bool(loaded.get("valid",false)):
		return loaded
	if str(record.get("input_hash","")) != input_hash:
		return _error("재생 시나리오 입력 해시가 저장값과 달라.")
	return start()


static func compare_runs(run_a: Dictionary, run_b: Dictionary) -> Dictionary:
	var samples_a: Variant = run_a.get("result_samples", [])
	var samples_b: Variant = run_b.get("result_samples", [])
	if not samples_a is Array or not samples_b is Array or samples_a.is_empty() or samples_b.is_empty():
		return {"valid":false,"error":"비교하려면 양쪽 실험에 결과 표본이 필요해."}
	var metrics_a := _summarize_metrics(samples_a)
	var metrics_b := _summarize_metrics(samples_b)
	var comparisons: Dictionary = {}
	for metric_name in metrics_a:
		if not metrics_b.has(metric_name):
			continue
		var a: Dictionary = metrics_a[metric_name]
		var b: Dictionary = metrics_b[metric_name]
		comparisons[metric_name] = {
			"run_a_final":a["final"],"run_b_final":b["final"],"final_delta_b_minus_a":float(b["final"])-float(a["final"]),
			"run_a_peak_absolute":a["peak_absolute"],"run_b_peak_absolute":b["peak_absolute"],
			"peak_absolute_delta_b_minus_a":float(b["peak_absolute"])-float(a["peak_absolute"])
		}
	return {"valid":not comparisons.is_empty(),"compared_metrics":comparisons,"metric_count":comparisons.size()}


static func _summarize_metrics(samples: Array) -> Dictionary:
	var result: Dictionary = {}
	for sample in samples:
		if not sample is Dictionary or not sample.get("metrics", {}) is Dictionary:
			continue
		var metrics: Dictionary = sample["metrics"]
		for key in metrics:
			var value := float(metrics[key])
			if not is_finite(value):
				continue
			if not result.has(str(key)):
				result[str(key)] = {"final":value,"peak_absolute":absf(value)}
			else:
				result[str(key)]["final"] = value
				result[str(key)]["peak_absolute"] = maxf(float(result[str(key)]["peak_absolute"]),absf(value))
	return result


func _begin_event(event: Dictionary, time_s: float) -> void:
	var event_id := str(event["id"])
	if _active_event_ids.has(event_id):
		return
	_active_event_ids[event_id] = true
	_event_log.append({"time_s":time_s,"action":"started","event_id":event_id,"type":event["type"],"order":event["order"]})
	event_started.emit(event.duplicate(true))


func _end_event(event: Dictionary, time_s: float) -> void:
	var event_id := str(event["id"])
	if not _active_event_ids.has(event_id):
		return
	_active_event_ids.erase(event_id)
	_event_log.append({"time_s":time_s,"action":"ended","event_id":event_id,"type":event["type"],"order":event["order"]})
	event_ended.emit(event.duplicate(true))


func _is_complete() -> bool:
	if events.is_empty():
		return false
	for event in events:
		if current_time_s < float(event["end_time_s"]) - BOUNDARY_EPSILON:
			return false
	return true


func _event_less(a: Dictionary, b: Dictionary) -> bool:
	if float(a["start_time_s"]) != float(b["start_time_s"]):
		return float(a["start_time_s"]) < float(b["start_time_s"])
	if int(a["order"]) != int(b["order"]):
		return int(a["order"]) < int(b["order"])
	return str(a["id"]) < str(b["id"])


func _boundary_less(a: Dictionary, b: Dictionary) -> bool:
	if float(a["time_s"]) != float(b["time_s"]):
		return float(a["time_s"]) < float(b["time_s"])
	if int(a["phase"]) != int(b["phase"]):
		return int(a["phase"]) < int(b["phase"])
	return _event_less(a["event"],b["event"])


func _resolve_kind(sorted_events: Array[Dictionary], requested: String) -> String:
	var allowed := ["single","sequential","simultaneous","composite"]
	if requested != "auto":
		return requested if allowed.has(requested) else ""
	if sorted_events.size() == 1:
		return "single"
	var first_time := float(sorted_events[0]["start_time_s"])
	var all_same_time := true
	var types: Dictionary = {}
	for event in sorted_events:
		types[str(event["type"])] = true
		if not is_equal_approx(float(event["start_time_s"]),first_time):
			all_same_time = false
	if all_same_time:
		return "simultaneous"
	if types.size() > 1:
		return "composite"
	return "sequential"


func _calculate_input_hash() -> String:
	var canonical := {
		"schema_version":SCHEMA_VERSION,"scenario_name":scenario_name,"scenario_kind":scenario_kind,
		"simulation_settings":simulation_settings,"events":events
	}
	return str(hash(JSON.stringify(canonical)))


func _save_json(file_key: String, kind: String, data: Dictionary) -> Dictionary:
	var validation := _validate_file_key(file_key)
	if not bool(validation["valid"]):
		return validation
	var absolute_dir := ProjectSettings.globalize_path(SAVE_DIRECTORY)
	var make_dir_error := DirAccess.make_dir_recursive_absolute(absolute_dir)
	if make_dir_error != OK:
		return _error("시나리오 저장 폴더를 만들지 못했어: %s" % error_string(make_dir_error))
	var path := "%s/%s.%s.json" % [SAVE_DIRECTORY,file_key,kind]
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file == null:
		return _error("시나리오 파일을 저장하지 못했어: %s" % error_string(FileAccess.get_open_error()))
	file.store_string(JSON.stringify(data,"\t"))
	return {"valid":true,"path":path,"input_hash":str(data.get("input_hash",data.get("scenario",{}).get("input_hash","")))}


func _read_json(file_key: String, kind: String) -> Dictionary:
	var validation := _validate_file_key(file_key)
	if not bool(validation["valid"]):
		return validation
	var path := "%s/%s.%s.json" % [SAVE_DIRECTORY,file_key,kind]
	if not FileAccess.file_exists(path):
		return _error("저장된 %s 파일이 없어: %s" % [kind,file_key])
	var file := FileAccess.open(path,FileAccess.READ)
	if file == null:
		return _error("%s 파일을 열지 못했어." % kind)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary:
		return _error("%s 파일 JSON 형식이 올바르지 않아." % kind)
	return {"valid":true,"data":parsed,"path":path}


func _validate_file_key(file_key: String) -> Dictionary:
	if file_key.is_empty():
		return _error("파일 키는 비어 있을 수 없어.")
	for index in range(file_key.length()):
		var code := file_key.unicode_at(index)
		var allowed := (code >= 48 and code <= 57) or (code >= 65 and code <= 90) or (code >= 97 and code <= 122) or code == 45 or code == 95
		if not allowed:
			return _error("파일 키에는 영문/숫자/밑줄/하이픈만 쓸 수 있어.")
	return {"valid":true}


func _error(message: String) -> Dictionary:
	return {"valid":false,"error":message}
