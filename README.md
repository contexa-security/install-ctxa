# Contexa CLI installer

Installs, updates and removes the `contexa` command. Adding Contexa to a Spring Boot application
is done afterwards by `contexa init` ([contexa-cli](https://github.com/contexa-security/contexa-cli)).

## Install

Linux / macOS:

```sh
curl -fsSL https://install.ctxa.ai | sh
```

Windows (PowerShell 5.1 or 7):

```powershell
irm https://install.ctxa.ai/install.ps1 | iex
```

Then, in your Spring Boot project:

```sh
contexa init
```

The installer prints that next step, and when the current terminal cannot see the new command yet,
the one line that makes it available (`export PATH=...`). New terminals find it on their own:
the installer adds the folder to `~/.profile`, `~/.bashrc`, `~/.zshrc` (and fish) on Linux/macOS,
and to the user `Path` on Windows.

| Platform | Binary | Installed to |
|---|---|---|
| Linux x64 (glibc 2.28+) | `contexa-linux-x64` | `/usr/local/bin` when writable, otherwise `~/.local/bin` |
| macOS Apple Silicon (11+) | `contexa-macos-arm64` | `/usr/local/bin` when writable, otherwise `~/.local/bin` |
| Windows x64 (10+) | `contexa-win-x64.exe` | `%LOCALAPPDATA%\Programs\Contexa` |

Other platforms stop with a clear message before anything is changed.

## What is verified

The installer reads the signed snapshot channel, checks its RSA signature, then the signed release
manifest it points to, and finally the SHA-256 of the binary. The new binary has to start and
report the expected version before it replaces the old one; on any failure the previous binary is
kept.

## Other actions

| Action | Linux / macOS | Windows |
|---|---|---|
| Install a specific release | `CONTEXA_VERSION=v0.2.0 sh install.sh` | `$env:CONTEXA_VERSION='v0.2.0'; .\install.ps1` |
| Go back to the previous binary | `sh install.sh rollback` | `.\install.ps1 -Action rollback` |
| Uninstall | `curl -fsSL https://install.ctxa.ai/uninstall.sh \| sh` | `irm https://install.ctxa.ai/uninstall.ps1 \| iex` |
| Install somewhere else | `CONTEXA_INSTALL_DIR=/opt/contexa/bin` | `$env:CONTEXA_INSTALL_DIR='D:\tools'` |

Uninstalling removes only the command. To remove Contexa from a project, run `contexa reset` in
that project first.

Exit code 0 means success (including "already installed"); 1 means the reason was printed on
standard error together with what to do.

---

# Contexa CLI 설치 프로그램 (한국어)

`contexa` 명령을 설치·업데이트·제거합니다. Spring Boot 앱에 Contexa를 붙이는 일은 설치 뒤에
`contexa init`이 합니다.

## 설치

Linux / macOS:

```sh
curl -fsSL https://install.ctxa.ai | sh
```

Windows (PowerShell 5.1 또는 7):

```powershell
irm https://install.ctxa.ai/install.ps1 | iex
```

그다음 Spring Boot 프로젝트 폴더에서:

```sh
contexa init
```

설치가 끝나면 다음 단계를 알려 주고, 지금 터미널이 새 명령을 아직 모르면 바로 쓸 수 있는 한 줄
(`export PATH=...`)도 알려 줍니다. 새 터미널은 따로 할 일이 없습니다. Linux/macOS는
`~/.profile`, `~/.bashrc`, `~/.zshrc`(그리고 fish)에, Windows는 사용자 `Path`에 폴더를 추가합니다.

| 플랫폼 | 바이너리 | 설치 위치 |
|---|---|---|
| Linux x64 (glibc 2.28 이상) | `contexa-linux-x64` | 쓸 수 있으면 `/usr/local/bin`, 아니면 `~/.local/bin` |
| macOS Apple Silicon (11 이상) | `contexa-macos-arm64` | 쓸 수 있으면 `/usr/local/bin`, 아니면 `~/.local/bin` |
| Windows x64 (10 이상) | `contexa-win-x64.exe` | `%LOCALAPPDATA%\Programs\Contexa` |

그 밖의 플랫폼은 아무것도 바꾸기 전에 이유를 알리고 멈춥니다.

## 검증하는 것

서명된 snapshot 채널과 그 RSA 서명, 채널이 가리키는 서명된 릴리스 매니페스트, 바이너리의 SHA-256을
차례로 확인합니다. 새 바이너리가 실제로 실행되어 기대한 버전을 보고해야 기존 바이너리를 바꾸며,
어느 단계에서 실패해도 기존 바이너리는 그대로 남습니다.

## 그 밖의 작업

| 작업 | Linux / macOS | Windows |
|---|---|---|
| 특정 릴리스 설치 | `CONTEXA_VERSION=v0.2.0 sh install.sh` | `$env:CONTEXA_VERSION='v0.2.0'; .\install.ps1` |
| 직전 바이너리로 되돌리기 | `sh install.sh rollback` | `.\install.ps1 -Action rollback` |
| 제거 | `curl -fsSL https://install.ctxa.ai/uninstall.sh \| sh` | `irm https://install.ctxa.ai/uninstall.ps1 \| iex` |
| 다른 위치에 설치 | `CONTEXA_INSTALL_DIR=/opt/contexa/bin` | `$env:CONTEXA_INSTALL_DIR='D:\tools'` |

제거는 명령만 지웁니다. 프로젝트에서 Contexa를 빼려면 먼저 그 프로젝트에서 `contexa reset`을
실행하세요.

종료 코드 0은 성공("이미 설치됨" 포함), 1은 실패이며 원인과 할 일을 표준 오류로 출력합니다.
