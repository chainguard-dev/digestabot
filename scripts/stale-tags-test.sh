#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Tests for stale-tags.sh, using a fake crane that serves manifest and config
# fixtures.

set -o errexit -o nounset -o pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stale-tags.sh"
fixtures=$(mktemp -d)
trap 'rm -rf "${fixtures}"' EXIT
mkdir -p "${fixtures}/manifest" "${fixtures}/config"

# The fake crane answers `manifest <ref>` and `config <ref>` from ${fixtures},
# fails for unknown refs, and logs every call.
cat > "${fixtures}/crane" <<EOF
#!/usr/bin/env bash
set -o errexit -o nounset
echo "\$*" >> "${fixtures}/calls"
file="${fixtures}/\$1/\$(printf '%s' "\$2" | tr '/:' '__')"
[ -f "\${file}" ] || { echo "MANIFEST_UNKNOWN: \$2" >&2; exit 1; }
cat "\${file}"
EOF
chmod +x "${fixtures}/crane"
export CRANE_PATH="${fixtures}/crane"
# 2026-09-29T00:00:00Z
export DIGESTABOT_NOW=1790640000

# fixture <manifest|config> <ref> <json> serves <json> for <ref>.
fixture() {
  printf '%s' "$3" > "${fixtures}/$1/$(printf '%s' "$2" | tr '/:' '__')"
}

# annotated: fresh and stale build times in the manifest annotations
fixture manifest cgr.dev/org/fresh:1 '{"annotations": {"org.opencontainers.image.created": "2026-09-20T10:00:00Z"}}'
fixture manifest cgr.dev/org/old:1 '{"annotations": {"org.opencontainers.image.created": "2026-07-01T10:00:00.123Z"}}'
# no annotations: the config build time is used
fixture manifest docker.io/library/old:1 '{"schemaVersion": 2}'
fixture config docker.io/library/old:1 '{"created": "2026-08-01T00:00:00Z"}'
# zeroed reproducible build timestamp
fixture manifest ghcr.io/org/ko:1 '{"schemaVersion": 2}'
fixture config ghcr.io/org/ko:1 '{"created": "0001-01-01T00:00:00Z"}'
# registry-map: the upstream image is looked up
fixture manifest cgr.dev/org/mapped:1 '{"annotations": {"org.opencontainers.image.created": "2026-06-01T00:00:00Z"}}'

out="${fixtures}/out"
printf '%s\t%s\t%s\n' \
  a.yaml cgr.dev/org/fresh:1 cgr.dev/org/fresh:1 \
  a.yaml cgr.dev/org/old:1 cgr.dev/org/old:1 \
  b/Dockerfile cgr.dev/org/old:1 cgr.dev/org/old:1 \
  a.yaml cgr.dev/org/old:1 cgr.dev/org/old:1 \
  a.yaml docker.io/library/old:1 docker.io/library/old:1 \
  a.yaml ghcr.io/org/ko:1 ghcr.io/org/ko:1 \
  a.yaml ghcr.io/org/missing:1 ghcr.io/org/missing:1 \
  a.yaml proxy.example/cgr/org/mapped:1 cgr.dev/org/mapped:1 |
  "${script}" 30 "${out}" 2> "${fixtures}/stderr"

failures=0

# check <name> <jq filter> checks that <filter> is true for stale-tags.json.
check() {
  if jq -e "$2" "${out}/stale-tags.json" > /dev/null; then
    echo "ok: $1"
  else
    echo "FAIL: $1: $(cat "${out}/stale-tags.json")"
    failures=$((failures + 1))
  fi
}

check "reports only the stale tags" '[.[].image] == ["cgr.dev/org/old:1", "docker.io/library/old:1", "proxy.example/cgr/org/mapped:1"]'
check "lists every file using a stale tag once" '.[0].files == ["a.yaml", "b/Dockerfile"]'
check "uses the manifest annotation" '.[0].created == "2026-07-01T10:00:00Z" and .[0].age_days == 89'
check "falls back to the config build time" '.[1].created == "2026-08-01T00:00:00Z" and .[1].age_days == 59'
check "looks up the upstream image" '.[2].lookup_image == "cgr.dev/org/mapped:1" and .[2].age_days == 120'

if [ "$(grep -c '^manifest cgr.dev/org/old:1$' "${fixtures}/calls")" = 1 ]; then
  echo "ok: looks up every tag once"
else
  echo "FAIL: looks up every tag once: $(cat "${fixtures}/calls")"
  failures=$((failures + 1))
fi

for image in ghcr.io/org/ko:1 ghcr.io/org/missing:1; do
  if grep -q "Build time of ${image} is unknown" "${fixtures}/stderr"; then
    echo "ok: skips ${image} with an unknown build time"
  else
    echo "FAIL: skips ${image} with an unknown build time: $(cat "${fixtures}/stderr")"
    failures=$((failures + 1))
  fi
done

# shellcheck disable=SC2016 # literal backticks of the markdown
if grep -q '| `cgr.dev/org/old:1` | 2026-07-01 (89 days ago) | `a.yaml`, `b/Dockerfile` |' "${out}/stale-tags.md"; then
  echo "ok: writes the markdown summary"
else
  echo "FAIL: writes the markdown summary: $(cat "${out}/stale-tags.md")"
  failures=$((failures + 1))
fi

printf '%s\t%s\t%s\n' a.yaml cgr.dev/org/fresh:1 cgr.dev/org/fresh:1 | "${script}" 30 "${out}" 2> /dev/null
if [ "$(cat "${out}/stale-tags.json")" = "[]" ] && [ ! -s "${out}/stale-tags.md" ]; then
  echo "ok: writes empty results without stale tags"
else
  echo "FAIL: writes empty results without stale tags"
  failures=$((failures + 1))
fi

if [ "${failures}" -gt 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi
