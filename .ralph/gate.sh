#!/usr/bin/env bash
# .ralph/gate.sh — the repo's pass gate. A PRD task is checked off only
# after this exits 0, and every run integration re-runs it. Executable form
# of CONVENTIONS.md's "Lint / Format / Test Commands" — keep the two from
# drifting apart, and keep gate.ps1 behaviorally identical.
#
# The Rust and Docker-smoke checks are scoped exactly as CONVENTIONS.md
# already documents them: "required whenever agent-config/ changed" /
# "whenever backends/elastic/ changed". Scope is decided against this run's
# upstream (set by ralph.sh); with no upstream to diff against, run them.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

changed() {
  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || return 0
  ! git diff --quiet "$upstream"...HEAD -- "$1"
}

echo "-- compose validate --"
for f in backends/*/docker-compose.yml; do
  docker compose -f "$f" config -q
done

if changed agent-config/; then
  echo "-- rust fmt/clippy/test (agent-config/) --"
  cargo fmt    --manifest-path agent-config/Cargo.toml --check
  cargo clippy --manifest-path agent-config/Cargo.toml --all-targets
  cargo test   --manifest-path agent-config/Cargo.toml
fi

echo "-- shell lint --"
if command -v shfmt >/dev/null 2>&1; then
  find backends agents -name '*.sh' ! -name 'provision-standalone.sh' -print0 |
    xargs -0 -r shfmt -d
fi
if command -v shellcheck >/dev/null 2>&1; then
  find backends agents -name '*.sh' ! -name 'provision-standalone.sh' -print0 |
    xargs -0 -r shellcheck
fi

if changed backends/elastic/; then
  echo "-- backend smoke test (backends/elastic/) --"
  backends/elastic/smoke-test.sh
fi
