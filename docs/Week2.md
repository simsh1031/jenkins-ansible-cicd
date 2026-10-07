# Week 2 — Rolling 무중단 배포 설계 및 구현 계획

이 문서는 2주 차 과제를 위한 설계다. 배포 전략은 **Rolling**으로 선택한다. 아래의 신규 앱 API, stage, 플레이북, Galaxy 모듈 활용과 정리 기능은 구현 예정이며 실행 완료 결과가 아니다. 현재 구현은 [Week1.md](Week1.md)를 참고한다.

## 1. 목표와 과제 대응

앱 서버 3대 중 한 대씩 Nginx에서 제외하고, 기존 요청 처리 완료 후 새 버전으로 교체한다. 검증에 성공한 서버만 다시 등록하고 다음 서버로 진행한다. 배포 전부터 지속적으로 HTTP 요청을 보내 성공률과 서버별 버전 전환을 기록한다.

| 과제 요구사항 | 구현 계획 | 제출할 증거 |
| --- | --- | --- |
| Rolling 전략 | 서버 한 대의 제외·교체·검증·복귀를 완료한 뒤 다음 서버 진행 | 서버별 작업 시각과 버전 변화 |
| Jenkins·Ansible | Jenkins는 전체 단계, Ansible은 서버별 순차 배포 제어 | stage 결과와 task 실행 기록 |
| Nginx 트래픽 제어 | 배포 대상 한 대를 upstream에서 제외·재등록 | 설정 변경 내역과 서버별 응답 |
| Health Check | 이미지·배포 전 서비스·배포 후 서버·LB 경유 검사 | 상태·릴리스 확인 결과 |
| 실패 시 후속 배포 중단 | 실패 서버 복구 후에도 다음 서버 진행 금지 | 장애 실험에서 미배포 서버가 유지됨 |
| Role·Handler·Variable | 앱·LB·검증·상태·정리 역할 분리 | 플레이북과 변수 구성 |
| 서비스 가용성 | 연속 요청 중 정상 응답과 버전 혼재 기록 | 요청 원본·성공률·지연·서버별 집계 |
| Galaxy 활용 | community.docker 모듈로 배포·조회·정리 | requirements와 모듈 적용 결과 |

단일 LB 자체 장애에 대한 고가용성과 데이터베이스 무중단 마이그레이션은 이번 실습 범위와 구분한다. 정상 배포의 서비스 공백 최소화와 배포 실패의 안전한 중단·복구에 집중한다.

## 2. 현재 구조와 유지할 설계

현재 앱은 컨테이너 안의 Nginx가 `/health`에 고정 `OK`, `/version`에 실행 시 주입한 값을 반환한다. 이미지 tar를 서버에 전달하고 기존 컨테이너를 삭제한 뒤 새 컨테이너를 실행한다. `serial`과 트래픽 제외가 없어 여러 서버가 비슷한 시점에 내려갈 수 있다.

유지할 고려 사항:

- Test stage는 배포 전 이미지 자체를 검사하고, app role은 실제 서버에 배포한 결과를 검사한다.
- `prepare_ssh`는 프로젝트 전용 known_hosts를 준비한다. 실제 SSH 인증 검사는 원격 실행에서 이루어진다.
- SSH 준비, 앱 배포, Nginx 제어, 검증의 역할을 명확하게 구분한다.
- 테스트한 이미지를 tar로 전달하며 원격 서버에서 다시 빌드하지 않는다.

변경점은 단순한 `serial: 1` 추가가 아니다. **서버 제외 → 요청 종료 확인 → 교체 → 직접 검사 → 재등록 → 서비스 검사** 전체를 한 서버의 배포 단위로 묶는다.

## 3. 서버와 트래픽 구조

| 항목 | 설계 |
| --- | --- |
| 앱 서버 | 기존 app1, app2, app3 |
| 앱 컨테이너 | 서버마다 `sohyeon-cicd-app` 한 개 |
| 서버 공개 포트 | 기존 `20007` |
| 컨테이너 포트 | 기존 `80` |
| LB 수신 포트 | 기존 `18007` |
| 동시 배포 수 | 1대 |
| 최소 서비스 서버 수 | 2대 |
| 복구 자원 | 서버별 이전 정상 이미지와 정확한 실행 설정 |

색상별 컨테이너나 추가 포트는 사용하지 않는다. 버전 혼재 기간에 v1과 v2의 응답 계약이 호환되어야 하며, 남은 두 대가 전체 요청을 감당할 수 있어야 한다. 향후 세션·DB를 추가하면 세션 외부 저장과 구·신버전 스키마 호환성을 별도로 설계한다.

```text
초기       LB → app1 v1 + app2 v1 + app3 v1
app1 교체  LB →           app2 v1 + app3 v1
app1 복귀  LB → app1 v2 + app2 v1 + app3 v1
app2 교체  LB → app1 v2 +           app3 v1
app2 복귀  LB → app1 v2 + app2 v2 + app3 v1
app3 교체  LB → app1 v2 + app2 v2
최종       LB → app1 v2 + app2 v2 + app3 v2
```

각 서버 제외 직전에 나머지 두 대의 ready 상태와 LB 경유 응답을 다시 확인한다. 이미 다른 한 대가 장애 상태라면 추가 서버를 제외하지 않고 중단한다.

## 4. 앱 개선 계획

### 4-1. 작은 Python HTTP 앱

고정 응답 앱을 Python 표준 라이브러리 `ThreadingHTTPServer` 기반 앱으로 바꾸는 안을 사용한다. 외부 Nginx LB와 컨테이너 포트 80은 유지한다. 별도 DB는 추가하지 않는다. 이 서버는 실습용이며 운영용 서버 선정은 별도 검토한다.

| 경로 | 동작 | 용도 |
| --- | --- | --- |
| `/` | 서비스명·버전·릴리스·서버 ID를 JSON으로 응답 | 실제 서비스 검사와 트래픽 추적 |
| `/health` | 프로세스가 HTTP 요청을 처리하면 200 | 생존 확인 |
| `/ready` | 초기화·메타데이터·필수 설정 검사 완료 시 200, 준비 전/실패 시 503 | 서비스 투입 가능 여부 |
| `/version` | 이미지에 기록된 앱 버전 반환 | 버전 확인 |
| 그 외 경로 | 404 | 잘못된 경로 구분 |

```json
{
  "service": "sohyeon-cicd-app",
  "version": "v2",
  "release_id": "v2-a1b2c3d4e5f6-42",
  "git_revision": "a1b2c3d4e5f6...",
  "server_id": "sohyeon-app2",
  "ready": true
}
```

`SERVER_ID`에는 `inventory_hostname`을 주입한다. 버전·커밋·릴리스는 빌드 시 이미지 내부 메타데이터 파일에 기록하고 실행 시 앱이 읽는다. 환경변수로 버전 문자열만 바꿔 같은 이미지를 새 버전처럼 표시하지 않는다. 응답은 `Cache-Control: no-store`를 사용한다.

### 4-2. Health와 readiness의 구분

현재 고정 `OK`는 HTTP 응답 가능 여부만 보여 준다. 개선 앱도 health 하나로 전체 기능을 보장하지 않는다. 배포 검증은 `/ready`, 실제 서비스 `/`, 이미지 릴리스 정보를 함께 확인한다. 존재하지 않는 DB를 검사한다고 설명하지 않는다.

실험용 옵션으로 시작 지연, readiness 실패, 일정 시간 후 `/`의 503 응답을 추가할 수 있다. 기본값은 정상이며 지정한 대상 서버의 새 컨테이너에만 적용한다. 공개 장애 제어 API는 만들지 않는다. readiness 통과 뒤 실제 서비스가 실패하는 경우도 검증한다.

서버는 정상 종료 신호를 처리하고 진행 중 요청을 마치도록 구현한다. 다만 애플리케이션의 종료 처리만 믿고 트래픽 제외·drain 확인 없이 컨테이너를 종료하지 않는다. 단위 테스트에는 초기화 실패, 상태 전이, 메타데이터, 기본 응답과 서버 식별을 포함한다.

## 5. Jenkins Pipeline 설계

### 5-1. Stage와 동시 실행 정책

| Stage | 작업 | 통과 조건 |
| --- | --- | --- |
| Check Environment | 도구·Docker·컬렉션 접근 확인 | 실행 환경 정상 |
| Checkout / Release Metadata | 커밋·버전·릴리스 식별 | 입력값 검증 성공 |
| Unit Test | 앱 로직 검사 | 테스트 통과 |
| Build | 메타데이터를 포함한 이미지 생성 | 빌드 성공 |
| Test Image | 임시 컨테이너의 ready·기본 응답·버전 검사 | 기대 릴리스 확인 |
| Prepare Artifact | tar와 체크섬 생성 | 전달 파일 준비 |
| Prepare SSH | 전용 known_hosts 생성 | 키 준비 성공 |
| Preflight | 현재 서버별 릴리스·LB 설정·용량·복구 자원 확인 | 상태 일치 및 3대 정상 |
| Prepare Images | 서버 3대에 새 이미지 미리 전달·로드 | 모든 서버 이미지 준비 |
| Rolling Deploy | 한 서버씩 제외·drain·교체·검증·복귀 | 서버별 전체 절차 성공 |
| Verify Fleet | 서버 3대 직접 검사와 LB 안정화 검사 | 모두 목표 릴리스, 서비스 정상 |
| Finalize | 전체 배포 성공 확정 및 보고서 보관 | 상태 기록 성공 |
| Cleanup Plan / Archive | 정리 후보·보호 이유 생성, 배포 증거 사전 보관 | 계획 생성·archive 성공 |
| Cleanup Apply | apply 모드에서 앱·LB의 보호 목록 밖 자원 정리 | 삭제 직전 재검증·삭제 후 검증 성공 |
| post / always | 실패 로그·요청 결과 보관, Agent 임시 자원 정리 | 성공·실패 공통 |

이미지 테스트의 `sleep 2`는 요청별 timeout과 전체 준비 대기 기한을 갖춘 재시도로 바꾼다. 버전 예시는 `APP_VERSION=v2`, `RELEASE_ID=v2-커밋일부-빌드번호`로 한다.

**Nginx 제외/등록과 중간 검증은 Rolling Deploy 안에서 서버마다 실행한다.** 모든 서버를 제외하는 stage, 모든 컨테이너를 바꾸는 stage, 모든 서버를 등록하는 stage로 나누면 서비스 공백이 발생한다. Jenkins 화면에는 Rolling Deploy를 표시하고 Ansible task와 배포 이벤트에 서버명·하위 단계를 기록한다.

같은 job은 `disableConcurrentBuilds()`로 직렬화한다. 별도 정리·복구 job까지 병행하려면 공통 환경 잠금이 필요하다. 동시성 제어용 Jenkins 플러그인을 추가하지 않고 초기에는 하나의 job에서 배포·복구·정리를 제어한다. 수동 작업이나 다중 Agent까지 포함하려면 공유된 배포 잠금과 소유권·중단 후 복구 규칙을 별도로 구현한다.

### 5-2. 조건 분기와 결과 보관

Declarative Pipeline의 `when`과 `post`를 사용해 정리 조건과 종료 처리를 명시한다. `CLEANUP_MODE` 기본값은 `plan`으로 두고, 정상 배포 경로에서는 Finalize 성공 후 Cleanup Plan / Archive를 수행한다. Cleanup Apply는 `when { expression { params.CLEANUP_MODE == 'apply' } }`로 분기하되, 전체 배포 확정·사전 archive 성공·삭제 직전 보호 목록 재검증을 모두 통과해야 한다. 파라미터 하나만으로 삭제를 허용하지 않는다.

| 위치 | 처리 |
| --- | --- |
| 정리 전 Archive | probe 원본·집계, 배포 이벤트, 필요한 진단 자료와 cleanup-plan을 보관. 실패하면 원격 삭제 금지 |
| `post / always` | 실행 중인 probe 종료·flush 확인, 수집 가능한 결과 집계, Ansible 로그·상태·cleanup-result 최종 보관 |
| `post / failure` | 배포 실패와 정리 실패를 구분해 결과 기록. 원격 복구는 Ansible의 서버별 복구 경로가 담당 |
| `post / aborted` | Jenkins 중단을 별도로 기록. 다음 실행에서 영속 상태와 실제 서비스를 대조하도록 안내 |
| `post / cleanup` | 해당 빌드의 Agent 테스트 자원과 인증 임시 자료 정리. 보고서 원본은 archive 성공 확인 후 삭제 |

`post` 조건은 실행 순서가 정해져 있으므로 failure/aborted에서 만든 결과도 보관할 수 있도록 마지막 cleanup에서 결과 기록 보관을 먼저 시도하고 임시 자원을 정리한다. 한 수집 작업이 실패해도 나머지 자료 수집과 인증 자료 정리를 시도하며, 수집 실패를 별도 기록하고 원래 배포 실패 원인을 유지한다. 초기 stage 실패로 생성되지 않은 파일은 미생성으로 기록하고, 생성됐어야 할 필수 증거의 누락을 정상으로 숨기지 않는다.

아티팩트는 `.artifacts/` 안의 지정된 보고서·로그만 명시적으로 수집한다. workspace 전체, SSH 개인 키, 인증 임시 파일, 민감정보가 포함된 원본 실행 설정은 보관하지 않는다. 복구용 정확한 실행 설정은 원격의 접근 제한 경로에 보존하고, 제출용 상태·진단 자료는 민감값을 제거한다. archive 실패 시 보고서 원본은 보존하되 인증 임시 파일은 별도로 정리한다.

`post / cleanup`은 원격 이미지 정리 stage를 대신하지 않는다. Jenkins나 Agent가 강제로 종료되면 post 자체가 완료되지 않을 수 있으므로, post에서 자동 재등록·전체 롤백을 보장한다고 설명하지 않는다. 중단 후 복구는 8절의 상태 대조 절차를 따른다. [Jenkins Pipeline 문법](https://www.jenkins.io/doc/book/pipeline/syntax/)

### 5-3. Jenkins Credentials와 민감정보 관리

SSH 개인 키는 Jenkins의 SSH Username with private key Credential로 관리하고, 원격 작업에 필요한 구간에서 `withCredentials`로 임시 키 경로와 사용자명을 전달한다. 키 내용을 저장소·인벤토리·명령 문자열에 직접 넣지 않는다. `prepare_ssh`의 전용 known_hosts와 호스트 키 검증은 유지한다. Credentials Binding 사용 가능 여부와 사용할 credential ID는 구현 전 확인한다.

- Groovy 문자열 보간으로 비밀값을 명령에 삽입하지 않고 셸에서 바인딩된 변수를 참조한다. 인증 처리 구간은 shell tracing을 끈다.
- 민감정보를 처리하는 Ansible task에 `no_log: true`를 적용하고, 등록된 결과를 후속 debug에서 출력하지 않는다. 일반 배포·readiness 로그는 관측을 위해 유지한다.
- 임시 키는 Credentials 바인딩 범위에서 관리하고, 추가 복사본을 만들지 않는다. secret file이 browsable workspace 하위에 노출되지 않도록 바인딩과 `dir`의 순서를 확인한다.
- 앱·배포 상태·수집 로그에 비밀값을 넣지 않고, 제출 자료와 Jenkins 콘솔에 인증정보가 없는지 검증한다.

이번 앱에는 DB나 별도 비밀 설정을 추가하지 않으므로 **Ansible Vault는 필수 범위에 넣지 않는다.** 이후 저장소에서 암호화해 관리해야 할 실제 비밀 변수가 생기면 Vault와 Jenkins Secret File 기반 비밀번호 전달을 추가한다. workspace에 `.vault_pass`를 직접 생성하는 패턴은 사용하지 않는다. [Credentials Binding](https://www.jenkins.io/doc/pipeline/steps/credentials-binding/)

### 5-4. 이번 실습에서 도입하지 않는 확장

- `milestone`과 `disableConcurrentBuilds(abortPrevious: true)`를 통한 배포 중 선점은 사용하지 않는다. 서버 제외·교체 중 취소는 안전한 복구를 보장하지 않으며, 현재의 job 직렬화와 상태 대조 정책을 유지한다. 향후 빌드 병렬화가 필요하면 환경 잠금과 함께 배포 시작 전 오래된 대기 빌드를 제거하는 방식을 별도 설계한다.
- Shared Library는 여러 job에 공통 로직이 생길 때 검토한다. 이번에는 probe·집계 로직을 `scripts/`에 두고 Jenkinsfile은 단계 실행과 결과 보관에 집중한다.
- `when { branch 'main' }`은 Multibranch Pipeline 도입 시 검토한다. 현재 job에 브랜치 조건만 추가해 배포가 의도치 않게 건너뛰어지게 하지 않는다.

## 6. Ansible의 서버별 실행 구조

### 6-1. 핵심 playbook 형태

다음은 구조 예시이며 참조하는 role은 구현 예정이다.

```yaml
- name: Roll out one application server at a time
  hosts: app_servers
  gather_facts: false
  strategy: linear
  serial: 1
  order: inventory
  any_errors_fatal: true
  roles:
    - role: "{{ playbook_dir }}/../roles/rolling_deploy"
```

`serial: 1`은 한 서버에서 play를 마친 뒤 다음 서버로 진행하게 한다. `delegate_to`로 현재 서버의 제외·등록 작업을 LB에서 수행한다. 기존 상태를 읽고 제외 목록을 갱신할 때 원래 앱 서버 이름을 명시적으로 넘겨 위임 대상의 변수와 혼동하지 않는다. [Ansible 공식 Rolling 예제](https://docs.ansible.com/projects/ansible/latest/playbook_guide/guide_rolling_upgrade.html)

전체 LB 검사와 상태 초기화는 별도 preflight play에서 LB 한 대를 대상으로 실행한다. 서버별 제외·등록에는 `run_once`를 붙이지 않는다. `serial: 1` 구간에 `throttle: 1`을 추가하는 것은 현재 동시성을 더 줄이지 않으므로 필수로 넣지 않는다. 향후 병렬 play에서 공용 LB 변경 task를 위임할 때 검토하되, `throttle`을 다른 job·Ansible 프로세스·수동 작업까지 막는 환경 잠금으로 취급하지 않는다.

`any_errors_fatal`만으로 모든 실패 복구가 해결되지는 않는다. rescue가 복구에 성공해도 마지막에 명시적으로 fail하여 후속 서버 배포를 중단한다. 연결 불가나 실행 중단은 상태 기록과 재실행 검증으로 처리한다.

### 6-2. 한 서버의 배포 순서

1. 대상 서버의 기존 이미지 ID·태그·환경·포트·재시작 정책을 저장한다.
2. 나머지 두 대의 readiness와 현재 LB 서비스를 확인한다.
3. 대상의 상태를 `draining`으로 기록하고 Nginx에서 해당 서버를 제외한다.
4. 설정 검사·reload·기존 요청 종료 확인을 완료한다.
5. `updating` 상태를 기록하고 현재 컨테이너를 새 릴리스로 교체한다.
6. 서버 내부에서 `/ready`, `/`, `/version`과 서버 ID·릴리스를 검사한다.
7. LB에서 대상 IP:20007로 직접 요청해 네트워크 경로까지 확인한다.
8. 성공 시 대상을 Nginx에 재등록하고 reload한다.
9. 대상의 정상 응답과 LB 서비스 안정성을 확인하고 서버별 성공 상태를 기록한다.
10. 현재 서버의 확인이 끝난 뒤 다음 서버로 진행한다.

서버별 재등록 이후 관찰 시간은 초기 15초, 전체 종료 후 안정화 시간은 60초로 정하고 실험 결과에 따라 조정한다. 진행 중에는 구버전·신버전 응답을 모두 허용하지만 서버 ID별 기대 릴리스와 맞는지 검사한다. 최종 단계에서는 전 서버가 목표 릴리스여야 한다.

### 6-3. 구현할 파일

| 파일/role | 책임 |
| --- | --- |
| `playbook/prepare_ssh.yml` | 기존 SSH 준비 |
| `playbook/preflight.yml` | 전체 상태·가용 서버·복구 가능성 검사 |
| `playbook/prepare_images.yml` | 전 서버 이미지 전달·로드 |
| `playbook/deploy.yml` | serial 1로 rolling_deploy 실행 |
| `playbook/verify.yml` | 전 서버 및 LB 최종 검사 |
| `playbook/rollback.yml` | 지정 서버 또는 완료 서버들의 순차 복구 |
| `playbook/cleanup.yml` | 서버별 계획·삭제·사후 검사 |
| `roles/rolling_deploy/` | 한 서버의 전체 배포·실패 복구 흐름 |
| `roles/app/` | 이미지 로드·컨테이너 실행·조회 |
| `roles/nginx_lb/` | 제외 목록 반영·설정 검사·reload handler |
| `roles/verification/` | HTTP·릴리스·서버 식별 검사 |
| `roles/deployment_state/` | 서버별 상태 기록·재시작 시 대조 |
| `roles/cleanup/` | 소유권·보호 목록 기반 정리 |

## 7. Nginx 제외·등록과 drain

### 7-1. 설정 적용

upstream은 인벤토리와 `excluded_hosts` 목록에서 생성한다. 예시에서는 제외할 서버를 `down`으로 표시한다. 서버 공개 포트는 `host_port` 변수 하나로 관리한다.

```jinja2
upstream sohyeon_backend {
{% for host in groups['app_servers'] %}
    server {{ hostvars[host]['ansible_host'] }}:{{ host_port }}{% if host in excluded_hosts %} down{% endif %};
{% endfor %}
}
```

변경 순서: 현재 프로젝트 설정 기록 → 후보 설정 생성 → 임시 전체 구성으로 문법 검사 → 프로젝트 설정 원자적 교체 → 실제 전체 구성 검사 → handler 즉시 실행 → 실제 응답 확인.

upstream 조각만 `nginx -t -c`에 넣지 않는다. 공용 include 구조를 반영한 전체 구성이 필요하다. 임시 파일이 실제 `conf.d/*.conf`에 중복 포함되지 않도록 한다. 다른 사용자의 설정을 덮어쓰지 않는다. handler는 다음 교체 단계 전에 flush하여 reload를 완료한다.

`CONFIGURE_NGINX`는 최초 구성용으로 남길 수 있지만 서버 제외·복귀는 매 배포의 필수 작업이다. 서버마다 최소 제외·복귀 두 번의 reload가 필요하므로 공용 LB의 다른 설정 작업과 충돌하지 않는 운영 절차가 필요하다.

### 7-2. 기존 요청 처리 완료 확인

reload 성공은 기존 요청 종료를 뜻하지 않는다. 기존 Nginx 워커는 이미 연결된 클라이언트 요청을 처리할 수 있다. [Nginx 공식 문서](https://nginx.org/en/docs/control.html)

실습의 drain 완료 기준은 보수적으로 다음과 같이 잡는다.

- 제외 reload 전에 아직 실행 중인 이전 세대 워커의 PID와 프로세스 시작 시각을 기록한다. 이미 종료 중인 워커도 포함한다.
- reload 후 새 워커가 실행되는지 확인하고, 기록한 이전 세대 워커가 모두 정상 종료될 때까지 기다린다.
- LB 외부에서 앱 포트로 직접 들어오는 서비스 트래픽이 없다는 전제를 확인한다. 앱 직접 접근은 검사 트래픽으로 제한한다.
- 이전 워커 종료 후 대상의 진행 요청·연결이 없는지도 확인하고 컨테이너 교체를 허용한다.
- 초기 drain 제한 시간은 60초로 한다. 기한을 넘기면 컨테이너를 강제로 교체하지 않고, 기존 버전이 정상일 때 대상을 재등록한 뒤 배포를 중단한다.

공용 LB의 다른 서비스에 긴 연결이 있으면 워커 종료가 늦어져 배포가 중단될 수 있다. 이는 이번 실습의 보수적인 제한이다. 워커를 강제 종료하거나 공용 timeout을 줄여 우회하지 않는다. 워커 종료를 확인할 권한·환경이 없으면 고정 sleep으로 무중단을 주장하지 말고, 전용 LB 또는 신뢰할 수 있는 대상별 drain 관측을 먼저 마련한다.

## 8. 서버별 상태와 실패 처리

### 8-1. 상태 기록

LB의 프로젝트 전용 경로(예: `/var/lib/sohyeon-cicd/deployment.json`)에 상태를 원자적으로 기록한다. Jenkins workspace에만 두지 않는다.

```yaml
deployment_id: v2-a1b2c3d4e5f6-42
target_release: v2-a1b2c3d4e5f6-42
status: rolling
excluded_hosts: []
servers:
  sohyeon-app1:
    current_release: v2-a1b2c3d4e5f6-42
    previous_release: v1-112233445566-41
    phase: healthy
  sohyeon-app2:
    current_release: v1-112233445566-41
    previous_release: v1-112233445566-41
    phase: pending
  sohyeon-app3:
    current_release: v1-112233445566-41
    previous_release: v1-112233445566-41
    phase: pending
```

상태는 `pending → draining → updating → verifying → rejoining → healthy`로 기록한다. 서버의 previous_release와 실행 설정은 해당 배포 시작 시 스냅샷으로 고정하여 재시도 때문에 덮어쓰지 않는다. 전체 성공은 세 서버가 목표 릴리스이며 제외 대상이 없을 때만 확정한다.

재실행 시 상태 파일, 실제 컨테이너 이미지·응답, Nginx 설정·실제 서비스 상태를 대조한다. 파일만 보고 배포 완료나 트래픽 제외 완료를 가정하지 않는다. 불일치는 `recovery_required`로 표시하고 자동 교체를 멈춘다. `run_once`는 serial 배치마다 실행될 수 있으므로 전체 상태 초기화는 별도 preflight play에서 한 번 수행한다.

### 8-2. 실패 위치별 처리

| 실패 | 처리 | 다음 서버 |
| --- | --- | --- |
| 이미지 테스트·전달·preflight 실패 | 기존 서비스 유지, 배포 시작 안 함 | 진행 금지 |
| Nginx 제외 실패 | 기존 컨테이너 보존, 설정·서비스 확인 | 진행 금지 |
| drain 시간 초과 | 기존 앱 정상 확인 후 재등록, 실패 기록 | 진행 금지 |
| 새 컨테이너 실행·직접 검증 실패 | 제외 상태에서 이전 이미지·실행 설정 복원 후 검증·재등록 | 진행 금지 |
| 재등록 후 대상 장애 | 다시 제외·drain 후 이전 버전 복구, 검증·재등록 | 진행 금지 |
| 이전 버전 복구 실패 | 대상 제외 유지, 나머지 두 대 확인, 복구 자료 보존 | 진행 금지 |
| SSH 단절·Jenkins 중단 | 확실하지 않은 대상을 자동 등록/삭제하지 않음, 상태 대조 필요 | 진행 금지 |
| 최종 전체 검증 실패 | 새 배포와 정리 중단, 문제 서버 식별 및 복구 | 진행 금지 |

기본 자동 복구 범위는 **현재 실패한 서버**다. 예를 들어 app1이 v2로 성공한 뒤 app2가 실패하면 app2를 v1으로 복구하고 app3는 v1으로 유지한다. app1은 v2로 남으므로 전체 상태를 `failed_partial`로 기록한다. 이것을 전체 롤백 성공이라고 보고하지 않는다.

전체 v1 복귀가 필요하면 이미 갱신된 서버들을 동일한 제외·drain·복원·검증·등록 절차로 한 대씩 되돌리는 별도 rollback 경로를 실행한다. 모든 서버를 동시에 복원하지 않는다. 이 정책 때문에 구·신버전 공존 가능성이 사전 조건이다.

Ansible `block/rescue`에서 복구 후에도 `ansible.builtin.fail`로 원래 배포 실패를 반환한다. unreachable과 프로세스 중단은 일반 rescue의 완전한 보장 범위가 아니므로 영속 상태와 별도 복구 경로가 필요하다. [Ansible Blocks 문서](https://docs.ansible.com/projects/ansible-core/devel/playbook_guide/playbooks_blocks.html)

## 9. 기존 Week 1 앱에서 전환하기

기존 앱에는 `/ready`와 서버 식별 JSON이 없다. 바로 새 검증 계약을 강제하면 최초 preflight와 이전 버전 복구 검사가 실패한다.

1. 기존 이미지 ID·버전·실행 설정과 현재 LB 구성을 기록한다.
2. 최초 마이그레이션에서는 기존 서버에 `/health`·`/version` 검사를 적용하고 새 앱에 새 검사 계약을 적용한다.
3. 기존 컨테이너를 서버별로 롤링 교체해 개선 앱 v1을 전 서버에 준비한다.
4. v1 정상 상태를 기준으로 v1 → v2 과제 실험을 시작한다.

기존 앱 응답에는 서버 ID가 없으므로 최초 마이그레이션의 서버 식별은 프로젝트 LB access log의 upstream 주소와 직접 검사 결과로 보완한다. 새 환경의 최초 설치 자체는 기존 서비스가 없으므로 무중단 전환 실험과 구분한다.

## 10. 연속 요청과 검증 기준

### 10-1. 검사 위치

| 위치 | 검사 내용 |
| --- | --- |
| Agent 임시 컨테이너 | ready·기본 응답·빌드 메타데이터 |
| 서버 제외 전 | 나머지 두 대 ready·기본 응답, LB 서비스 |
| 서버 교체 후 내부 | 목표 릴리스·서버 ID·ready |
| LB → 대상 IP:20007 | 원격 접근 가능성과 응답 일치 |
| 재등록 후 | 대상 직접 검사 + LB 서비스 + 해당 서버의 실제 처리 기록 |
| 전체 완료 | 서버 3대가 모두 목표 릴리스, LB 안정화 |

초기값은 요청 timeout 2초, readiness 전체 기한 60초, 연속 성공 3회로 한다. 재등록 후 LB에 한 번 요청해서 원하는 서버가 응답하지 않았다는 이유만으로 실패로 보지 않는다. 충분한 요청과 upstream 로그로 처리 여부를 확인하고 직접 검사를 병행한다. 반대로 LB 한 번 성공만으로 세 서버 모두 정상이라고 판단하지 않는다.

### 10-2. 요청 수집

`scripts/probe.py`를 구현해 배포 전 30초부터 종료 후 최소 60초까지 독립적으로 `/`에 요청한다. 예시는 아직 구현 전인 명령이다.

빌드별 probe 프로세스 식별 정보를 보관하고 정상 경로에서는 관측 구간 완료 후 종료·flush·집계를 마쳐 정리 전 archive에 포함한다. 실패 경로에서도 실행 환경이 유지되면 실패·복구 후 관측을 이어간 뒤 post에서 종료·수집한다. 중단이나 Agent 유실로 관측 시간이 짧아진 경우 실제 종료 시각과 누락 구간을 기록하며 정상 관측 완료로 보고하지 않는다.

```sh
python3 scripts/probe.py \
  --url http://1.201.116.156:18007/ \
  --interval 0.2 \
  --timeout 2 \
  --output .artifacts/availability.jsonl
```

UTC 요청 시각·완료 시각·상태 코드·오류·응답 시간·version·release_id·server_id를 저장한다. 배포 로그에도 서버별 제외·drain 완료·교체·등록 시각을 남겨 대조한다. 초당 약 5회 목표로 제한된 동시성을 사용하고 timeout 때문에 측정이 멈추거나 생략된 구간도 기록한다.

Agent에서 실행하면 Agent 관점의 결과다. 외부 사용자 경로를 확인하려면 외부 측정 클라이언트를 추가한다. 초기 실험은 새 연결 기준으로 관찰하고 긴 요청·지속 연결은 별도로 검증한다. 공용 서버를 과부하시키는 테스트로 확대하지 않는다.

### 10-3. 지표와 성공 기준

| 지표 | 판정 |
| --- | --- |
| HTTP 성공률 | HTTP 200 수 / 전체 시도 수 × 100 |
| 유효 응답 성공률 | HTTP 200이며 필수 JSON 정상인 수 / 전체 시도 수 × 100 |
| 오류 | 연결 실패·timeout·5xx·파싱 오류를 구분, 분모에서 제외하지 않음 |
| 응답 시간 | 평균·p95·최대, 배포 전과 비교 |
| 서버별 처리 | 서버 ID별 요청 수와 해당 시각의 릴리스 |
| 버전 혼재 | 롤링 중 v1/v2 공존, 종료 후 v2만 존재 |
| 제외 효과 | drain 완료 후 교체 대상이 사용자 요청을 처리하지 않음 |
| 실패 관측 구간 | 연속 실패 시각과 길이, 정확한 전체 장애 시간과 구분 |

정상 배포의 목표는 관측 실패 0건과 최종 전 서버 목표 릴리스다. 롤링 도중 정상 v1 응답은 실패가 아니다. 타임라인에 app1→app2→app3 순차 전환이 나타나야 한다. 표본 요청의 성공률 100%를 모든 조건의 무중단 보장으로 확대하지 않는다.

| 실험 | 기대 결과 |
| --- | --- |
| v1 → v2 정상 배포 | 순차 전환, 혼재 후 v2 통일, 관측 실패 0건 |
| app2 새 버전 readiness 실패 | app2 이전 버전 복구, app3 미배포, app1 v2 유지, 전체 실패 |
| 새 버전의 잘못된 릴리스 | 재등록 전 차단 |
| LB에서 대상 포트 접근 불가 | 내부 검사 성공과 관계없이 재등록 차단 |
| 다른 서버가 이미 장애 | 추가 서버 제외 금지 |
| 긴 요청으로 drain 기한 초과 | 앱 강제 종료 없이 중단·안전한 재등록 |
| 재등록 후 서비스 503 | 대상 재제외·복구, 다음 서버 중단 |
| 잘못된 Nginx 후보 설정 | reload 금지, 기존 정상 설정 보존 |
| 배포 중단 후 재실행 | 실제 상태 대조, 잘못된 교체·등록 금지 |
| 전체 이전 버전 복귀 | 갱신된 서버만 한 대씩 복원 |

재등록 후 장애 실험은 오류 0건보다 감지·복구 성공과 복구 시간을 평가한다. 다른 사용자의 컨테이너나 공용 Nginx를 중지해 장애를 만들지 않는다.

## 11. 서버별 정리 자동화

### 11-1. 삭제와 보존 대상

| 위치 | 정리 대상 | 보존 대상 |
| --- | --- | --- |
| Agent | 종료된 내 테스트 컨테이너, tar·SSH 임시 파일, 미사용 프로젝트 이미지 | 실행 중 작업, archive 전 보고서, 다른 프로젝트 자원 |
| app1/app2/app3 각각 | 원격 tar, 보호 목록 밖 내 이미지·불필요한 내 컨테이너 | 현재 실제 이미지, 이전 정상 이미지·실행 설정, 진행 중 목표 이미지, 미해결 실패 자료 |
| LB | 프로젝트 임시 설정·만료된 백업·진단 파일 | 현재 설정, 복구에 필요한 설정, 서버별 상태 파일 |
| Jenkins Controller | 해당 job의 보관 정책 밖 빌드·아티팩트 | 보관 기간 안의 결과 |

현재 실행 중인 컨테이너는 서버당 하나다. 롤백용 이전 컨테이너를 계속 실행하는 대신 이전 이미지와 정확한 실행 설정을 보존하고 필요할 때 재생성한다. 현재/이전 정상은 빌드 번호가 가장 큰 두 개가 아니라 서버별 배포 기록과 실제 이미지 ID로 판단한다.

부분 실패 상태에서는 갱신된 서버와 미갱신 서버의 보호 목록이 다르다. 전체 배포를 확정하기 전에 이전 이미지를 정리하지 않는다. 재실행해도 배포 시작 당시 복구 기준이 사라지지 않도록 한다.

### 11-2. 소유권과 삭제 순서

이미지·컨테이너에 `io.sohyeon.project=sohyeon-cicd`, `io.sohyeon.release=<release>`, 컨테이너에는 `io.sohyeon.role=test|app`과 서버 식별 정보를 부여한다. label, 정확한 저장소·컨테이너 이름, 배포 기록을 대조한다. 기존 label 없는 자원은 별도의 확인된 목록으로 관리한다.

1. 환경 잠금 아래 실제 Docker endpoint·컨테이너·이미지·파일·디스크 사용량 조회.
2. 상태 기록·실제 서비스·Nginx 설정 대조 후 서버별 보호 목록 확정.
3. `cleanup-plan.json`에 삭제 후보와 보존 이유 저장.
4. 진단 자료·요청 결과 archive. 보관 실패 시 원본 보존.
5. 삭제 직전 ID·참조·보호 목록 재확인. 상태 변경 시 재계산.
6. 보호 목록 밖 컨테이너 정리 후, 모든 실행/중지 컨테이너 참조를 재조회해 미사용 프로젝트 이미지 태그만 강제 옵션 없이 삭제.
7. 정확한 프로젝트 경로의 임시 tar·설정·만료 백업 삭제. 빈 경로·상위 경로 이탈·예상 밖 심볼릭 링크 거부.
8. 대상 재조회, 서버별 직접 및 LB 경유 검사, `cleanup-result.json` 기록.

결과는 deleted / preserved / skipped / failed와 이유·전후 용량을 포함한다. 실패를 `|| true`로 숨기고 정리 성공이라고 표시하지 않는다. 공유 레이어 때문에 이미지 표시 크기의 합과 회수 용량은 다를 수 있다.

Agent와 앱 서버가 같은 Docker daemon을 사용하면 역할 이름만으로 삭제하지 않고 전체 보호 목록을 합친다. 전역 `docker system prune -a`, `docker image prune -a`, `/tmp/*` 삭제와 공용 캐시·volume 삭제는 사용하지 않는다. 소유권 불명의 dangling 이미지는 skipped로 남긴다. 로그 증가에는 컨테이너별 로그 회전을 적용하며 Docker 관리 파일이나 공용 LB 로그를 직접 삭제하지 않는다.

### 11-3. 실행과 사후 검증

- `CLEANUP_MODE=plan|apply` (기본값 `plan`): plan은 조회·목록 생성, apply는 `when` 조건과 전체 성공·사전 archive·삭제 직전 재검증을 통과한 경우에만 삭제. check mode만으로 임의 shell 삭제를 안전하다고 가정하지 않음.
- `CLEANUP_SCOPE=agent|app_servers|load_balancer`: inventory와 `--limit`으로 대상 명시.
- 정상 전체 배포 확정 후 앱 서버를 한 대씩 정리·검증. 문제 시 다음 정리 중단.
- 실패 시에는 명확한 임시 자원만 정리하고 롤백 자료 보존.
- 원격 작업 종료 후 Agent 인증 임시 파일 정리. 보고서 보관 실패 시에도 인증 파일은 정리하고 보고서 원본만 보존.
- 정리 실패는 배포 결과와 구분. 이미 검증된 서비스를 디스크 정리 실패만으로 자동 롤백하지 않음.

완료 기준은 삭제 예정 항목의 제거 확인, 현재 서비스와 이전 이미지 보존, 다른 프로젝트 무영향, 반복 정리 시 불필요한 변화 없음, 실패·건너뜀 이유 기록이다.

## 12. Ansible Galaxy 활용

### 12-1. community.docker 적용

Jenkins 플러그인 추가 대신 Galaxy 컬렉션의 Docker 모듈을 기존 role에 적용한다. 컬렉션은 Agent에 설치하고, 원격 모듈 실행 노드에는 해당 버전의 Python 의존성과 Docker 접근 권한을 준비한다. Galaxy가 원격 Docker Engine이나 Python 패키지까지 자동 설치해 주지는 않는다.

| 작업 | 모듈 |
| --- | --- |
| tar 로드 | `community.docker.docker_image_load` |
| 현재 이미지·실행 설정 조회 | `community.docker.docker_container_info` |
| 컨테이너 목표 상태 적용·삭제 | `community.docker.docker_container` |
| 서버별 전체 자원 조회 | `community.docker.docker_host_info` |
| 이미지 ID·label·태그 조회 | `community.docker.docker_image_info` |
| 보호 목록 밖 이미지 태그 삭제 | `community.docker.docker_image_remove` |

공식 자료: [모듈 목록](https://docs.ansible.com/projects/ansible/13/collections/community/docker/index.html), [컨테이너 관리](https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_container_module.html), [이미지 로드](https://docs.ansible.com/projects/ansible/latest/collections/community/docker/docker_image_load_module.html).

`ansible/requirements.yml`에 검증한 정확한 컬렉션 버전을 기록한다. Agent의 ansible-core, 원격 Python과 Docker API 호환성을 확인한 뒤 버전을 확정하며 매 실행에서 무조건 최신 버전을 받지 않는다.

```sh
# requirements.yml 작성 및 프로젝트 설정 준비 후 실행할 예시
ansible --version
ansible-galaxy collection list
ansible-galaxy collection install -r ansible/requirements.yml -p .ansible/collections
ansible-doc -t module community.docker.docker_container
```

프로젝트 ansible.cfg의 collection 검색 경로와 설치 경로를 맞추고 `ANSIBLE_CONFIG`를 명시한다. 공용 Agent의 기존 컬렉션을 덮어쓰지 않는다. Check Environment에서 필수 모듈 로딩을 확인한다. Docker SDK 등 요구사항은 선택한 모듈 버전의 Requirements로 확인한다.

### 12-2. drain 완료 후 컨테이너 교체 예시

아래 task는 단독 실행용이 아니다. rolling_deploy 안에서 현재 서버가 제외됐고 drain이 완료되었으며 이전 이미지와 실행 설정이 보존됐다는 검증 후 실행한다.

```yaml
- name: Apply the target release on the drained server
  community.docker.docker_container:
    name: "{{ app_name }}"
    image: "{{ image_name }}:{{ target_release }}"
    state: started
    restart_policy: unless-stopped
    published_ports:
      - "{{ host_port }}:{{ container_port }}"
    env:
      SERVER_ID: "{{ inventory_hostname }}"
    labels:
      io.sohyeon.project: sohyeon-cicd
      io.sohyeon.release: "{{ target_release }}"
      io.sohyeon.role: app
  become: true
```

변경된 이미지·설정에 따른 컨테이너 재생성은 이 격리 구간에서만 허용한다. `state: started`는 readiness나 무중단을 보장하지 않으므로 뒤에 HTTP 검사가 필요하다. 같은 목표 상태를 재적용했을 때 불필요한 재시작이 없는지 확인하고, 재생성·이미지 비교 동작은 선택한 컬렉션 버전에서 검증한다.

### 12-3. Galaxy 실험과 정리 연결

조회 모듈부터 적용해 현재 정보를 구조화된 값으로 받는다. 중지 컨테이너도 빠짐없이 조회한다. 그다음 이미지 준비와 컨테이너 교체, 복원, 정리 task 순으로 적용한다. 모듈을 사용해도 프로젝트 소유권·롤백 보호 정책을 직접 작성해야 한다.

Agent에서 기존 `sg docker -c` 권한이 모듈에 자동 적용되지는 않는다. 로컬 Docker 접근 권한과 원격 `become: true`를 구분한다. tar load의 changed 여부와 컨테이너 재시작 여부도 별도로 평가한다.

Nginx 설정과 HTTP·파일 작업은 기존 `ansible.builtin.template`, `service`, `uri`, `assert`, `file`을 활용한다. 먼저 community.docker 하나를 실제 배포와 정리에 적용하고 필요할 때 추가 컬렉션을 검토한다.

## 13. 구현 순서와 제출 체크리스트

구현 순서:

1. Python 앱·단위 테스트·연속 요청 수집 도구 작성.
2. Galaxy 컬렉션 버전 확정, 조회와 이미지 준비 모듈 적용.
3. LB 제외·등록·handler 및 drain 관측 구현.
4. serial 1 서버별 교체·검증과 실패 서버 복구 구현.
5. 상태 영속화·재실행 대조·전체 순차 롤백 구현.
6. Credentials 바인딩·민감 task 로그 보호, `when`·`post`와 정리 전/종료 시 아티팩트 보관 구현.
7. 서버별 정리 plan/apply와 삭제 후 검증 구현.
8. 정상 배포·부분 실패·복구·재실행 실험 실행 및 결과 기록. app2 readiness 실패 시 app2 복구·app3 미배포와 Jenkins 증거 보관까지 함께 확인.

- [ ] 나머지 두 서버의 용량과 상태를 확인하고 한 대만 제외
- [ ] drain 완료 전 컨테이너를 교체하지 않음
- [ ] 서버별 상태·버전·실제 서비스 검증 후 재등록
- [ ] 재등록 확인 후 다음 서버 진행
- [ ] 실패 서버 복구 후에도 후속 서버 배포 중단
- [ ] 부분 성공과 전체 성공·전체 롤백을 구분
- [ ] 상태 기록과 실제 서비스 불일치 시 삭제·교체 중단
- [ ] 서버 ID별 v1 → v2 전환과 가용성 수치 기록
- [ ] Galaxy 적용 전후 반복 실행·불필요 재시작 여부 확인
- [ ] 서버별 정리 결과와 롤백 자원 보존 확인
- [ ] plan 기본 실행에서 삭제가 없고 apply도 전체 성공·archive·보호 목록 검증 후에만 실행됨
- [ ] 배포 실패·사용자 중단 시 수집 가능한 probe·진단 자료 보관 및 관측 누락 표시
- [ ] archive 실패 시 원격 삭제 중단·보고서 원본 보존, 인증 임시 자료는 정리
- [ ] SSH 키·민감값이 저장소·Jenkins 콘솔·아티팩트에 포함되지 않음

제출 자료는 테스트 결과, 서버별 배포 이벤트, 프로젝트 Nginx 변경 내역, 실패 컨테이너 로그, 상태 기록, 연속 요청 JSONL 및 집계, cleanup-plan/result로 구성한다. 보고서 보관 후 정리하며 SSH 개인 키나 임시 인증 자료는 포함하지 않는다. 실제 성공률·응답 시간·실험 성공 여부는 구현 후 측정값으로 추가한다.
