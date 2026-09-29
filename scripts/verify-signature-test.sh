#!/usr/bin/env bash
# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Tests for signature-policy.sh and verify-signature.sh, using a fake cosign.

set -o errexit -o nounset -o pipefail

scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures=$(mktemp -d)
trap 'rm -rf "${fixtures}"' EXIT

# The fake cosign logs its arguments, and fails for images whose name contains
# "unsigned".
cat > "${fixtures}/cosign" <<EOF
#!/usr/bin/env bash
echo "\$*" > "${fixtures}/args"
if [[ "\${*: -1}" == *unsigned* ]]; then
  echo "Error: no matching signatures" >&2
  echo "error during command execution: no matching signatures" >&2
  exit 1
fi
echo '[{"critical": {}}]'
EOF
chmod +x "${fixtures}/cosign"
export COSIGN_PATH="${fixtures}/cosign"

failures=0
ok() { echo "ok: $1"; }
fail() {
  echo "FAIL: $1: $2"
  failures=$((failures + 1))
}

# policy <name> <yaml> checks that <yaml> is a valid policy and writes it to
# ${fixtures}/policy.json.
policy() {
  if "${scripts}/signature-policy.sh" "$2" > "${fixtures}/policy.json" 2> "${fixtures}/stderr"; then
    ok "$1"
  else
    fail "$1" "$(cat "${fixtures}/stderr")"
  fi
}

# invalid <name> <yaml> <message> checks that <yaml> is rejected with <message>.
invalid() {
  if "${scripts}/signature-policy.sh" "$2" > /dev/null 2> "${fixtures}/stderr"; then
    fail "$1" "want an error"
  elif ! grep -q -F -- "$3" "${fixtures}/stderr"; then
    fail "$1" "want $3, got $(cat "${fixtures}/stderr")"
  else
    ok "$1"
  fi
}

# verify <name> <image:tag> <exit code> <cosign args> checks the exit code of
# verify-signature.sh and, when cosign runs, its arguments.
verify() {
  local code=0
  rm -f "${fixtures}/args"
  "${scripts}/verify-signature.sh" "${fixtures}/policy.json" "$2" sha256:abc 2> "${fixtures}/stderr" || code=$?
  if [ "${code}" != "$3" ]; then
    fail "$1" "want exit code $3, got ${code}: $(cat "${fixtures}/stderr")"
  elif [ -n "${4:-}" ] && [ "$(cat "${fixtures}/args")" != "$4" ]; then
    fail "$1" "want cosign $4, got cosign $(cat "${fixtures}/args")"
  elif [ -z "${4:-}" ] && [ -e "${fixtures}/args" ]; then
    fail "$1" "want no cosign call, got cosign $(cat "${fixtures}/args")"
  else
    ok "$1"
  fi
}

policy "reads an inline policy" '
- images: cgr.dev/
  identity-regexp: ^https://issuer\.enforce\.dev/
  issuer: https://issuer.enforce.dev
- images: [cgr.dev/chainguard/, ghcr.io/org/unsigned]
  identity: https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
  issuer-regexp: ^https://token\.actions\.githubusercontent\.com$'

verify "uses the longest matching prefix" cgr.dev/chainguard/static:latest 0 \
  "verify --certificate-identity https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main --certificate-oidc-issuer-regexp ^https://token\.actions\.githubusercontent\.com$ cgr.dev/chainguard/static@sha256:abc"
verify "falls back to a shorter prefix" cgr.dev/my-org/static:1 0 \
  "verify --certificate-identity-regexp ^https://issuer\.enforce\.dev/ --certificate-oidc-issuer https://issuer.enforce.dev cgr.dev/my-org/static@sha256:abc"
verify "does not verify images without a rule" docker.io/library/python:3 3
verify "fails when the signature can't be verified" ghcr.io/org/unsigned:1 1 \
  "verify --certificate-identity https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main --certificate-oidc-issuer-regexp ^https://token\.actions\.githubusercontent\.com$ ghcr.io/org/unsigned@sha256:abc"
if grep -q "no matching signatures" "${fixtures}/stderr"; then
  ok "reports the cosign error"
else
  fail "reports the cosign error" "$(cat "${fixtures}/stderr")"
fi

cat > "${fixtures}/policy.yaml" <<'EOF'
- images: [ghcr.io/, "localhost:5000/"]
  identity: someone
  issuer: https://example.com
EOF
policy "reads a policy file" "${fixtures}/policy.yaml"
verify "uses the policy file" ghcr.io/org/app:1 0 \
  "verify --certificate-identity someone --certificate-oidc-issuer https://example.com ghcr.io/org/app@sha256:abc"
verify "strips the tag of an image on a registry with a port" localhost:5000/app:1 0 \
  "verify --certificate-identity someone --certificate-oidc-issuer https://example.com localhost:5000/app@sha256:abc"

invalid "rejects invalid YAML" 'a: [b' "not valid YAML"
invalid "rejects a policy that is not a list" 'images: cgr.dev/' "must be a non-empty list of rules"
invalid "requires an identity" '- {images: cgr.dev/, issuer: x}' "rule 1: set exactly one of identity and identity-regexp"
invalid "rejects two identities" '- {images: cgr.dev/, identity: a, identity-regexp: b, issuer: x}' "rule 1: set exactly one of identity and identity-regexp"
invalid "requires an issuer" '- {images: cgr.dev/, identity: a}' "rule 1: set exactly one of issuer and issuer-regexp"
invalid "requires images" '- {identity: a, issuer: x}' "rule 1: images must be an image prefix or a list of image prefixes"
invalid "rejects empty images" '- {images: [], identity: a, issuer: x}' "rule 1: images must be an image prefix or a list of image prefixes"
invalid "rejects an empty prefix" '- {images: "", identity: a, issuer: x}' "rule 1: images must be non-empty strings"
invalid "rejects unknown keys" '- {images: cgr.dev/, identity: a, issuer: x, key: k}' "rule 1: unknown key key"
invalid "numbers the rules" '[{images: a/, identity: a, issuer: x}, nope]' "rule 2: must be a mapping"

if [ "${failures}" -gt 0 ]; then
  echo "${failures} test(s) failed"
  exit 1
fi
