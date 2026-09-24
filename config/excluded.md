# Phase 2에서 제외한 프로젝트 (4개)

빌드 명령 정의 문제가 아니라 환경 또는 빌드 파이프라인 구조상
이 VM에서 완주하지 못한 항목이다. 추후 재시도 대상.

| dir | 실패 지점 | 원인 | 다음 시도 |
|---|---|---|---|
| cortex | protoc codegen | Makefile이 GOPATH 워크스페이스를 가정. 심볼릭 링크로 include path는 해결됐으나 protoc-gen-gogoslick 플러그인 부재 | go install protoc-gen-gogoslick |
| cilium | make all 내 precheck | gofmt 스타일 검사 실패. 컴파일과 무관 | 순수 빌드 타겟으로 변경 검토 |
| cert-manager | helm chart 패키징 | shallow clone이라 semver 태그가 없어 chart version이 무효 | full clone 또는 바이너리 타겟으로 변경 |
| policy | goreleaser 실행 | .ext/bin/goreleaser 다운로드 실패 | goreleaser 사전 설치 |

## build_cmd 를 순수 빌드 타겟으로 좁힌 프로젝트

기본 타겟이 컴파일 외 단계(lint, 컨테이너 이미지 패키징)를 포함하여
호스트 레벨 관측 대상이 아니거나 이 환경에서 완주하지 못한 경우,
Makefile 에 명시적으로 존재하는 순수 빌드 타겟으로 변경했다.

| project | 기존 | 변경 | 사유 |
|---|---|---|---|
| Cortex | make BUILD_IN_CONTAINER=false | make BUILD_IN_CONTAINER=false dist | 기본 타겟이 Docker 빌드 이미지 생성을 포함 (build-image/.uptodate) |
| cilium | make all | make build | all = precheck + build + postcheck. precheck 는 gofmt 스타일 검사로 컴파일과 무관 |
