# 재난 시나리오 매니저

`DisasterScenarioManager`는 SI 단위 입력을 가진 재난 이벤트 시간표와 실행 기록을 관리하는 독립 모듈이다. Godot의 `RigidBody2D` 물리와 개별 재난 모델을 대체하지 않는다.

## 이벤트 구성

`configure_scenario(name, events, settings, kind)`에 이벤트 `Dictionary` 배열을 전달한다. 이벤트는 고유 `id`, `type`, `start_time_s`, `duration_s`를 가져야 한다. `intensity`는 재난 모델별 입력 `Dictionary`이며 값은 호출하는 모델이 정의한다. 선택 입력 `order`는 동일 시각 이벤트의 시작 순서를 정한다.

지원 타입은 `earthquake`, `typhoon`, `flood`, `fire`다. 시작 시각은 0 이상, 지속시간은 양수여야 한다. 강도 및 시뮬레이션 시간 간격은 유한한 값이어야 한다. 기본 설정은 120Hz, 1/120초 간격, 난수 시드 1, SI 단위다. 실행 때 엔진 프로젝트 설정이 저장 설정과 같은지 검증하는 역할은 시뮬레이션을 구동하는 쪽에 있다.

`kind="auto"`이면 이벤트 1개는 `single`, 같은 시각에 시작하는 여러 이벤트는 `simultaneous`, 같은 유형의 서로 다른 시각 이벤트는 `sequential`, 여러 유형이 서로 다른 시각에 나타나면 `composite`로 분류한다. 분류는 보고용 메타데이터이며 이벤트 동작에는 영향을 주지 않는다.

## 시간 제어와 연결

- `start()`는 0초 이벤트를 시작하고 시간표를 초기화한다.
- 매 물리 시간 단계에서 `advance(delta_s)`를 호출한다. 시작/종료 경계의 이벤트는 경계 시각과 `order` 순으로 처리한다.
- `event_started`, `event_ended`, `timeline_advanced` 신호 또는 `get_active_inputs_by_type()`을 이용해 각 재난 모델에 입력을 전달한다.
- `pause()`, `resume()`, `replay()`는 스케줄러 상태를 제어한다. `replay()`는 이벤트 시간표와 로그를 초기화한다.
- `record_results(metrics)`에는 실제 계산한 수치 지표만 전달한다. 입력 추정치나 미계산 물리량을 결과처럼 전달하면 안 된다.

이 모듈은 현재 메인 대시보드나 `EarthquakeController`, `WindLoadModel`, `FluidFloodModel`, `ThermalFireModel`을 자동으로 구동하지 않는다. 호출자가 시간 진행 및 활성 이벤트를 각 모델에 연결해야 한다. 따라서 테스트는 시간표/저장/재생 일관성을 검증하며 재난 하중의 실제 강체 적용이나 동적 구조 응답까지 검증하지 않는다.

## 저장, 재생, 비교

시나리오 입력은 `save_scenario(key)` / `load_scenario(key)`로, 입력과 시뮬레이션 설정·이벤트 로그·결과 표본을 포함한 실행 기록은 `save_run(key)` / `load_run(key)`로 저장한다. 파일은 `user://disaster_scenarios/` 아래 JSON으로 저장되며 파일 키는 영문, 숫자, 밑줄, 하이픈만 허용한다. 입력 해시를 재계산해 저장 입력의 변조/불일치를 확인한다.

`replay_run(run)`은 저장된 입력과 설정으로 이벤트 시간표를 다시 시작한다. 실행 기록의 결과 표본은 과거 실행 증거로 유지되고 새 동적 계산은 호출자가 같은 물리 설정으로 다시 수행해야 한다. Godot Physics의 완전한 비트 단위 재현성을 보장하지 않는다. `compare_runs(a, b)`는 공통 결과 지표에 대해 최종값과 표본 기준 최대 절대값 차이를 계산한다.

## 검증

`scenes/tests/disaster_scenario_validation.tscn`은 단일 지진, 순차 이벤트, 복수 재난 동시 발생, 복합 재난, 일시정지, 결과 저장/불러오기, 입력 해시, 시간표 리플레이 및 실험 비교를 검증한다. 출력 태그는 `[DISASTER_SCENARIO_TEST]`다.
