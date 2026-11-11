# DISASTER LAB 검증 씬

## 실행 방법

Godot 4.7.1에서 `scenes/tests`의 검증 씬을 열고 실행한다. MCP에서는 다음처럼 실행할 수 있다.

```text
game_start(scene_path="res://scenes/tests/frame_solver_validation.tscn")
```

비동기 물리 검증은 결과 태그가 게임 로그에 출력될 때까지 기다린 다음 확인한다. 태그의 `PASS`와 실패 수를 함께 읽는다. 스크립트 구문 검사는 MCP의 `script_check`로 수행한다.

## 검증 씬 목록

| 씬 | 범위 | 결과 태그 |
|---|---|---|
| `frame_solver_validation.tscn` | 단순보·외팔보·축하중 기둥·2D 프레임 이론해, 특이행렬 오류 | `[FRAME_SOLVER_TEST]` |
| `connection_behavior_validation.tscn` | 힌지 회전 허용, 강접합 회전 억제, 연결 유형 저장 | `[CONNECTION_VALIDATION_RESULT]` |
| `breakable_connection_validation.tscn` | 인장·압축·전단·모멘트 강도, 약/강 접합 비교, Joint 해제와 낙하 | `[TASK05_TEST_RESULT]` |
| `central_member_fracture_validation.tscn` | 정지·이동·회전 중앙 파단, 운동량, Joint 재매핑, 바닥 충돌 | `[TASK06_TEST_RESULT]` |
| `material_system_validation.tscn` | 프리셋·사용자 재료·질량·재료별 솔버 응답 | `[MATERIAL_TEST]` |
| `failure_mechanics_validation.tscn` | Euler 좌굴, Miner 누적, 균열 위치, 정적 하중 재분배/연쇄 제거 | `[FAILURE_MECHANICS_TEST]` |

기본 게임 씬의 5층 통합 지진 검증은 `/root/DisasterLab` 노드에서 다음 메서드를 호출하고, `validation_result_status`와 `user://earthquake_validation.csv`를 확인한다.

```gdscript
start_validation_case("test name", 0.05, 0.5, true, 10.0)
```

이 검증은 강체 좌표가 유한한지 검사한다. 상태가 `물리 비정상값`이면 저장된 0 변위/가속도/층간변위는 측정 성공이 아니라 유효 샘플 없음으로 기록한다.

## 해석 범위

전용 검증 씬 통과는 해당 계산/모듈의 결과만 검증한다. 기본 5층 구조에서의 동적 통합, 응력 기반 파괴, 실제 연쇄 붕괴, 반복 지진 재현성을 자동으로 보증하지 않는다. 통합 결과와 현재 실패 원인은 프로젝트 루트의 `TASK10_REGRESSION_REPORT.md`에 기록한다.
