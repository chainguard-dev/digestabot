#!/usr/bin/env bash
# Test fixture for digestabot: validates that digest updates preserve shell
# syntax characters adjacent to the SHA (e.g., closing braces and quotes).
#
# The patterns below use a stale digest so digestabot will attempt to update
# them. After the update, `bash -n` should still pass (no parse errors).

set -o errexit -o nounset -o pipefail

# Pattern 1: colon-builtin default assignment — SHA followed by }"
: "${IMAGE_A:=cgr.dev/chainguard/static:latest@sha256:a8aeacbaf0a1176ab5dbcf9b73a517665d8db5e1495ba97d64c73b3821deb0d8}"

# Pattern 2: plain variable default — SHA followed by }"
IMAGE_B="${IMAGE_B:-cgr.dev/chainguard/static:latest@sha256:a8aeacbaf0a1176ab5dbcf9b73a517665d8db5e1495ba97d64c73b3821deb0d8}"

# Pattern 3: simple assignment — SHA followed by "
IMAGE_C="cgr.dev/chainguard/static:latest@sha256:a8aeacbaf0a1176ab5dbcf9b73a517665d8db5e1495ba97d64c73b3821deb0d8"

# Pattern 4: bare assignment (no quotes) — SHA at end of line
_DEFAULT_IMAGE=cgr.dev/chainguard/static:latest@sha256:a8aeacbaf0a1176ab5dbcf9b73a517665d8db5e1495ba97d64c73b3821deb0d8

echo "${IMAGE_A}" "${IMAGE_B}" "${IMAGE_C}" "${_DEFAULT_IMAGE}"
