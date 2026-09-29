#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Usage: stale-tags.sh <stale-after-days> <output-dir> < images.tsv
#
# Reads "file<TAB>image<TAB>lookup_image" lines on stdin and reports the tags
# whose latest image was built more than <stale-after-days> days ago. A tag
# that is no longer rebuilt has usually reached its end of life and won't get
# any more patches, so digestabot keeps pinning an outdated image.
#
# The build time is the `org.opencontainers.image.created` annotation of the
# manifest, or the `created` field of the image config. Images without a build
# time (or with a zero one, as reproducible builds often set) are ignored.
# Every tag is looked up once. Writes the result to <output-dir>:
#
#   stale-tags.json  one entry per stale tag, with the files that use it
#   stale-tags.md    the same as a markdown summary

set -o nounset -o pipefail

stale_after=${1:?usage: stale-tags.sh <stale-after-days> <output-dir>}
out_dir=${2:?usage: stale-tags.sh <stale-after-days> <output-dir>}
CRANE="${CRANE_PATH:-crane}"
NOW="${DIGESTABOT_NOW:-$(date +%s)}"

mkdir -p "${out_dir}"

# created <image:tag> prints the build time of the image, in seconds since the
# epoch, or nothing when it is unknown.
created() {
  local ref=$1 time
  time=$("${CRANE}" manifest "${ref}" | jq -r '.annotations["org.opencontainers.image.created"] // empty')
  if [ -z "${time}" ]; then
    time=$("${CRANE}" config "${ref}" | jq -r '.created // empty')
  fi
  [ -n "${time}" ] || return 0
  # before 2000 means a zeroed, reproducible build timestamp
  jq -rn --arg time "${time}" '$time | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch empty | select(. >= 946684800)'
}

# group the files per tag, so every tag is looked up once
jq -Rn '[inputs | split("\t") | select(length == 3) | {file: .[0], image: .[1], lookup_image: .[2]}]
  | group_by(.image, .lookup_image)
  | map({image: .[0].image, lookup_image: .[0].lookup_image, files: (map(.file) | unique)}) | .[]' -c |
  while read -r entry; do
    lookup_image=$(jq -r '.lookup_image' <<<"${entry}")
    time=$(created "${lookup_image}")
    if [ -z "${time}" ]; then
      echo "Build time of ${lookup_image} is unknown, skipping" >&2
      continue
    fi
    age=$(((NOW - time) / 86400))
    if [ "${age}" -gt "$((10#${stale_after}))" ]; then
      jq -c --argjson time "${time}" --argjson age "${age}" \
        '. + {created: ($time | todate), age_days: $age}' <<<"${entry}"
    fi
  done | jq -s . > "${out_dir}/stale-tags.json"

jq -r --arg days "$((10#${stale_after}))" '
  if length == 0 then empty else
    "These tags were not rebuilt in the last \($days) days. They may have reached their end of life and no longer receive patches; consider moving to a supported tag.\n\n" +
    "| Image | Last built | Files |\n|-------|------------|-------|\n" +
    (map("| `\(.image)` | \(.created[:10]) (\(.age_days) days ago) | \(.files | map("`\(.)`") | join(", ")) |\n") | join(""))
  end' "${out_dir}/stale-tags.json" > "${out_dir}/stale-tags.md"
