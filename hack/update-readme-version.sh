#!/usr/bin/env bash

# Copyright 2026 Chainguard, Inc.
# SPDX-License-Identifier: Apache-2.0

# Usage: update-readme-version.sh [<tag>]
#
# Pins every `chainguard-dev/digestabot@<sha> # <tag>` reference in the README
# and the docs to the commit of <tag>, the latest release by default, so the
# examples always point to the latest release.
#
# Set CHECK=true to only report whether the references are up to date (exit
# status 1 if not), without changing any file.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/chainguard-dev/digestabot}"
FILES=(README.md docs/*.md)

tag="${1:-}"
if [ -z "${tag}" ]; then
  # latest release tag, ignoring pre-releases such as v1.4.0-rc.1
  tag=$(git ls-remote --tags --refs --sort=-v:refname "${REPO_URL}" 'v*' |
    awk -F/ '{print $3}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
fi
if [ -z "${tag}" ]; then
  echo "Could not find the latest release of ${REPO_URL}" >&2
  exit 1
fi

# commit of the tag, peeled if the tag is annotated
sha=$(git ls-remote --tags "${REPO_URL}" "refs/tags/${tag}" "refs/tags/${tag}^{}" |
  sort -k2 | tail -n 1 | cut -f1)
if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Could not resolve the commit of ${tag}" >&2
  exit 1
fi

pattern='chainguard-dev/digestabot@[0-9a-f]{40} # v[0-9][0-9A-Za-z.+-]*'
replacement="chainguard-dev/digestabot@${sha} # ${tag}"

outdated=()
for file in "${FILES[@]}"; do
  [ -f "${file}" ] || continue
  if grep -E "${pattern}" "${file}" | grep -v -q -F "${replacement}"; then
    outdated+=("${file}")
  fi
done

if [ ${#outdated[@]} -eq 0 ]; then
  echo "All digestabot references point to ${tag} (${sha})."
  exit 0
fi

if [ "${CHECK:-false}" == "true" ]; then
  echo "These files don't point to the latest release ${tag} (${sha}): ${outdated[*]}" >&2
  echo "Run ./hack/update-readme-version.sh to update them." >&2
  exit 1
fi

for file in "${outdated[@]}"; do
  # portable in-place edit (GNU and BSD sed differ on -i)
  tmp=$(mktemp)
  sed -E "s|${pattern}|${replacement}|g" "${file}" > "${tmp}"
  cat "${tmp}" > "${file}"
  rm -f "${tmp}"
  echo "Updated ${file} to ${tag} (${sha})."
done
