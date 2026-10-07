# Nginx와 앱 배포 이해하기

지금까지의 질문과 답변을 현재 프로젝트 코드 기준으로 정리한 문서다. 핵심은 **앱 배포는 앱을 실행하는 작업이고, Nginx 설정은 사용자 요청이 그 앱에 도착하도록 연결하는 작업**이라는 점이다.

## 1. 이 프로젝트에서 Nginx가 왜 필요한가?

1주 차 요구사항에는 앱 서버 3대에 동일한 앱을 배포하고, **Nginx를 통해 앱에 접근해 `/health`, `/version`을 확인하는 것**이 포함된다.

앱을 배포하면 각 서버의 `IP:20007`로 직접 접근할 수도 있다. 이 프로젝트에서는 공용 Nginx 주소 하나를 서비스 입구로 사용하고, Nginx가 요청을 앱 서버 3대로 분산하도록 구성했다.

```text
사용자
  ↓ 공용 Nginx 주소의 18007번 포트
공용 Nginx
  ├→ 앱 서버 1의 20007번 포트 → 컨테이너의 80번 포트
  ├→ 앱 서버 2의 20007번 포트 → 컨테이너의 80번 포트
  └→ 앱 서버 3의 20007번 포트 → 컨테이너의 80번 포트
```

요청 하나를 세 서버에 모두 보내는 것은 아니다. Nginx가 서버 하나로 전달하고, 그 서버의 응답을 사용자에게 돌려준다.

## 2. deploy.yml로 배포한 다음 Nginx는 무엇을 하나?

`deploy.yml`은 앱 서버에 컨테이너를 실행한다. 이후 실행 중인 Nginx는 사용자의 요청을 그 컨테이너로 전달한다.

예를 들어 사용자가 `http://공용Nginx주소:18007/version`에 접속하면 다음과 같이 처리된다.

```text
사용자의 /version 요청
→ Nginx가 앱 서버 하나를 선택
→ 해당 앱 서버의 20007/version으로 전달
→ 앱이 v15 등의 버전을 응답
→ Nginx를 거쳐 사용자에게 응답
```

| 구분 | 실행 대상 | 하는 일 |
| --- | --- | --- |
| `deploy.yml` → `app` Role | 앱 서버 3대 | 이미지 전달, 컨테이너 교체, 서버별 검증 |
| `nginx.yml` → `nginx_lb` Role | 공용 Nginx 서버 | 요청 전달 규칙을 설정하고 적용 |
| 실행 중인 공용 Nginx | 공용 Nginx 서버 | 설정된 규칙대로 실제 사용자 요청을 계속 전달 |

`nginx_lb`는 설정을 수행하는 Ansible Role이고, Nginx는 요청을 처리하는 프로그램이다. `lb`는 Load Balancer, 즉 요청을 분산하는 역할을 뜻한다.

## 3. 전달 설정이란 무엇인가?

**어느 포트로 들어온 요청을 어느 서버로 보낼지 정한 규칙**이다.

[sohyeon.conf.j2](../ansible/roles/nginx_lb/templates/sohyeon.conf.j2)의 핵심 내용은 다음과 같다.

```nginx
upstream sohyeon_backend {
    server 1.201.118.202:20007;
    server 1.201.118.10:20007;
    server 1.201.118.90:20007;
}

server {
    listen 18007;

    location / {
        proxy_pass http://sohyeon_backend;
    }
}
```

| 설정 | 의미 |
| --- | --- |
| `upstream sohyeon_backend` | 요청을 받을 앱 서버 3대를 하나의 이름으로 묶음 |
| `listen 18007` | 공용 Nginx의 18007번 포트에서 요청을 받음 |
| `location /`와 `proxy_pass` | 들어온 요청을 위에서 묶은 앱 서버로 전달 |

공용 서버를 여러 스터디원이 사용하므로, 내 서비스의 입구인 `18007`과 내 앱 서버들의 주소를 연결하는 설정이 필요하다.

### 포트 세 개의 차이

| 포트 | 위치 | 역할 |
| --- | --- | --- |
| `18007` | 공용 Nginx 서버 | 사용자가 접속하는 내 서비스 입구 |
| `20007` | 각 앱 서버 | 컨테이너로 연결되는 서버 측 입구 |
| `80` | 각 앱 컨테이너 내부 | 앱이 실제로 요청을 받는 포트 |

`docker run -p 20007:80`은 서버의 20007번 포트로 들어온 요청을 컨테이너 내부의 80번 포트로 연결한다는 뜻이다.

## 4. 접근만 하면 되는데 reload는 왜 필요한가?

설정 파일을 저장하는 것만으로는 실행 중인 Nginx에 새 설정이 적용되지 않는다. **Reload는 Nginx에 설정 파일을 다시 읽고 적용하도록 요청하는 작업**이다.

```text
① 설정 작성: 18007번 요청을 내 앱 서버 3대로 전달
② 설정 검사: nginx -t
③ reload: 실행 중인 Nginx에 설정 적용
④ 사용자 접근: 적용된 규칙대로 요청 전달
```

사용자가 접근할 때마다 reload하는 것은 아니다. 처음 전달 규칙을 추가하거나, 앱 서버 주소·포트 등 Nginx 설정을 변경할 때 필요하다.

앱 버전만 바꾸고 서버 주소·포트가 그대로라면 기존 전달 규칙을 계속 사용하므로 reload할 필요가 없다.

Reload는 서비스를 완전히 껐다 켜는 restart와 다르다. 정상적인 reload는 기존 연결을 처리하면서 새 설정을 적용한다. 다만 앱 컨테이너 교체 중 발생하는 서비스 공백까지 해결해 주는 것은 아니다.

## 5. nginx_lb Role은 실제로 어떤 작업을 하나?

관련 파일은 [tasks/main.yml](../ansible/roles/nginx_lb/tasks/main.yml), [templates/sohyeon.conf.j2](../ansible/roles/nginx_lb/templates/sohyeon.conf.j2), [handlers/main.yml](../ansible/roles/nginx_lb/handlers/main.yml)이다.

1. 템플릿을 공용 Nginx 서버의 `/etc/nginx/conf.d/sohyeon.conf`에 배치한다.
2. `nginx -t`로 설정을 검사한다.
3. 설정 파일이 변경되었고 검사가 성공하면 Handler가 Nginx를 reload한다.

```yaml
# tasks/main.yml: 설정 파일이 변경되면 Handler 실행을 예약
notify: Reload Nginx
```

```yaml
# handlers/main.yml: 예약된 설정 재적용 수행
- name: Reload Nginx
  ansible.builtin.service:
    name: nginx
    state: reloaded
  become: true
```

Jenkins에서는 `CONFIGURE_NGINX`를 선택한 경우에만 이 Role을 실행한다. 선택했더라도 파일 내용에 변경이 없다면 해당 task가 Handler를 호출하지 않는다. 처음 배포할 때는 이 옵션을 선택하거나, 필요한 Nginx 설정을 미리 적용해 두어야 한다.

## 6. 공용 Nginx의 reload 동시 실행을 왜 주의하나?

각자 자기 설정 파일을 수정하더라도 reload는 **공용 Nginx 전체 설정을 다시 읽는 작업**이다. 내 설정을 검사하는 사이 다른 사람이 설정을 바꾸면 검사한 상태와 실제 적용되는 상태가 달라질 수 있다. Reload가 겹친다고 반드시 장애가 발생한다는 뜻은 아니다.

현재 Jenkinsfile의 `disableConcurrentBuilds()`는 같은 Job의 중복 실행만 막는다. 다른 스터디원의 Job까지 막지는 않는다.

작업 시간을 공유해 순서를 맞추거나, 모든 관련 Pipeline이 같은 Jenkins 공용 잠금을 사용하도록 구성할 수 있다. 잠금을 도입한다면 reload만이 아니라 **설정 변경 → 검사 → reload 전체 구간**을 보호해야 한다. 현재 코드에는 스터디원 간 공용 잠금이 구현되어 있지 않다.

## 7. 앱은 어떻게 서버 3대에 배포되나?

[inventory.ini](../ansible/inventory.ini)에서 서버 3대를 `app_servers` 그룹으로 묶는다.

```ini
[app_servers]
sohyeon-app1 ansible_host=1.201.118.202
sohyeon-app2 ansible_host=1.201.118.10
sohyeon-app3 ansible_host=1.201.118.90
```

[deploy.yml](../ansible/deploy.yml)은 이 그룹에 `app` Role을 실행하도록 지정한다.

```yaml
- name: Deploy Sohyeon CI/CD application
  hosts: app_servers
  gather_facts: false
  roles:
    - role: app
```

Jenkins Agent에서 Ansible을 실행하면, Ansible이 SSH로 각 서버에 접속해서 같은 task를 수행한다. Task는 무엇을 할지 정의하고, `hosts`는 어느 서버에서 할지 정한다.

이미지는 Jenkins Agent에서 한 번 빌드한다. 별도 이미지 레지스트리 없이 `docker save`로 tar 파일로 저장하고, Ansible로 서버 3대에 복사한 뒤 각각 `docker load`로 등록한다. 같은 설치 파일을 여러 컴퓨터에 복사하는 것과 비슷하다.

## 8. app Role의 task는 어떤 순서로 실행되나?

[app/tasks/main.yml](../ansible/roles/app/tasks/main.yml)에 정의되어 있다.

| 순서 | 작업 |
| --- | --- |
| 1 | 이미지 tar 경로와 태그가 비어 있지 않은지 확인 |
| 2 | 각 앱 서버의 `/tmp`로 이미지 tar 복사 |
| 3 | `docker load`로 이미지 등록 |
| 4 | 같은 이름의 기존 컨테이너 조회 |
| 5 | 기존 컨테이너가 있으면 `docker rm -f`로 삭제 |
| 6 | 새 이미지로 컨테이너 실행, 버전과 `20007:80` 포트 설정 |
| 7 | `/health`의 HTTP 200과 `OK` 응답 확인, 실패 시 재시도 |
| 8 | `/version` 응답 조회 |
| 9 | 버전이 Jenkins에서 전달한 `v{빌드 번호}`와 일치하는지 검증 |
| 10 | 검증을 마치면 서버의 임시 이미지 tar 삭제 |

`register`는 결과 저장, `when`은 실행 조건, `until`은 재시도 종료 조건, `assert`는 조건 검증에 사용된다. `changed_when`은 변경 여부를 보고하는 기준이며 실행 여부를 결정하지 않는다.

현재는 서버 한 대의 배포를 모두 끝내고 다음 서버로 넘어가는 설정이 없다. 기본적으로 대상 서버들에서 현재 task를 수행하고 다음 task로 진행한다.

## 9. 기존 컨테이너는 왜, 언제 제거하나?

새 이미지를 가져오는 것만으로 실행 중인 컨테이너가 새 버전으로 바뀌지는 않는다. 새 이미지로 컨테이너를 만들어야 한다.

현재 코드는 기존 앱과 새 앱에 동일한 이름 `sohyeon-cicd-app`과 서버 포트 `20007`을 사용한다. 기존 컨테이너를 그대로 둔 채 새 컨테이너를 실행하면 이름이 충돌하고, 기존 앱이 실행 중이면 포트도 충돌한다. 따라서 기존 것을 먼저 삭제한다.

```text
v1 서비스 중
→ v2 이미지 전달·로드 (v1은 계속 실행 중)
→ v1 컨테이너 정지·삭제
→ v2 컨테이너 실행
→ 상태와 버전 검증
```

실제 교체 명령은 다음 두 task에 있다.

```yaml
- name: Remove existing Sohyeon container
  ansible.builtin.command:
    cmd: "docker rm -f {{ app_name }}"
  become: true
  when: existing_container.stdout | length > 0

- name: Run Sohyeon application container
  ansible.builtin.command:
    cmd: >
      docker run -d
      --name {{ app_name }}
      --restart unless-stopped
      -e APP_VERSION=v{{ image_tag }}
      -p {{ host_port }}:{{ container_port }}
      {{ image_name }}:{{ image_tag }}
  become: true
```

첫 배포라면 기존 컨테이너가 없으므로 삭제는 건너뛴다. 컨테이너를 삭제한다고 기존 이미지까지 삭제되는 것은 아니다.

기존 컨테이너를 삭제한 시점부터 새 앱이 준비될 때까지 서비스 공백이 생길 수 있다. Nginx가 있어도 세 서버의 앱을 비슷한 시점에 교체하면 무중단을 보장할 수 없다. 현재 코드는 새 버전 검증 실패 시 이전 버전을 자동으로 다시 실행하는 롤백도 구현하지 않았다.

이후에는 다른 이름·포트로 새 앱을 먼저 실행하고 검증한 뒤 Nginx의 전달 대상을 전환하는 방식 등을 검토할 수 있다. 이는 향후 확장 예시이며 현재 구현은 아니다.

## 10. become: true는 왜 공유하라고 하나?

`become: true`는 원격 서버에서 보통 sudo를 통해 관리자 권한으로 작업한다는 뜻이다. 현재 Docker 명령과 Nginx 설정 작업에 사용한다.

컨테이너 교체 명령은 본인 컨테이너를 대상으로 하지만, 공용 서버에서 관리자 권한을 사용하는 만큼 팀 운영 규칙에 따라 작업 범위를 공유하자는 취지다. 코드 자체가 사전 협의를 요구하는 것은 아니며, 실제 승인·협의 필요 여부는 스터디 규칙을 확인해야 한다.

## 11. 전체 실행 흐름

```text
Jenkins UI에서 실행
→ Agent 환경 확인
→ 이미지 빌드
→ 임시 컨테이너에서 상태·버전 테스트
→ 이미지 tar와 SSH 접속 정보 준비
→ deploy.yml: 앱 서버 3대 배포 및 서버별 검증
→ 선택한 경우 nginx.yml: 전달 설정 배치·검사·필요 시 reload
→ verify.yml: Nginx를 통한 상태·버전 검증
→ 성공·실패와 관계없이 Agent의 테스트 컨테이너와 임시 파일 정리
```

최종 검증은 로드밸런서 내부에서 `127.0.0.1:18007`로 요청한다. Nginx를 거친 앱 응답을 확인하는 것이며, 사용자 PC에서 외부 네트워크로 접속하는 경로까지 검증하는 것은 아니다. 서버 3대 각각의 상태·버전은 앞선 `app` Role에서 확인한다.
