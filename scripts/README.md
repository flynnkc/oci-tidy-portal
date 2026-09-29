# Workspace helper scripts

These scripts provide repeatable development and operations tasks that apply to
the projects in this workspace. **Run them from the workspace root**.

> **Windows:** These are Bash scripts. Run them from Windows Subsystem for
> Linux (WSL), not PowerShell or Command Prompt. Ensure Docker or Podman is
> available to your WSL distribution.

## Build and push an OCIR image

`build-and-push-image.sh` builds the Dockerfiles in all three project submodules
(OCI Management Portal, Tag Updater, and OCI Extirpater) with Docker Buildx or
Podman, then pushes all three images to Oracle Cloud Infrastructure Registry
(OCIR). It resolves the tenancy namespace through the OCI CLI unless
`--namespace` is provided. The target OCIR repositories must already exist and
the selected engine must already be authenticated, unless `--login` is used.
The default `auto` engine selects Docker when available, otherwise Podman.
The helper selects the documented short OCIR endpoint automatically for every
public OC1 region, including `iad.ocir.io` for `us-ashburn-1` and
`ord.ocir.io` for `us-chicago-1`. For a region outside that table, provide its
OCIR endpoint with `--registry` (or `REGISTRY`).

```bash
scripts/build-and-push-image.sh \
  --region us-ashburn-1 \
  --platform linux/arm64
```

By default, each image is tagged with the short SHA of its own submodule. Use
`--tag 1.2.0` to apply one tag to every image, or use `--portal-tag`,
`--tag-updater-tag`, and `--extirpater-tag` for individual overrides. Repository
names default to `oci-management-portal`, `tag-updater`, and `ociextirpater`;
override them with the matching `--*-repository` option or environment variable.

To explicitly use Podman, add `--engine podman` (or set
`CONTAINER_ENGINE=podman`). Podman builds a manifest list when more than one
platform is supplied.

For a multi-architecture image, supply a comma-separated platform list:

```bash
scripts/build-and-push-image.sh \
  --tag-updater-repository platform/tag-updater \
  --region us-ashburn-1 \
  --platform linux/amd64,linux/arm64 \
  --also-tag-latest
```

Run `scripts/build-and-push-image.sh --help` for all options and environment
variables.
