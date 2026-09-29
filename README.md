# Image Digest Update (digestabot)

This action updates a image digest when using the tag+digest pattern.
If the tag is mutable it will have a new digest when the tag is updated.
If there is a change in the digest this action will update to the latest digest
and open a PR.

Given an image in the format `<repo>:<tag>@sha256:<digest>`
e.g. `cgr.dev/chainguard/nginx:latest@sha256:81bed54c9e507503766c0f8f030f869705dae486f37c2a003bb5b12bcfcc713f`, digesta-bot
will look up the digest of the tag on the registry and,
if it doesn't match, open a PR to update it.
This can be used to keep tags up-to-date whilst maintaining a reproducible build and providing an opportunity to test updates.

## Usage

Basic usage:

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
```

### Authentication
When accessing images in a private Chainguard registry, you will need to create an assumable identity with the `viewer` role, and add a step to set up the `chainctl` prior to running digestabot.

Authentication example:

```yaml
...
    - uses: chainguard-dev/setup-chainctl@be0acd273acf04bfdf91f51198327e719f6af978 # v0.4.0
        with:
          identity: ${{ secrets.CHAINCTL_IDENTITY }}

    - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0

    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
...
```

## Scenarios

Also you will need to enable the setting to allow GitHub Actions to create Pull Requests if you are not using a PAT Token

```
settings -> actions -> Allow GitHub Actions to create and approve pull requests
```

```yaml
name: Image digest update

on:
  workflow_dispatch:
  schedule:
    # At the end of every day
    - cron: "0 0 * * *"

jobs:
  image-update:
    name: Image digest update
    runs-on: ubuntu-latest

    permissions:
      contents: write # to push the updates
      pull-requests: write # to open Pull requests
      id-token: write # used to sign the commits using gitsign

    steps:
    - uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0

    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        signoff: true # optional
        author: ${{ github.actor }} <${{ github.actor_id }}+${{ github.actor }}@users.noreply.github.com> # optional
        committer: github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com> # optional
        labels-for-pr: automated pr, kind/cleanup, release-note-none # optional
        branch-for-pr: update-digests # optional
        title-for-pr: Update images digests # optional
        description-for-pr: Update images digests # optional
        commit-message: Update images digests # optional
```

### Registry Mapping

When pulling images through a registry proxy (e.g. GCP Artifact Registry), the proxy may return stale digests. Use `registry-map` to resolve digests against the upstream registry while keeping the proxy URL in your files:

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        registry-map: 'us-docker.pkg.dev/my-project/cgr/=cgr.dev/,us-docker.pkg.dev/my-project/ghcr/=ghcr.io/'
```

### Cooldown

When the registry enforces a [cooldown policy](https://edu.chainguard.dev/chainguard/chainguard-repository/container-policies/#cooldown),
digests newer than the cooldown period can't be pulled. Chainguard images are
rebuilt often, so the latest digest of a tag is usually still in that window.

Set `min-age` to the cooldown period, in days, to update to the most recent
digest that is at least that old instead. It uses the tag history of the
Chainguard registry, so it only applies to `cgr.dev` images (after
`registry-map`). Other images are skipped and reported in the job summary.
A pinned digest is never replaced by an older one.

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        min-age: 7
```

### Stale tags

`digestabot` keeps the digests of your tags up to date, but not the tags
themselves. Once a tag reaches its end of life it is no longer rebuilt, and the
pinned image stops receiving patches.

Set `stale-after` to a number of days to warn about the tags that were not
rebuilt in that period. They are annotated in the workflow run, listed in the
job summary and in the pull request, and returned in the `stale_tags` output.
The build time comes from the `org.opencontainers.image.created` annotation or
the image config; images without one, like most reproducible builds, are
skipped.

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        stale-after: 30
```

### Signature verification

Set `verify-signatures` to verify the [cosign](https://github.com/sigstore/cosign)
signature of every new digest before `digestabot` updates it. It is disabled by
default.

`verify-signatures` is a YAML list of rules. Each rule maps one or more image
prefixes to the certificate identity and issuer the signature must have:

| Key | Description |
|-----|-------------|
| `images` | Image prefix, or list of image prefixes, the rule applies to. |
| `identity` / `identity-regexp` | Expected certificate identity, exact or as a regular expression. Set exactly one. |
| `issuer` / `issuer-regexp` | Expected certificate OIDC issuer, exact or as a regular expression. Set exactly one. |

How the rules are applied:

- Images are matched against the prefixes after `registry-map`, so the
  signatures are always read from the upstream registry. When several prefixes
  match, the longest one wins.
- Images that no rule matches are updated without verification, as without
  `verify-signatures`.
- When a signature can't be verified, the update is skipped and the old digest
  is kept. The failure is annotated on the file, listed in the job summary and
  returned in the `verification_failures` output. The other updates are still
  applied.
- An invalid policy fails the step before any image is updated.

The policy is read with `yq`, which is installed on the GitHub-hosted runners.

#### Public Chainguard images

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        verify-signatures: |
          - images: cgr.dev/chainguard/
            identity: https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
            issuer: https://token.actions.githubusercontent.com
```

#### Images from different signers

Each signer gets its own rule. This example verifies the public Chainguard
images, the images of a Chainguard organization, and the sigstore images, and
updates any other image without verification:

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        verify-signatures: |
          - images: cgr.dev/chainguard/
            identity: https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main
            issuer: https://token.actions.githubusercontent.com
          - images: cgr.dev/my-org/
            identity-regexp: ^https://issuer\.enforce\.dev/(<catalog-syncer-id>|<apko-builder-id>)$
            issuer: https://issuer.enforce.dev
          - images:
              - ghcr.io/sigstore/
              - gcr.io/projectsigstore/
            identity-regexp: ^https://github\.com/sigstore/
            issuer: https://token.actions.githubusercontent.com
```

See [Verifying Chainguard Containers](https://edu.chainguard.dev/chainguard/chainguard-images/how-to-use/verifying-chainguard-images-and-metadata-signatures-with-cosign/)
for the identities that sign the images of your organization.

#### Policy file

`verify-signatures` can also be the path of a file with the policy, relative to
the root of the repository, so it is reviewed like the rest of the code:

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        verify-signatures: .github/digestabot-signatures.yaml
```

#### Acting on failures

Skipped updates don't fail the job. To fail it, or to open an issue, use the
`verification_failures` output:

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      id: digestabot
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        verify-signatures: .github/digestabot-signatures.yaml

    - if: ${{ steps.digestabot.outputs.verification_failures != '[]' }}
      shell: bash
      env:
        FAILURES: ${{ steps.digestabot.outputs.verification_failures }}
      run: |
        jq -r '.[] | "\(.image) \(.updated_digest) in \(.file): \(.error)"' <<<"${FAILURES}"
        exit 1
```

### Package changes

Set `sbom-diff: true` to list, for every updated image that publishes an SPDX
SBOM attestation (e.g. Chainguard images), the packages whose version changed
between the old and the new digest. It is disabled by default because it
fetches two SBOMs per updated image, which adds time on repositories with many
images; each image and digest is only processed once.

The SBOM of the `sbom-platform` image (`linux/amd64` by default) is used.
Images without an SBOM are listed as such and otherwise ignored.

The package changes are written to the job summary and the `sbom_diff` output,
and uploaded as the `sbom-diff-artifact-name` workflow artifact
(`sbom-diff.json` and `sbom-diff.md`) for further analysis.

### Acting on the updates

The `json` output describes the updates that `digestabot` has made and makes it
possible to extend the functionality of the action and act on the updates in
subsequent steps.

The schema of the output is described in [`action.yml`](action.yml).

```yaml
    # Run digestabot
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      id: digestabot
      with:
        token: ${{ secrets.GITHUB_TOKEN }}

    # Iterate over the updates in the `json` output
    - shell: bash
      env:
        UPDATES: ${{ steps.digestabot.outputs.json }}
      run: |
        while read -r update; do
          updated_image=$(jq -r '.image + "@" + .updated_digest' <<<"${update}")

          echo "Do something with ${updated_image} here."
        done < <(jq -c '.updates // [] | .[]' <<<"${UPDATES}")
```

### Filtering the updates

To decide yourself which updates to apply, set `create-pr: false`. `digestabot`
then leaves its changes uncommitted in the working tree and still reports them
in the `json` output. Discard the changes, re-apply only the updates you want,
and open the pull request in a later step.

This example only keeps the updates of Chainguard images that remove
vulnerabilities, using `chainctl image diff`:

```yaml
    - uses: chainguard-dev/digestabot@43222237fd8a07dc41a06ca13e931c95ce2cedac # v1.2.2
      id: digestabot
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        create-pr: false

    - shell: bash
      env:
        UPDATES: ${{ steps.digestabot.outputs.json }}
      run: |
        # Discard the changes made by digestabot
        git reset --hard && git clean -fd

        while read -r update; do
          image=$(jq -r '.image' <<<"${update}")
          digest=$(jq -r '.digest' <<<"${update}")
          updated_digest=$(jq -r '.updated_digest' <<<"${update}")
          file=$(jq -r '.file' <<<"${update}")

          if [[ ! "${image}" =~ ^cgr\.dev/ ]]; then
            echo "Skipping ${image}: not a Chainguard image."
            continue
          fi

          removed=$(chainctl image diff -o json "${image}@${digest}" "${image}@${updated_digest}" \
            | jq -r '.vulnerabilities.removed // [] | .[]')
          if [[ -z "${removed}" ]]; then
            echo "Skipping ${image}: no vulnerabilities removed."
            continue
          fi

          sed -i -e "s|${digest}|${updated_digest}|g" "${file}"
        done < <(jq -c '.updates // [] | .[]' <<<"${UPDATES}")

    # Commit the remaining changes and open a pull request here.
```

## File examples

Here are some examples of files that digestabot can update:

- `.ko.yaml`:

```yaml
defaultBaseImage: cgr.dev/chainguard/kubectl:latest-dev@sha256:d5f340d044438351413d6cb110f6f8a2abc45a7149aa53e6ade719f069fc3b0a
```

- any Kubernetes manifest with an image field e.g: Job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  namespace: default
  name: myjob
spec:
  template:
    spec:
      restartPolicy: Never
      initContainers:
      - image: cgr.dev/chainguard/cosign:latest-dev@sha256:09653ac03c1ac1502c3e3a8831ee79252414e4d659b423b71fb7ed8b097e9c88
...
```

- Dockerfile:

```
FROM cgr.dev/chainguard/busybox:latest@sha256:257157f6c6aa88dd934dcf6c2f140e42c2653207302788c0ed3bebb91c5311e1
```

- Kustomizations:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - "https://github.com/cert-manager/cert-manager/releases/download/v1.11.1/cert-manager.yaml"
patchesJSON6902:
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: cert-manager
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: cgr.dev/chainguard/cert-manager-controller:1.11.1@sha256:819a8714fc52fe3ecf3d046ba142e02ce2a95d1431b7047b358d23df6759de6c
...
```

## Inputs / Outputs

<!-- begin automated updates do not change -->
### Inputs

| Name | Description | Default |
|------|-------------|--------|
| `working-dir` | Working directory to run the digestabot, to run in a specific path, if not set will run from the root  | `.` |
| `include-files` | Files (names or globs, comma-separated) that will be scanned for digest updates.  | `*.yaml,*.yml,Dockerfile*,Makefile*,*.sh,*.tf,*.tfvars` |
| `token` | GITHUB_TOKEN or a `repo` scoped Personal Access Token (PAT)  | `${{ github.token }}` |
| `signoff` | Add `Signed-off-by` line by the committer at the end of the commit log message.  | `false` |
| `author` | The author name and email address in the format `Display Name <email@address.com>`. Defaults to the user who triggered the workflow run.  | `${{ github.actor }} <${{ github.actor_id }}+${{ github.actor }}@users.noreply.github.com>` |
| `committer` | The committer name and email address in the format `Display Name <email@address.com>`. Defaults to the GitHub Actions bot user.  | `github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>` |
| `labels-for-pr` | A comma or newline separated list of labels to be used in the pull request.  | `automated pr, kind/cleanup, release-note-none` |
| `branch-for-pr` | The pull request branch name.  | `update-digests` |
| `title-for-pr` | The title of the pull request.  | `Update images digests` |
| `description-for-pr` | The description of the pull request.  | `Update images digests ...` |
| `commit-message` | The message to use when committing changes.  | `Update images digests` |
| `create-pr` | Create a PR or just keep the changes locally.  | `true` |
| `use-gitsign` | Use gitsign to sign commits.  | `true` |
| `registry-map` | Comma-separated registry prefix mappings (proxy=upstream) for digest lookups. e.g. us-docker.pkg.dev/my-proj/cgr/=cgr.dev/  | `` |
| `min-age` | Only update to digests pushed at least this many days ago, so a cooldown policy on the registry does not block pulling them. Uses the tag history of the Chainguard registry, so it only applies to cgr.dev images (after `registry-map`); other images are skipped. Disabled when empty or 0.  | `` |
| `stale-after` | Warn about image tags that were not rebuilt in this many days, as they may have reached their end of life and no longer receive patches. Uses the build time of the image (`org.opencontainers.image.created`); images without one are skipped. Disabled when empty or 0.  | `` |
| `verify-signatures` | Verify the cosign signature of the new digests before updating them. A YAML list of rules mapping image prefixes to the expected certificate identity and issuer, or the path of a file with it. Updates whose signature cannot be verified are skipped; images not matched by any rule are not verified. Disabled when empty.  | `` |
| `sbom-diff` | List the package changes of each updated image in the job summary and upload them as a workflow artifact, based on its SPDX SBOM attestation. Images without an SBOM are skipped.  | `false` |
| `sbom-platform` | Platform of the image whose SBOM is used for the package changes.  | `linux/amd64` |
| `sbom-diff-artifact-name` | Name of the workflow artifact with the package changes (`sbom-diff.json` and `sbom-diff.md`). Must be unique within the workflow run.  | `digestabot-sbom-diff` |

### Outputs

| Name | Description |
|------|-------------|
| `pull_request_number` | Pull Request Number  |
| `json` | The changes made by this action, in JSON format. Contains information about updated files, images, and digests. |
| `changed_files` | A newline-separated list of files that were modified during the digest update process. Only includes files that actually had their digests updated.  |
| `sbom_diff` | Markdown summary of the package changes of each updated image, based on its SPDX SBOM attestation. Empty when `sbom-diff` is disabled or no digest was updated.  |
| `sbom_diff_artifact_url` | URL of the workflow artifact with the package changes. Empty when `sbom-diff` is disabled or no digest was updated.  |
| `stale_tags` | The image tags that were not rebuilt in the last `stale-after` days, in json format. Empty when `stale-after` is disabled.  The output follows this structure:  ``` [   {     "image": "cgr.dev/chainguard/python:3.9",     "lookup_image": "cgr.dev/chainguard/python:3.9",     "files": ["Dockerfile"],     "created": "2026-06-01T00:00:00Z",     "age_days": 120   } ] ```  |
| `verification_failures` | The updates that were skipped because the signature of the new digest could not be verified, in json format. Empty when `verify-signatures` is disabled.  The output follows this structure:  ``` [   {     "file": "Dockerfile",     "image": "cgr.dev/chainguard/static:latest",     "digest": "sha256:a117fb6e8c62246fe60e40eaa0c2cb51575db8cec42c114bc5a9d4cb89d94fee",     "updated_digest": "sha256:41e17ed83c594a64a9396b6ab96dd26d5ddc290dacf4c177464712ff21ad534f",     "error": "no matching signatures"   } ] ```  |

> **Note:** For complete details on inputs and outputs, please refer to the [action.yml](./action.yml) file.
<!-- end automated updates do not change -->
