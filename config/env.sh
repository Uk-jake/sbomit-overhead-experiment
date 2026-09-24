# witness overhead experiment 공통 환경
# sudo -i 진입 후 source 해서 사용

export EXP_ROOT=/home/jake/sbomit-overhead-experiment

# HOME을 jake로 되돌림
# rust(~/.cargo), node(~/.npm), maven(~/.m2)이 홈 기반 경로를 쓰기 때문
export HOME=/home/jake

# toolchain 경로 명시 (Step 1에서 확인된 값으로 조정할 것)
export PATH=/usr/local/go/bin:/home/jake/go/bin:/home/jake/.cargo/bin:/home/jake/.nvm/versions/node/v20.20.2/bin:/opt/maven/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 실험 전용 캐시. jake 홈의 기존 캐시와 격리해서 cold 정책을 정확히 제어
# export GOMODCACHE=$EXP_ROOT/work/modcache
# export GOCACHE=$EXP_ROOT/work/buildcache
# export GOTMPDIR=$EXP_ROOT/work/tmp
# export GOPATH=$EXP_ROOT/work/gopath

export WITNESS_KEY=$EXP_ROOT/config/keys/testkey.pem

# (캐시는 Go 기본 경로 사용)
