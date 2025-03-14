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
    - uses: chainguard-dev/digestabot@v1.0.2
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
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
    - uses: actions/checkout@v4
    - uses: chainguard-dev/digestabot@v1.0.2
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

The `json` output describes the updates that `digestabot` has made and makes it
possible to extend the functionality of the action and act on the updates in
subsequent steps.

The schema of the output is described in [`action.yml`](action.yml).

```yaml
    # Run digestabot
    - uses: chainguard-dev/digestabot@v1
      id: digestabot
      with:
        token: ${{ secrets.GITHUB_TOKEN }}

    # Iterate over the updates in the `json` output
    - shell: bash
      run: |
        while read -r update; do
          updated_image=$(jq -r '.image + "@" + .updated_digest' <<<"${update}")

          echo "Do something with ${updated_image} here."
        done < <(jq -c '.updates // [] | .[]' <<<'${{ steps.digestabot.outputs.json }}')
```

You can also conditionally update images based on some criteria by reverting the
changes made by `digestabot` and applying them yourself.

```yaml
    # Run digestabot to discover images to update. Don't create the PR.
    - uses: chainguard-dev/digestabot@v1
      id: digestabot
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        create-pr: false

    # Revert the changes made by digestabot
    - run: |
        git reset --hard && git clean -fd

    # Iterate over the updates in the `json` output. Make the change if the image
    # is in cgr.dev.
    - shell: bash
      run: |
        while read -r update; do
          from_image=$(jq -r '.image + "@" + .digest' <<<"${update}")
          to_image=$(jq -r '.image + "@" + .updated_digest' <<<"${update}")
          file=$(jq -r '.file' <<<"${update}")

          if [[ "${to_image}" =~ ^cgr.dev/.+$ ]]; then
            sed -i -e "s|$from_image|$to_image|g" "$file"
          fi
        done < <(jq -c '.updates // [] | .[]' <<<'${{ steps.digestabot.outputs.json }}')

    # Check for any changes
    - id: create_pr_update
      shell: bash
      run: |
        echo "create_pr_update=false" >> $GITHUB_OUTPUT
        if [[ $(git diff --stat) != '' ]]; then
          echo "create_pr_update=true" >> $GITHUB_OUTPUT
        fi

    # Create the PR yourself
    - uses: peter-evans/create-pull-request@v7
      if: ${{ steps.create_pr_update.outputs.create_pr_update == 'true' }}
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
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

```
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
