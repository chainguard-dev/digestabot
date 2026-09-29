#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Usage: cooldown-digest.sh <image:tag> <current-digest> <min-age-days>
#
# Prints the most recent digest of a cgr.dev <image:tag> that is at least
# <min-age-days> days old, based on the tag history of the Chainguard registry
# (`/v2/<repo>/_chainguard/history/<tag>`). This keeps digestabot from
# proposing a digest that a cooldown policy won't allow to be pulled yet.
#
# Never goes back in time: when <current-digest> was pushed after that digest,
# <current-digest> is printed. Fails, with the reason on stderr, when the image
# is not in cgr.dev, the history can't be fetched, or no digest is old enough.

set -o nounset -o pipefail

ref=${1:?usage: cooldown-digest.sh <image:tag> <current-digest> <min-age-days>}
current=${2:?usage: cooldown-digest.sh <image:tag> <current-digest> <min-age-days>}
min_age=${3:?usage: cooldown-digest.sh <image:tag> <current-digest> <min-age-days>}
CRANE="${CRANE_PATH:-crane}"
NOW="${DIGESTABOT_NOW:-$(date +%s)}"

registry="${ref%%/*}"
if [ "${registry}" != "cgr.dev" ]; then
  echo "min-age is only supported for cgr.dev images" >&2
  exit 1
fi
repo="${ref#*/}"
tag="${repo##*:}"
repo="${repo%:*}"

# crane mints a pull token from the same credentials used to resolve digests.
token=$("${CRANE}" auth token "${registry}/${repo}" | jq -r '.token') || {
  echo "failed to get a registry token for ${registry}/${repo}" >&2
  exit 1
}
history=$(curl -fsSL -H "Authorization: Bearer ${token}" \
  "https://${registry}/v2/${repo}/_chainguard/history/${tag}") || {
  echo "failed to fetch the tag history of ${ref}" >&2
  exit 1
}

digest=$(jq -r --arg current "${current}" --argjson cutoff "$((NOW - 10#${min_age} * 86400))" '
  [.history[] | {digest, time: (.updateTimestamp | sub("\\.[0-9]+"; "") | fromdateiso8601)}] | sort_by(.time)
  | ([.[] | select(.time <= $cutoff)] | last) as $candidate
  | ([.[] | select(.digest == $current)] | last) as $pinned
  | if $candidate == null then empty
    elif $pinned != null and $pinned.time > $candidate.time then $current
    else $candidate.digest end' <<<"${history}") || {
  echo "failed to parse the tag history of ${ref}" >&2
  exit 1
}
if [ -z "${digest}" ]; then
  echo "no digest of ${ref} is older than ${min_age} days" >&2
  exit 1
fi
echo "${digest}"
