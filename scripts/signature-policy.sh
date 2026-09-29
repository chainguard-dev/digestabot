#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Usage: signature-policy.sh <policy> > policy.json
#
# Reads the `verify-signatures` policy, either inline YAML or the path of a
# YAML file, validates it and prints it as JSON, one rule per image prefix:
#
#   [{"prefix": "cgr.dev/chainguard/", "identity": "...", "issuer": "..."}]
#
# A rule of the policy has these keys:
#
#   images           image prefix, or list of image prefixes, it applies to
#   identity         certificate identity, or identity-regexp
#   issuer           certificate OIDC issuer, or issuer-regexp
#
# Fails, listing every problem on stderr, when the policy is invalid.

set -o nounset -o pipefail

policy=${1:?usage: signature-policy.sh <policy>}

if ! command -v yq > /dev/null; then
  echo "yq is required to read the verify-signatures policy" >&2
  exit 1
fi

if [ -f "${policy}" ]; then
  json=$(yq -o=json '.' "${policy}")
else
  json=$(yq -o=json '.' <<<"${policy}")
fi || {
  echo "verify-signatures is not valid YAML" >&2
  exit 1
}

errors=$(jq -r '
  if type != "array" or length == 0 then "the policy must be a non-empty list of rules"
  else to_entries[] | .key as $i | .value |
    if type != "object" then "rule \($i + 1): must be a mapping"
    else
      ((keys - ["images", "identity", "identity-regexp", "issuer", "issuer-regexp"])[] | "rule \($i + 1): unknown key \(.)"),
      (if (.images | type) == "string" then .images else .images[]? end | select(type != "string" or . == "") |
        "rule \($i + 1): images must be non-empty strings"),
      (select((.images | type) != "string" and ((.images | type) != "array" or (.images | length) == 0)) |
        "rule \($i + 1): images must be an image prefix or a list of image prefixes"),
      (select([has("identity"), has("identity-regexp")] | map(select(.)) | length != 1) |
        "rule \($i + 1): set exactly one of identity and identity-regexp"),
      (select([has("issuer"), has("issuer-regexp")] | map(select(.)) | length != 1) |
        "rule \($i + 1): set exactly one of issuer and issuer-regexp"),
      (to_entries[] | select(.key != "images" and ((.value | type) != "string" or .value == "")) |
        "rule \($i + 1): \(.key) must be a non-empty string")
    end
  end' <<<"${json}")

if [ -n "${errors}" ]; then
  echo "invalid verify-signatures policy:" >&2
  echo "  ${errors//$'\n'/$'\n'  }" >&2
  exit 1
fi

jq '[.[] | (if (.images | type) == "string" then [.images] else .images end)[] as $prefix
  | {prefix: $prefix} + (del(.images))]' <<<"${json}"
