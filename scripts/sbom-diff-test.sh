#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Tests for sbom-diff.sh, using a fake crane that serves SBOM fixtures.

set -o errexit -o nounset -o pipefail

script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sbom-diff.sh"
fixtures=$(mktemp -d)
trap 'rm -rf "${fixtures}"' EXIT
mkdir -p "${fixtures}/att" "${fixtures}/blobs" "${fixtures}/index"

# The fake crane answers `digest --platform=<p> <ref>`, `manifest <repo>:<tag>`
# and `blob <repo>@<digest>` from ${fixtures}, and logs every call.
cat > "${fixtures}/crane" <<EOF
#!/usr/bin/env bash
set -o errexit -o nounset
echo "\$*" >> "${fixtures}/calls"
case "\$1" in
  digest)
    platform="\${2#--platform=}"
    digest="\${3#*@}"
    index="${fixtures}/index/\${digest}/\${platform//\//-}"
    if [ -f "\${index}" ]; then cat "\${index}"; else echo "\${digest}"; fi
    ;;
  manifest)
    att="${fixtures}/att/\${2##*:}"
    [ -f "\${att}" ] || { echo "MANIFEST_UNKNOWN: \$2" >&2; exit 1; }
    cat "\${att}"
    ;;
  blob)
    cat "${fixtures}/blobs/\${2#*@}"
    ;;
  *)
    echo "unexpected crane call: \$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${fixtures}/crane"
export CRANE_PATH="${fixtures}/crane"

# sbom <digest> <name@version>... publishes an SPDX attestation for <digest>
# listing the given APKs, plus a non-APK package (whose version changes with
# every digest) that must be ignored.
sbom() {
  local digest=$1 layer="${1}-sbom"
  shift
  jq -n '{predicate: {packages: (
      [$ARGS.positional[] | split("@") | {name: .[0], versionInfo: .[1], externalRefs: [{referenceLocator: "pkg:apk/wolfi/\(.[0])@\(.[1])?arch=x86_64"}]}]
      + [{name: "wolfi-baselayout.yaml", versionInfo: $digest, externalRefs: [{referenceLocator: "pkg:github/chainguard-dev/stereo@\($digest)"}]}]
    )}}' --arg digest "${digest}" --args "$@" |
    jq -n --arg payload "$(base64 | tr -d '\n')" '{payloadType: "application/vnd.in-toto+json", payload: $payload}' \
      > "${fixtures}/blobs/${layer}"
  jq -n --arg layer "${layer}" '{layers: [
      {digest: "sha256:provenance", annotations: {predicateType: "https://slsa.dev/provenance/v1"}},
      {digest: $layer, annotations: {predicateType: "https://spdx.dev/Document"}}
    ]}' > "${fixtures}/att/${digest/:/-}.att"
}

# index <digest> <platform> <platform digest> makes <digest> an image index.
index() {
  mkdir -p "${fixtures}/index/${1}"
  echo "$3" > "${fixtures}/index/${1}/${2//\//-}"
}

failures=0
out=

# run <description> <image> <lookup image> <old> <new> runs sbom-diff.sh on a single update.
run() {
  echo "=== $1"
  : > "${fixtures}/calls"
  out=$(printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" | "${script}")
  echo "${out}"
}

expect() {
  if ! grep -qxF -- "$1" <<<"${out}"; then
    echo "FAIL: expected line: $1"
    failures=$((failures + 1))
  fi
}

expect_not() {
  if grep -qF -- "$1" <<<"${out}"; then
    echo "FAIL: unexpected: $1"
    failures=$((failures + 1))
  fi
}

sbom sha256:old busybox@1.36.0-r0 glibc@2.42-r0 zlib@1.3-r0
sbom sha256:new busybox@1.36.1-r0 glibc-2.44@2.44-r0 zlib@1.3-r0
sbom sha256:rebuilt busybox@1.36.1-r0 glibc-2.44@2.44-r0 zlib@1.3-r0

run "changed, added and removed packages" cgr.dev/chainguard/busybox:latest cgr.dev/chainguard/busybox:latest sha256:old sha256:new
expect "<summary><code>cgr.dev/chainguard/busybox:latest</code>: 3 package change(s)</summary>"
expect "| busybox | 1.36.0-r0 | 1.36.1-r0 |"
expect "| glibc | 2.42-r0 | - |"
expect "| glibc-2.44 | - | 2.44-r0 |"
expect_not "zlib"
expect_not "wolfi-baselayout.yaml"

run "no package changes" cgr.dev/chainguard/busybox:latest cgr.dev/chainguard/busybox:latest sha256:new sha256:rebuilt
expect "- \`cgr.dev/chainguard/busybox:latest\`: no package changes"
expect_not "<details>"

run "missing SBOM" docker.io/library/alpine:3.20 docker.io/library/alpine:3.20 sha256:unknown sha256:new
expect "- \`docker.io/library/alpine:3.20\`: SBOM not available"
expect_not "<details>"

index sha256:old-index linux/amd64 sha256:old
index sha256:old-index linux/arm64 sha256:new
index sha256:new-index linux/amd64 sha256:new
index sha256:new-index linux/arm64 sha256:rebuilt
run "image index uses the linux/amd64 SBOM by default" cgr.dev/chainguard/busybox:latest cgr.dev/chainguard/busybox:latest sha256:old-index sha256:new-index
expect "| busybox | 1.36.0-r0 | 1.36.1-r0 |"

SBOM_PLATFORM=linux/arm64 run "image index uses the sbom-platform SBOM" cgr.dev/chainguard/busybox:latest cgr.dev/chainguard/busybox:latest sha256:old-index sha256:new-index
expect "- \`cgr.dev/chainguard/busybox:latest\`: no package changes"

run "registry-map lookups use the upstream repository" us-docker.pkg.dev/proxy/chainguard/busybox:latest cgr.dev/chainguard/busybox:latest sha256:old sha256:new
expect "<summary><code>us-docker.pkg.dev/proxy/chainguard/busybox:latest</code>: 3 package change(s)</summary>"
if grep -q 'us-docker.pkg.dev' "${fixtures}/calls" || ! grep -qxF 'manifest cgr.dev/chainguard/busybox:sha256-old.att' "${fixtures}/calls"; then
  echo "FAIL: crane was not called with the upstream repository"
  cat "${fixtures}/calls"
  failures=$((failures + 1))
fi

run "registry with a port" localhost:5000/busybox:latest localhost:5000/busybox:latest sha256:old sha256:new
if ! grep -qxF 'manifest localhost:5000/busybox:sha256-old.att' "${fixtures}/calls"; then
  echo "FAIL: repository with a registry port was not parsed correctly"
  cat "${fixtures}/calls"
  failures=$((failures + 1))
fi

echo "=== duplicate updates are reported once"
out=$(printf '%s\t%s\t%s\t%s\n' \
  cgr.dev/chainguard/busybox:latest cgr.dev/chainguard/busybox:latest sha256:old sha256:new \
  cgr.dev/chainguard/busybox:latest cgr.dev/chainguard/busybox:latest sha256:old sha256:new | "${script}")
if [ "$(grep -c '^<details>$' <<<"${out}")" -ne 1 ]; then
  echo "FAIL: duplicate update reported more than once"
  failures=$((failures + 1))
fi

echo "=== no updates"
out=$("${script}" < /dev/null)
if [ -n "${out}" ]; then
  echo "FAIL: expected no output without updates"
  failures=$((failures + 1))
fi

if [ "${failures}" -ne 0 ]; then
  echo "${failures} failure(s)"
  exit 1
fi
echo "All tests passed"
