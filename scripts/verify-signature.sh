#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Usage: verify-signature.sh <policy.json> <image:tag> <digest>
#
# Verifies the cosign signature of <image>@<digest> with the rule of
# <policy.json> (as printed by signature-policy.sh) whose prefix is the
# longest one matching <image:tag>.
#
# Exits 0 when the signature is verified, 1 when it is not (with the reason on
# stderr), and 3 when no rule matches the image, which is then not verified.

set -o nounset -o pipefail

policy=${1:?usage: verify-signature.sh <policy.json> <image:tag> <digest>}
ref=${2:?usage: verify-signature.sh <policy.json> <image:tag> <digest>}
digest=${3:?usage: verify-signature.sh <policy.json> <image:tag> <digest>}
COSIGN="${COSIGN_PATH:-cosign}"

rule=$(jq -c --arg ref "${ref}" \
  '[.[] | select(.prefix as $p | $ref | startswith($p))] | max_by(.prefix | length) // empty' "${policy}")
[ -n "${rule}" ] || exit 3

args=()
for key in identity identity-regexp issuer issuer-regexp; do
  jq -e --arg key "${key}" 'has($key)' <<<"${rule}" > /dev/null || continue
  flag="--certificate-${key/issuer/oidc-issuer}"
  args+=("${flag}" "$(jq -r --arg key "${key}" '.[$key]' <<<"${rule}")")
done

echo "Verifying the signature of ${ref%:*}@${digest} with the rule for $(jq -r '.prefix' <<<"${rule}")" >&2
if ! output=$("${COSIGN}" verify "${args[@]}" "${ref%:*}@${digest}" 2>&1 > /dev/null); then
  echo "${output}" >&2
  exit 1
fi
