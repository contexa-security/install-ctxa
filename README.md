# Contexa CLI 설치기

이 저장소는 Contexa CLI 바이너리의 설치, 업데이트, 직전 버전 롤백과 제거만 담당합니다. 사용자 Spring 프로젝트를 변경하는 `contexa init`과 `contexa reset`은 별도 명령입니다.

## 지원 환경

| 운영체제 | CPU | 최소 환경 | 시험 채널 코드 서명 |
| --- | --- | --- | --- |
| Linux | x64 | glibc 2.28 이상 | unsigned |
| macOS | ARM64 | macOS 11 이상 | ad-hoc |
| Windows | x64 | Windows 10 이상 | unsigned |

Linux ARM64, Intel Mac, Windows ARM64용 바이너리는 배포하지 않습니다. 지원하지 않는 환경에서는 기존 CLI나 사용자 파일을 변경하기 전에 명확한 오류로 종료합니다.

## 안전한 최신 버전 설치

POSIX 셸은 외부 다운로드가 성공한 경우에만 설치기를 실행하고, 다운로드 또는 설치 실패 코드를 호출자에게 반환합니다.

```sh
installer="$(mktemp)" && curl -fsSL --connect-timeout 5 --max-time 30 https://install.ctxa.ai/install.sh -o "$installer" && sh "$installer"; status=$?; rm -f "$installer"; exit $status
```

PowerShell은 설치기 다운로드 실패를 종료 오류로 처리합니다.

```powershell
$ErrorActionPreference='Stop'; & ([scriptblock]::Create((Invoke-WebRequest https://install.ctxa.ai/install.ps1 -UseBasicParsing).Content))
```

## 고정 버전과 수명주기

- 변경되지 않는 버전별 설치기: `https://install.ctxa.ai/v0.1.2-phase1.1/install.sh` 또는 `install.ps1`
- 고정 CLI 릴리스 설치: `CONTEXA_VERSION=v0.1.2-phase1.1`
- 직전 정상 바이너리로 롤백: `CONTEXA_INSTALL_ACTION=rollback`
- CLI 바이너리 제거: `CONTEXA_INSTALL_ACTION=uninstall`
- 사용자 프로젝트 원복: `contexa reset` — CLI 제거와 다른 작업입니다.

동일 버전을 다시 실행하면 설치 바이너리를 교체하지 않습니다. 업데이트가 성공하면 직전 정상 바이너리를 `.previous`로 보존해 롤백 대상으로 사용합니다. 이전 경로에서 발견된 다른 `contexa` 바이너리는 자동으로 삭제하지 않고 경고만 출력합니다.

## 종료 코드

| 코드 | 의미 |
| ---: | --- |
| 0 | 신규 설치, 업데이트, 동일 버전 무변경, 롤백 또는 제거 성공 |
| 1 | 다운로드, 시간 초과, 서명, 해시, 권한, PATH, 실행 점검 또는 복구 실패 |

오류는 표준 오류 출력에 원인과 재시도 조치를 기록합니다. 비밀키나 인증정보는 출력하지 않습니다.
