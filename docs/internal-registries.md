# Using digestabot with an internal registry only

This guide covers repositories whose images come only from an internal
registry, such as Amazon ECR, Azure Container Registry (ACR) or JFrog
Artifactory, where the workflow does not (or can't) connect to `cgr.dev`.

It's a common setup when Chainguard images are mirrored into a registry the
organization controls, served through a pull-through cache, or when the
runners can only reach approved endpoints.

## How digestabot resolves digests

For every `<registry>/<repository>:<tag>@sha256:<digest>` reference in your
files, digestabot asks the registry **in the reference** for the current digest
of the tag, with `crane digest`. If it differs from the pinned digest, the
reference is updated.

So with references like:

```dockerfile
FROM 123456789012.dkr.ecr.us-east-1.amazonaws.com/chainguard/python:latest@sha256:<digest>
```

digestabot only talks to `123456789012.dkr.ecr.us-east-1.amazonaws.com`. It
never contacts `cgr.dev` unless you set it up to:

- **Don't set `registry-map`.** It redirects lookups to another registry (e.g.
  `cgr.dev`) and is meant for proxies that may serve stale digests while the
  upstream is reachable.
- **Don't set `min-age`.** It reads the tag history from the Chainguard
  registry, so it only works for `cgr.dev` images. Other images are skipped and
  listed in the job summary.

Digestabot can only be as fresh as your internal registry: it reports the
digest the internal tag points to at the time of the run. How that tag gets
updated depends on how the images get there:

- **Mirroring / replication** (a scheduled job copying images into the
  registry): the tag moves when the job runs. Schedule digestabot after it.
- **Pull-through cache** (ECR pull through cache rules, ACR artifact cache,
  Artifactory remote repositories): the cache refreshes a mutable tag on its
  own schedule, so a run may see the previous digest until then. Check the
  cache settings of your registry.

> [!TIP]
> Copy the images without modifying them (all platforms of the index, no
> re-compression) so that the digests stay identical to the upstream ones. This
> isn't required for digestabot, which only uses the internal digests, but
> signatures, attestations and SBOMs reference the original digests.

## Authentication

Digestabot has no registry credential inputs. `crane` uses the Docker
configuration of the runner (`~/.docker/config.json`, or `$DOCKER_CONFIG`) and
its credential helpers, so any step that logs in with `docker login` before
digestabot works. Digestabot only reads from the registry: read-only (pull)
access is enough.

The examples below use `use-gitsign: false`, as runners that can't reach
`cgr.dev` usually can't reach the Sigstore public good instance either. See
[Commit signing](../README.md#commit-signing).

### Amazon ECR

Assume an IAM role with GitHub OIDC and log in with `amazon-ecr-login`. The role
needs pull access to the repositories, for example through the
`AmazonEC2ContainerRegistryReadOnly` managed policy.

```yaml
name: Image digest update

on:
  workflow_dispatch:
  schedule:
    - cron: "0 0 * * *"

permissions: {}

jobs:
  image-update:
    runs-on: ubuntu-latest

    permissions:
      contents: write # to push the updates
      pull-requests: write # to open Pull requests
      id-token: write # to assume the AWS role with OIDC

    steps:
    - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

    - uses: aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0
      with:
        role-to-assume: arn:aws:iam::123456789012:role/digestabot
        aws-region: us-east-1

    - uses: aws-actions/amazon-ecr-login@03f1aad4c6c7ffd436567f42f9384779290529bd # v2.1.7
      # For registries of other AWS accounts, list their account IDs:
      # with:
      #   registries: "123456789012,210987654321"

    - uses: chainguard-dev/digestabot@33d0b78e580aa0c83fe188eb3dfad6611b662479 # v1.3.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        use-gitsign: false
```

### Azure Container Registry

Log in to Azure with OIDC (a federated credential on an app registration or a
managed identity) and then to the registry with `az acr login`. The identity
needs the `AcrPull` role on the registry. `az acr login` uses the Docker CLI,
which is installed on the GitHub-hosted runners.

```yaml
    permissions:
      contents: write # to push the updates
      pull-requests: write # to open Pull requests
      id-token: write # to log in to Azure with OIDC

    steps:
    - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

    - uses: azure/login@a641126d1b8aa4d1fa005f4f92df94a3a4c4c906 # v3.1.0
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

    - name: Log in to ACR
      shell: bash
      run: az acr login --name myregistry

    - uses: chainguard-dev/digestabot@33d0b78e580aa0c83fe188eb3dfad6611b662479 # v1.3.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        use-gitsign: false
```

The references then look like
`myregistry.azurecr.io/chainguard/python:latest@sha256:<digest>`.

### JFrog Artifactory

Log in with `docker/login-action` and an access token of a user with read
permission on the Docker repositories. Artifactory can also exchange a GitHub
OIDC token for an access token, see
[jfrog/setup-jfrog-cli](https://github.com/jfrog/setup-jfrog-cli).

```yaml
    permissions:
      contents: write # to push the updates
      pull-requests: write # to open Pull requests

    steps:
    - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

    - uses: docker/login-action@dbcb813823bdd20940b903addbd779551569679f # v4.6.0
      with:
        registry: mycompany.jfrog.io
        username: ${{ vars.JFROG_USERNAME }}
        password: ${{ secrets.JFROG_ACCESS_TOKEN }}

    - uses: chainguard-dev/digestabot@33d0b78e580aa0c83fe188eb3dfad6611b662479 # v1.3.2
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        use-gitsign: false
```

The references include the Artifactory repository, e.g.
`mycompany.jfrog.io/docker-remote/chainguard/python:latest@sha256:<digest>`
with the repository path method, or
`docker-remote.mycompany.jfrog.io/chainguard/python:latest@sha256:<digest>`
with the subdomain method.

`docker/login-action` works the same way for any other registry that supports
`docker login`, including ECR and ACR.

## Features with an internal registry

| Feature | Works with an internal registry only | Notes |
|---------|--------------------------------------|-------|
| Digest updates | Yes | |
| `registry-map` | Not needed | Redirects the lookups to another registry. |
| `min-age` | No | Reads the tag history of `cgr.dev`. The images are skipped and listed in the job summary. |
| `stale-after` | Yes | Reads the build time from the image in the internal registry. |
| `verify-signatures` | If the signatures are mirrored | Signatures are read from the internal repository, so they must be copied with the images (e.g. `cosign copy`), and the `images` prefixes must match the internal registry. `cosign` also needs the Sigstore trust root, see [Network access and dependencies](network-and-dependencies.md#signature-verification). |
| `sbom-diff` | If the attestations are mirrored | Reads the `sha256-<digest>.att` attestation tag from the same repository, so it must be copied with the image and the digest preserved. |
| `use-gitsign` | Needs Sigstore access | Set `use-gitsign: false` if the runners can't reach the Sigstore public good instance. |

> [!NOTE]
> `min-age`, `stale-after`, `verify-signatures` and `sbom-diff` are not in
> v1.3.2 yet; they're available on `main` and will ship in the next release.

## What the runner still needs to reach

Even without `cgr.dev`, digestabot downloads `crane` from GitHub releases and
uses the GitHub API to open the pull request. See
[Network access and dependencies](network-and-dependencies.md) for the full
list of endpoints and tools.
