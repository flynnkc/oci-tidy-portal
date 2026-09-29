# OCI Tidy Portal

This repository is the umbrella workspace for the OCI management tools below. Each project remains an independent Git repository and is included here as a pinned Git submodule.

| Project | Location | Purpose |
| --- | --- | --- |
| OCI Management Portal | `projects/oci-management-portal` | Management portal application |
| Tag Updater | `projects/tag-updater` | OCI resource tag updater |
| OCI Extirpater | `projects/ociextirpater` | OCI resource cleanup utility |

## Configuration-variable reference

The Portal deployment requires the Portal and OCI environment values below.
Tag Updater and Extirpater values are required only when deploying the
corresponding optional component. Image tags default to the checked-out short
Git SHA when the image-build helper is used; setting them explicitly keeps the
build and Helm deployment commands pinned to the same image.

| Variable | Description | Projects | Required | Default value | Example value |
| --- | --- | --- | --- | --- | --- |
| `OCI_REGION` | Region containing the OCIR registry and OKE deployment. | Portal, Tag Updater, Extirpater | Yes | None | `us-ashburn-1` |
| `OCI_HOME_REGION` | Tenancy home region used by Tag Updater for Identity calls. | Tag Updater | Yes, for Tag Updater | None | `us-ashburn-1` |
| `TENANCY_OCID` | OCID of the OCI tenancy. | Tag Updater, Extirpater | Yes, for Tag Updater or Extirpater | None | `ocid1.tenancy.oc1..example` |
| `DEPLOYMENT_COMPARTMENT_OCID` | Compartment where Terraform creates the deployment infrastructure. | Shared infrastructure | Yes | None | `ocid1.compartment.oc1..example` |
| `CLEANUP_COMPARTMENT_OCID` | Compartment the Portal is allowed to clean up. | Portal | Yes, for Portal cleanup features | None | `ocid1.compartment.oc1..example` |
| `IDENTITY_DOMAIN_OCID` | OCID of the Identity Domain that authenticates Portal users. | Portal | Yes | None | `ocid1.domain.oc1..example` |
| `PORTAL_URL` | Public HTTPS URL for the Portal. | Portal | Yes | None | `https://portal.example.com` |
| `TAG_NAMESPACE` | OCI tag namespace used for Portal and Tag Updater tag configuration. | Portal, Tag Updater | Yes, for Portal or Tag Updater tag settings | None | `Usage-Management` |
| `TAG_KEY` | OCI tag key configured for the Portal. | Portal | Yes, for Portal tag settings | None | `Owner` |
| `EXPIRY_NAMESPACE` | OCI tag namespace containing the resource-expiry tag. | Portal | Yes, for Portal expiry-tag settings | None | `Usage-Management` |
| `EXPIRY_KEY` | OCI tag key that stores resource-expiry information. | Portal, Tag Updater | Yes, for Portal expiry-tag settings or Tag Updater | None | `Expires` |
| `OCIR_NAMESPACE` | Object Storage namespace used in OCIR image paths. | Portal, Tag Updater, Extirpater | Yes, to push or deploy images | `oci os ns get` output when the build helper runs | `mytenancynamespace` |
| `PORTAL_REPOSITORY` | OCIR repository name for the Portal image. | Portal | No | `oci-management-portal` | `oci-management-portal` |
| `TAG_UPDATER_REPOSITORY` | OCIR repository name for the Tag Updater image. | Tag Updater | No | `tag-updater` | `tag-updater` |
| `EXTIRPATER_REPOSITORY` | OCIR repository name for the Extirpater image. | Extirpater | No | `ociextirpater` | `ociextirpater` |
| `PORTAL_TAG` | Image tag selecting the Portal build revision. | Portal | No | Short SHA of `projects/oci-management-portal` `HEAD` | `a1b2c3d` |
| `TAG_UPDATER_TAG` | Image tag selecting the Tag Updater build revision. | Tag Updater | No | Short SHA of `projects/tag-updater` `HEAD` | `d4e5f6a` |
| `EXTIRPATER_TAG` | Image tag selecting the Extirpater build revision. | Extirpater | No | Short SHA of `projects/ociextirpater` `HEAD` | `b7c8d9e` |

Keep secrets out of shell history, Helm values committed to Git, and terminal
output. You will need an OCIR auth token and an Identity Domain client secret.

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
