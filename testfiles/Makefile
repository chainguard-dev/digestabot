dev-container:
	docker run --privileged --rm -it \
			-v "${PWD}:${PWD}" \
			-v "${HOME}/.cache/wolfictl/dev-container-enterprise/root:/root" \
			-v "${HOME}/.config/chainctl:/root/.config/chainctl" \
			-w "${PWD}" \
			ghcr.io/wolfi-dev/sdk:latest@sha256:16e05ea526a250ddb3e24167ecc6494b29961d0e5fc02b716b9eea31e82439f8

# The next two targets are mostly copies from the local-wolfi and
# dev-container-wolfi targets from wolfi-dev/os:
# https://github.com/wolfi-dev/os/blob/main/Makefile

PACKAGES_CONTAINER_FOLDER ?= /work/packages
TMP_REPOSITORIES_DIR := $(shell mktemp -d)
TMP_REPOSITORIES_FILE := $(TMP_REPOSITORIES_DIR)/repositories
# This target spins up a docker container that is helpful for testing local
# changes to the packages. It mounts the local packages folder as a read-only,
# and sets up the necessary keys for you to run `apk add` commands, and then
# test the packages however you see fit.
local-wolfi: ${KEY}
	@echo "https://packages.wolfi.dev/os" > $(TMP_REPOSITORIES_FILE)
	@echo "https://apk.cgr.dev/chainguard-private" >> $(TMP_REPOSITORIES_FILE)
	@echo "https://packages.cgr.dev/extras" >> $(TMP_REPOSITORIES_FILE)
	@echo "$(PACKAGES_CONTAINER_FOLDER)" >> $(TMP_REPOSITORIES_FILE)
	@mkdir -p ${PWD}/packages
	docker run --rm -it \
		-e HTTP_AUTH="basic:apk.cgr.dev:user:$(shell chainctl auth token --audience apk.cgr.dev)" \
		--mount type=bind,source="${PWD}/packages",destination="$(PACKAGES_CONTAINER_FOLDER)",readonly \
		--mount type=bind,source="${PWD}/local-melange-enterprise.rsa.pub",destination="/etc/apk/keys/local-melange-enterprise.rsa.pub",readonly \
		--mount type=bind,source="$(TMP_REPOSITORIES_FILE)",destination="/etc/apk/repositories",readonly \
		-w "$(PACKAGES_CONTAINER_FOLDER)" \
		cgr.dev/chainguard-private/chainguard-base:latest
	@rm "$(TMP_REPOSITORIES_FILE)"
	@rmdir "$(TMP_REPOSITORIES_DIR)"

dev-container-wolfi:
	@echo "https://packages.wolfi.dev/os" > $(TMP_REPOSITORIES_FILE)
	@echo "$(PACKAGES_CONTAINER_FOLDER)" >> $(TMP_REPOSITORIES_FILE)
	docker run --rm -it \
		--mount type=bind,source="${OUT_DIR}",destination="$(OUT_LOCAL_DIR)" \
		--mount type=bind,source="${OS_DIR}",destination="$(OS_LOCAL_DIR)",readonly \
		--mount type=bind,source="${PWD}/packages",destination="$(PACKAGES_CONTAINER_FOLDER)",readonly \
		--mount type=bind,source="${PWD}/local-melange-enterprise.rsa.pub",destination="/etc/apk/keys/local-melange-enterprise.rsa.pub",readonly \
		--mount type=bind,source="$(TMP_REPOSITORIES_FILE)",destination="/etc/apk/repositories",readonly \
		-w "$(PACKAGES_CONTAINER_FOLDER)" \
		ghcr.io/wolfi-dev/sdk:latest@sha256:16e05ea526a250ddb3e24167ecc6494b29961d0e5fc02b716b9eea31e82439f8
	@rm "$(TMP_REPOSITORIES_FILE)"
	@rmdir "$(TMP_REPOSITORIES_DIR)"
