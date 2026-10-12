# Network access and dependencies

This page lists what digestabot downloads, which tools it uses and which
endpoints it connects to, so it can be run behind an egress firewall, with an
allow-list such as [harden-runner](https://github.com/step-security/harden-runner),
or on self-hosted runners.

Most of the network access depends on the inputs. With the defaults, digestabot
needs GitHub, the registries of your images and, to sign the commit, the
Sigstore public good instance.

## Tools

### Downloaded by the action

| Tool | Version | When | Downloaded from |
|------|---------|------|-----------------|
| [crane](https://github.com/google/go-containerregistry/blob/main/cmd/crane/README.md) | v0.21.3, SHA-256 verified | Always | `github.com/google/go-containerregistry` releases |
| [cosign](https://github.com/sigstore/cosign) | Installed by `sigstore/cosign-installer` v4.1.2 | `verify-signatures` is set | `github.com/sigstore/cosign` releases |
| [gitsign](https://github.com/sigstore/gitsign) | v0.16.1, SHA-256 verified, installed by `chainguard-dev/actions/setup-gitsign` v1.6.39 | `use-gitsign: true` (the default) and there are updates to commit | `github.com/sigstore/gitsign` releases |

### Actions used by the action

The runner downloads these actions from GitHub when the step runs, so they must
be available to it (on GitHub Enterprise Server, through GitHub Connect or a
synced copy):

| Action | When |
|--------|------|
| `actions/github-script` | There are updates and `create-pr: true` |
| `chainguard-dev/actions/setup-gitsign` | There are updates, `create-pr: true` and `use-gitsign: true` |
| `sigstore/cosign-installer` | `verify-signatures` is set |
| `actions/upload-artifact` | `sbom-diff: true` and there are updates |

The exact versions are pinned by commit in [`action.yml`](../action.yml).

### Expected on the runner

Digestabot is a composite action, which runs on the runner itself. The
GitHub-hosted Ubuntu runners have everything it needs. Self-hosted runners must
be **Linux** (x86_64 or arm64) and provide:

- `bash` 4 or later, `git`, `curl`, `tar`, `sha256sum`, `openssl`
- GNU `sed`, `grep` and `find` (the BSD versions of macOS behave differently)
- `jq`
- `yq` ([mikefarah/yq](https://github.com/mikefarah/yq)), only with `verify-signatures`
- Node.js, which the runner provides for `actions/github-script`

## Endpoints

| Endpoint | Used for | When |
|----------|----------|------|
| `github.com:443` | Downloading `crane`, `cosign` and `gitsign` releases; pushing the branch | Always |
| `release-assets.githubusercontent.com:443`, `objects.githubusercontent.com:443` | GitHub release downloads redirect here | Always |
| `api.github.com:443` | Opening or updating the pull request and its labels | There are updates and `create-pr: true` |
| The registries of your images | Resolving the digests; with `stale-after`, `sbom-diff` and `verify-signatures`, reading manifests, configs, attestations and signatures | Always |
| `cgr.dev:443` | Only when your images (after `registry-map`) are on `cgr.dev`. `min-age` also reads the tag history from `https://cgr.dev/v2/<repository>/_chainguard/history/<tag>` | `cgr.dev` images |
| The GitHub Actions OIDC token endpoint (`ACTIONS_ID_TOKEN_REQUEST_URL`) | Getting the identity token that gitsign exchanges for a signing certificate | `use-gitsign: true` |
| `fulcio.sigstore.dev:443` | Issuing the short-lived signing certificate | `use-gitsign: true` |
| `rekor.sigstore.dev:443` | Recording the signature in the transparency log; checking it with `cosign` | `use-gitsign: true`, `verify-signatures` |
| `tuf-repo-cdn.sigstore.dev:443` | Fetching the Sigstore trust root | `use-gitsign: true`, `verify-signatures` |
| `results-receiver.actions.githubusercontent.com:443`, `*.blob.core.windows.net:443` | Uploading the workflow artifact | `sbom-diff: true` |

On GitHub Enterprise Server, replace `github.com` and `api.github.com` with
your server. The Sigstore endpoints are the public good instance; there's no
input to point gitsign or cosign to a private Sigstore deployment.

### Commit signing

With `use-gitsign: true`, the default, gitsign signs the commit with a
short-lived certificate from [Fulcio](https://docs.sigstore.dev/certificate_authority/overview/),
the Sigstore certificate authority, issued for the identity of the workflow
(GitHub OIDC). The signature is recorded in the
[Rekor](https://docs.sigstore.dev/logging/overview/) transparency log. This
needs:

- the `id-token: write` permission on the job,
- access to the GitHub OIDC token endpoint, `fulcio.sigstore.dev`,
  `rekor.sigstore.dev` and `tuf-repo-cdn.sigstore.dev`.

> [!IMPORTANT]
> Rekor is a public log. The signing certificate contains the identity of the
> workflow, e.g.
> `https://github.com/<org>/<repo>/.github/workflows/<workflow>.yaml@refs/heads/main`,
> so the names of the organization, repository and workflow become public, even
> for private repositories. Set `use-gitsign: false` if that isn't acceptable.

GitHub doesn't recognize the Sigstore certificate authority and shows these
commits as **Unverified**. See [Commit signing](../README.md#commit-signing).

With `use-gitsign: false`, none of the Sigstore endpoints are used and
`id-token: write` isn't needed for digestabot (other steps, such as an OIDC
login to your registry, may still need it).

### Signature verification

`verify-signatures` runs `cosign verify` for keyless signatures. `cosign`
fetches the Sigstore trust root from `tuf-repo-cdn.sigstore.dev` and may query
`rekor.sigstore.dev`. The signatures themselves are read from the registry of
the image (after `registry-map`).

## Example allow-list

A harden-runner allow-list for an internal ECR registry, without gitsign
(`use-gitsign: false`), and without `sbom-diff` or `verify-signatures`:

```yaml
    - uses: step-security/harden-runner@e14015d583714f6e62063499dc959a02595150a1 # v2.21.1
      with:
        egress-policy: block
        allowed-endpoints: >
          api.github.com:443
          github.com:443
          objects.githubusercontent.com:443
          release-assets.githubusercontent.com:443
          123456789012.dkr.ecr.us-east-1.amazonaws.com:443
          api.ecr.us-east-1.amazonaws.com:443
          sts.us-east-1.amazonaws.com:443
```

The last three entries are for ECR and the AWS login steps; with
`use-gitsign: true`, add `fulcio.sigstore.dev:443`, `rekor.sigstore.dev:443`
and `tuf-repo-cdn.sigstore.dev:443`. Start with `egress-policy: audit` to see
the endpoints a run actually uses, and then switch to `block`. Images stored on
ECR are served from Amazon S3, so ECR may also need
`prod-us-east-1-starport-layer-bucket.s3.us-east-1.amazonaws.com:443` when
blobs are read (`stale-after`, `sbom-diff`).

## Credentials

- **`token`** is used to push the branch and open the pull request. It's also
  stored in the Docker configuration of the runner as a `ghcr.io` credential,
  so that images on `ghcr.io` can be resolved. On persistent self-hosted
  runners, it stays in `~/.docker/config.json` and `~/.git-credentials` after
  the job.
- **Registry credentials** are read from the Docker configuration. See
  [Authentication](internal-registries.md#authentication).
- The branch is pushed with a credential for `github.com`. On GitHub Enterprise
  Server, keep the credentials of `actions/checkout` (the default,
  `persist-credentials: true`) so the push is authenticated.
