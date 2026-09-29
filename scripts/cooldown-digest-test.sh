#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Tests for cooldown-digest.sh, using a fake crane and curl that serve a tag
# history fixture.

set -o errexit -o nounset -o pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cooldown-digest.sh"
fixtures=$(mktemp -d)
trap 'rm -rf "${fixtures}"' EXIT

cat > "${fixtures}/crane" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "auth token" ] || { echo "unexpected crane call: $*" >&2; exit 1; }
echo '{"token": "fake-token"}'
EOF

# The fake curl serves ${fixtures}/history for the history of
# cgr.dev/chainguard/static:latest and fails for any other URL.
cat > "${fixtures}/curl" <<EOF
#!/usr/bin/env bash
[ "\${*: -1}" = "https://cgr.dev/v2/chainguard/static/_chainguard/history/latest" ] || exit 22
cat "${fixtures}/history"
EOF
chmod +x "${fixtures}/crane" "${fixtures}/curl"
export CRANE_PATH="${fixtures}/crane" PATH="${fixtures}:${PATH}"

# Unsorted, with and without fractional seconds.
cat > "${fixtures}/history" <<'EOF'
{"history": [
  {"updateTimestamp": "2026-09-20T00:00:00.123Z", "digest": "sha256:d20"},
  {"updateTimestamp": "2026-09-10T00:00:00Z", "digest": "sha256:d10"},
  {"updateTimestamp": "2026-09-28T00:00:00.5Z", "digest": "sha256:d28"},
  {"updateTimestamp": "2026-09-25T00:00:00Z", "digest": "sha256:d25"}
]}
EOF
# 2026-09-29T00:00:00Z
export DIGESTABOT_NOW=1790640000

failures=0

# expect <name> <expected output> <args>... checks that the script succeeds and
# prints <expected output>.
expect() {
  local name=$1 want=$2 got
  shift 2
  if got=$("${script}" "$@" 2>&1) && [ "${got}" = "${want}" ]; then
    echo "ok: ${name}"
  else
    echo "FAIL: ${name}: want ${want}, got ${got}"
    failures=$((failures + 1))
  fi
}

# expect_error <name> <expected message> <args>... checks that the script fails
# with <expected message> on stderr.
expect_error() {
  local name=$1 want=$2 got
  shift 2
  if got=$("${script}" "$@" 2>&1); then
    echo "FAIL: ${name}: want an error, got ${got}"
    failures=$((failures + 1))
  elif [[ "${got}" != *"${want}"* ]]; then
    echo "FAIL: ${name}: want ${want}, got ${got}"
    failures=$((failures + 1))
  else
    echo "ok: ${name}"
  fi
}

img=cgr.dev/chainguard/static:latest
expect "no cooldown picks the latest digest" sha256:d28 "${img}" sha256:d10 0
expect "picks the latest digest old enough" sha256:d25 "${img}" sha256:d10 3
expect "the cutoff is inclusive" sha256:d20 "${img}" sha256:d10 9
expect "keeps the current digest when it is the one picked" sha256:d20 "${img}" sha256:d20 5
expect "never downgrades a newer pin" sha256:d28 "${img}" sha256:d28 5
expect "updates a pin unknown to the history" sha256:d25 "${img}" sha256:unknown 3
expect_error "no digest old enough" "no digest of ${img} is older than 30 days" "${img}" sha256:d10 30
expect_error "not a cgr.dev image" "only supported for cgr.dev images" ghcr.io/foo/bar:latest sha256:d10 3
expect_error "history not available" "failed to fetch the tag history" cgr.dev/chainguard/static:other sha256:d10 3

if [ "${failures}" -gt 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi
