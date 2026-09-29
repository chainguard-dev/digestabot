#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Usage: sbom-diff.sh <output-dir> < updates.tsv
#
# Reads "image<TAB>lookup_image<TAB>old_digest<TAB>new_digest" lines on stdin
# and compares the APK packages of the old and new digest of each image, based
# on the SPDX SBOM attestations published next to the image (the cosign
# `sha256-<digest>.att` tag). Writes the result to <output-dir>:
#
#   sbom-diff.json  one entry per image with the changed packages
#   sbom-diff.md    the same as a markdown summary
#
# Updates of the same image and digests are compared once, and the SBOM of a
# digest is fetched once. Images without an SBOM (or whose SBOM can't be
# fetched) are reported as such, the script never fails because of them.

set -o nounset -o pipefail

out_dir=${1:?usage: sbom-diff.sh <output-dir>}
CRANE="${CRANE_PATH:-crane}"
PLATFORM="${SBOM_PLATFORM:-linux/amd64}"
SPDX_PREDICATE="https://spdx.dev/Document"

tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${out_dir}" "${tmp}/cache"

# fetch_packages <repo> <digest> prints "name version" for every APK in the
# SBOM of the <digest> image for ${PLATFORM}.
fetch_packages() {
  local repo=$1 digest=$2 layer
  digest=$("${CRANE}" digest --platform="${PLATFORM}" "${repo}@${digest}") || return 1
  layer=$("${CRANE}" manifest "${repo}:${digest/:/-}.att" |
    jq -r --arg type "${SPDX_PREDICATE}" '[.layers[] | select(.annotations.predicateType == $type)][0].digest // empty') || return 1
  [ -n "${layer}" ] || return 1
  "${CRANE}" blob "${repo}@${layer}" | jq -r '.payload' | base64 -d |
    jq -r '.predicate.packages[] | select(any(.externalRefs[]?; .referenceLocator | startswith("pkg:apk/"))) | "\(.name) \(.versionInfo)"' |
    sort -u
}

# packages <repo> <digest> is fetch_packages, cached per image digest. It fails
# when the image has no SBOM.
packages() {
  local cache
  cache="${tmp}/cache/$(printf '%s@%s' "$1" "$2" | tr -c 'A-Za-z0-9._-' '_')"
  if [ ! -e "${cache}" ]; then
    fetch_packages "$1" "$2" > "${cache}.tmp" || : > "${cache}.tmp"
    mv "${cache}.tmp" "${cache}"
  fi
  [ -s "${cache}" ] && cat "${cache}"
}

# changes <old> <new> prints "name<TAB>old version<TAB>new version" for every
# package whose version differs between the two "name version" lists, with an
# empty version for added and removed packages.
changes() {
  awk '
    FNR == NR { old[$1] = ($1 in old) ? old[$1] ", " $2 : $2; names[$1]; next }
    { new[$1] = ($1 in new) ? new[$1] ", " $2 : $2; names[$1] }
    END {
      for (p in names) {
        o = (p in old) ? old[p] : ""
        n = (p in new) ? new[p] : ""
        if (o != n) printf "%s\t%s\t%s\n", p, o, n
      }
    }' "$1" "$2" | sort
}

awk -F '\t' 'NF == 4 && !seen[$2 FS $3 FS $4]++' | while IFS=$'\t' read -r image lookup_image old new; do
  repo="${lookup_image%:*}"
  sbom=true
  if packages "${repo}" "${old}" > "${tmp}/old" && packages "${repo}" "${new}" > "${tmp}/new"; then
    changes "${tmp}/old" "${tmp}/new" > "${tmp}/rows"
  else
    echo "SBOM not available for ${image} (${old} -> ${new}), skipping" >&2
    sbom=false
    : > "${tmp}/rows"
  fi
  jq -Rn --arg image "${image}" --arg lookup_image "${lookup_image}" --arg digest "${old}" \
    --arg updated_digest "${new}" --argjson sbom "${sbom}" \
    '{image: $image, lookup_image: $lookup_image, digest: $digest, updated_digest: $updated_digest, sbom: $sbom,
      changes: [inputs | split("\t") | map(if . == "" then null else . end) | {package: .[0], version: .[1], updated_version: .[2]}]}' \
    < "${tmp}/rows"
done | jq -s . > "${out_dir}/sbom-diff.json"

jq -r '.[] |
  if (.sbom | not) then "- `\(.image)`: SBOM not available\n"
  elif (.changes | length) == 0 then "- `\(.image)`: no package changes\n"
  else
    "<details>\n<summary><code>\(.image)</code>: \(.changes | length) package change(s)</summary>\n\n" +
    "| Package | Old | New |\n|---------|-----|-----|\n" +
    (.changes | map("| \(.package) | \(.version // "-") | \(.updated_version // "-") |\n") | join("")) +
    "\n</details>\n"
  end' "${out_dir}/sbom-diff.json" > "${out_dir}/sbom-diff.md"
