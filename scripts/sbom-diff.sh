#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Reads "image<TAB>lookup_image<TAB>old_digest<TAB>new_digest" lines on stdin
# and prints a markdown summary of the APK package changes between the old and
# new digest of each image, based on the SPDX SBOM attestations published next
# to the image (the cosign `sha256-<digest>.att` tag).
#
# Images without an SBOM (or whose SBOM can't be fetched) are listed as such,
# the script never fails because of them.

set -o nounset -o pipefail

CRANE="${CRANE_PATH:-crane}"
PLATFORM="${SBOM_PLATFORM:-linux/amd64}"
SPDX_PREDICATE="https://spdx.dev/Document"

# packages <repo> <digest> prints "name version" for every APK in the SBOM of
# the <digest> image for ${PLATFORM}.
packages() {
  local repo=$1 digest=$2 layer
  digest=$("${CRANE}" digest --platform="${PLATFORM}" "${repo}@${digest}") || return 1
  layer=$("${CRANE}" manifest "${repo}:${digest/:/-}.att" |
    jq -r --arg type "${SPDX_PREDICATE}" '[.layers[] | select(.annotations.predicateType == $type)][0].digest // empty') || return 1
  [ -n "${layer}" ] || return 1
  "${CRANE}" blob "${repo}@${layer}" | jq -r '.payload' | base64 -d |
    jq -r '.predicate.packages[] | select(any(.externalRefs[]?; .referenceLocator | startswith("pkg:apk/"))) | "\(.name) \(.versionInfo)"' |
    sort -u
}

# changes <old> <new> prints a markdown table row for every package whose
# version differs between the two "name version" lists.
changes() {
  awk '
    FNR == NR { old[$1] = ($1 in old) ? old[$1] ", " $2 : $2; names[$1]; next }
    { new[$1] = ($1 in new) ? new[$1] ", " $2 : $2; names[$1] }
    END {
      for (p in names) {
        o = (p in old) ? old[p] : "-"
        n = (p in new) ? new[p] : "-"
        if (o != n) printf "| %s | %s | %s |\n", p, o, n
      }
    }' "$1" "$2" | sort
}

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

sort -u | while IFS=$'\t' read -r image lookup_image old new; do
  [ -n "${new}" ] || continue
  repo="${lookup_image%:*}"

  if ! packages "${repo}" "${old}" > "${tmp}/old" || ! packages "${repo}" "${new}" > "${tmp}/new" ||
    [ ! -s "${tmp}/old" ] || [ ! -s "${tmp}/new" ]; then
    echo "SBOM not available for ${image} (${old} -> ${new}), skipping" >&2
    echo "- \`${image}\`: SBOM not available"
    continue
  fi

  changes "${tmp}/old" "${tmp}/new" > "${tmp}/rows"
  count=$(wc -l < "${tmp}/rows" | tr -d ' ')

  if [ "${count}" -eq 0 ]; then
    echo "- \`${image}\`: no package changes"
    continue
  fi

  echo "<details>"
  echo "<summary><code>${image}</code>: ${count} package change(s)</summary>"
  echo
  echo "| Package | Old | New |"
  echo "|---------|-----|-----|"
  cat "${tmp}/rows"
  echo
  echo "</details>"
  echo
done
