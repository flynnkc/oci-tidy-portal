# Workspace helper scripts

These scripts provide repeatable development and operations tasks that apply to
the projects in this workspace. Run them from the workspace root.

## Build and push an OCIR image

`build-and-push-image.sh` builds a project's Dockerfile with Docker Buildx or
Podman and pushes the resulting image to Oracle Cloud Infrastructure Registry (OCIR).
It resolves the tenancy namespace through the OCI CLI unless `--namespace` is
provided. The target OCIR repository must already exist and the selected engine
must already be authenticated, unless `--login` is used. The default `auto`
engine selects Docker when available, otherwise Podman.

```bash
scripts/build-and-push-image.sh \
  --project projects/oci-management-portal \
  --repository oci-management-portal \
  --region us-ashburn-1 \
  --tag 1.2.0 \
  --platform linux/arm64
```

To explicitly use Podman, add `--engine podman` (or set
`CONTAINER_ENGINE=podman`). Podman builds a manifest list when more than one
platform is supplied.

For a multi-architecture image, supply a comma-separated platform list:

```bash
scripts/build-and-push-image.sh \
  --project projects/tag-updater \
  --repository platform/tag-updater \
  --region us-ashburn-1 \
  --platform linux/amd64,linux/arm64 \
  --also-tag-latest
```

Run `scripts/build-and-push-image.sh --help` for all options and environment
variables.
