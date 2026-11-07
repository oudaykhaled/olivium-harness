#!/bin/sh
# Run ONLY as the fixed entrypoint in the existing qualified no-network grader.
# Both /candidate and /protected are read-only mounts. Never run on the host.
set -eu
umask 077
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOENV=off CGO_ENABLED=0 GOWORK=off
export GOFLAGS= GOCACHE=/tmp/go-cache GOMODCACHE=/tmp/go-mod GOPATH=/tmp/go-path
fail() {
  printf '[grader_failure stage=%s exit=%s]\n' "$2" "$1"
  printf '[grader_log_begin: UTF-8; invalid bytes omitted]\n'
  if LC_ALL=C awk '
    BEGIN { remaining = 60000 }
    {
      size = length($0) + 1
      if (size > remaining) {
        print "[grader_log_truncated: 60000-byte complete-line limit]"
        exit
      }
      print
      remaining -= size
    }
  ' "$3" >/tmp/grader-failure-bounded.log 2>/dev/null &&
    iconv -f UTF-8 -t UTF-8 -c /tmp/grader-failure-bounded.log 2>/dev/null; then
    :
  else
    printf '\n[grader_log_unavailable]\n'
  fi
  printf '[grader_log_end]\n'
  exit "$1"
}
cd /tmp
go build -o /tmp/ast-guard /protected/ast_guard.go >/tmp/guard-build-log 2>&1 || fail 43 ast_guard_build /tmp/guard-build-log
go build -o /tmp/verify-events /protected/verify_events.go >/tmp/events-build-log 2>&1 || fail 43 test_event_verifier_build /tmp/events-build-log
/tmp/ast-guard /candidate/utility.go /protected/base_utility.go
mkdir -p /tmp/task/cmd/probe
cp /candidate/utility.go /tmp/task/utility.go
cp /protected/go.mod /tmp/task/go.mod
cp /protected/utility_test.go /tmp/task/utility_test.go
cp /protected/main.go /tmp/task/cmd/probe/main.go
cd /tmp/task
go test -json -count=1 -timeout=10s . >/tmp/test-events.json 2>&1 || fail 41 protected_tests /tmp/test-events.json
/tmp/verify-events /tmp/test-events.json
go build -o /tmp/probe ./cmd/probe >/tmp/probe-build-log 2>&1 || fail 42 probe_build /tmp/probe-build-log
exec /tmp/probe /tmp/test-events.json
