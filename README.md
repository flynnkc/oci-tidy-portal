# OCI Tidy Portal

This repository is the umbrella workspace for the OCI management tools below. Each project remains an independent Git repository and is included here as a pinned Git submodule.

| Project | Location | Purpose |
| --- | --- | --- |
| OCI Management Portal | `projects/oci-management-portal` | Management portal application |
| Tag Updater | `projects/tag-updater` | OCI resource tag updater |
| OCI Extirpater | `projects/ociextirpater` | OCI resource cleanup utility |

## Clone the workspace

Clone the umbrella repository and all project sources in one command:

```bash
git clone --recurse-submodules https://github.com/flynnkc/oci-tidy-portal.git
```

For an existing clone, initialize or update every project with:

```bash
git submodule update --init --recursive
```

## Work with a project

Each directory under `projects/` has its own branch, history, remotes, and development instructions. Enter the relevant directory before making project changes:

```bash
cd projects/oci-management-portal
```

After committing and pushing changes in a submodule, return to this repository and commit the updated submodule reference:

```bash
cd ../..
git add projects/oci-management-portal
git commit -m "chore: update oci-management-portal reference"
```

To bring every submodule forward to its configured remote branch, run:

```bash
git submodule update --remote --recursive
```

Review and commit the resulting submodule-reference updates deliberately; the umbrella repository pins the exact component revisions used together.

## Workspace helpers

Reusable workspace tasks live in [`scripts/`](scripts/). See the
[helper-script guide](scripts/README.md), including the OCIR image build and
push helper.

## Deployment

Use the [umbrella deployment guide](DEPLOYMENT_GUIDE.md) for the ordered,
end-to-end production deployment of the Portal and its optional Tag Updater and
Extirpater components.
