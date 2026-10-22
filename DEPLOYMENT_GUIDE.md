# OCI Tidy Portal Deployment Guide

This is the production deployment runbook for the OCI Tidy Portal workspace.
It deploys and connects the independently versioned projects pinned by this
umbrella repository:

| Component | Deployment target | Purpose |
| --- | --- | --- |
| OCI Management Portal | Helm on OKE | Authenticated interface for resource discovery and lifecycle actions |
| Tag Updater | Helm CronJob on OKE | Periodically updates defined-tag defaults |
| OCI Extirpater | Helm CronJob on OKE | Scheduled cleanup of explicitly selected compartments |

Deploy the Portal, Tag Updater, and Extirpater together. Tag Updater maintains
the configured tag defaults, and Extirpater performs scheduled cleanup in its
explicitly selected compartments. Review each component's IAM scope and
schedule. Extirpater deletes resources, so install its CronJob suspended while
reviewing its targets and permissions, then enable it to complete deployment.

The deployable infrastructure and charts are owned by this repository:

- [Terraform infrastructure](deploy/terraform/)
- [OCI Management Portal chart](deploy/helm/oci-management-portal/)
- [Tag Updater chart](deploy/helm/tag-updater/)
- [OCI Extirpater chart](deploy/helm/ociextirpater/)

## Table of Contents

1. [Deployment architecture and order](#deployment-architecture-and-order)
2. [Prerequisites](#prerequisites)
3. [Prepare the pinned release](#prepare-the-pinned-release)
4. [Collect configuration inputs](#collect-configuration-inputs)
5. [Provision Portal infrastructure](#provision-portal-infrastructure)
6. [Prepare OKE and OCIR](#prepare-oke-and-ocir)
7. [Build and publish images](#build-and-publish-images)
8. [Deploy the Portal](#deploy-the-portal)
9. [Deploy Tag Updater](#deploy-tag-updater)
10. [Deploy Extirpater](#deploy-extirpater)
11. [Validate the environment](#validate-the-environment)
12. [Operate and update the release](#operate-and-update-the-release)
13. [Troubleshooting](#troubleshooting)

## Deployment architecture and order

```text
Umbrella repository (pinned source submodule commits + central deployment assets)
  ├── deploy/terraform → OCI Identity Domain, networking, OKE, IAM baseline
  ├── OCIR ← Portal image + Tag Updater image + Extirpater image
  ├── Portal Helm chart → OKE Deployment + Service; instance or workload principal
  ├── Tag Updater Helm chart → OKE CronJob + instance principal or workload identity
  └── Extirpater Helm chart → OKE CronJob; instance or workload principal
```

Use this order for a new environment:

1. Clone the umbrella release and initialize the exact submodule revisions.
2. Decide the managed tags, cleanup compartment, and IAM scopes and schedules
   for Tag Updater and Extirpater.
3. Provision the Portal's OKE, networking, Identity Domain application, and
   baseline IAM through OCI Resource Manager using `deploy/terraform`.
4. Create OCIR repositories, publish all three images, and deploy the Portal.
5. Deploy Tag Updater after configuring the instance
   principal or workload identity for the selected cluster type.
6. Install Extirpater as a suspended OKE CronJob using the selected cluster's
   identity track, then enable it after its schedule, delete permissions, and
   cleanup target are reviewed.

## Prerequisites

### OCI access

The deployment operator needs access to create or use the following in the
target tenancy:

- a deployment compartment for OKE, networking, load balancers, and OCIR
  repositories;
- a cleanup compartment, including approval to perform lifecycle actions there;
- an OCI Identity Domain for the Portal's confidential OIDC application;
- OCIR repositories;
- IAM policies and dynamic groups for basic OKE, or workload-identity policies
  for enhanced OKE;
- Resource Manager stacks and plan/apply jobs in the deployment compartment;

Use a dedicated deployment compartment where practical. Do not use that same
compartment as Extirpater's cleanup target unless the resulting deletion scope
is explicitly intended and approved.

### Operator workstation

Install and configure:

- Git with submodule support;
- OCI CLI, authenticated to the target tenancy;
- OCI Console access;
- `kubectl` and `helm` for the target OKE cluster;
- Docker with Buildx or Podman;

The workspace helper scripts are Bash scripts. On Windows, run them from WSL,
not PowerShell or Command Prompt, and ensure Docker or Podman is accessible
inside the WSL distribution.

### OCI design decisions to make before deployment

- OCI region and tenancy home region;
- deployment and cleanup compartment OCIDs;
- OKE worker architecture (`linux/arm64`, `linux/amd64`, or both);
- basic OKE with worker-node instance principals, or enhanced OKE with
  workload identity for all three components;
- Portal public URL and TLS/ingress approach;
- Identity Domain OCID;
- defined-tag namespace/key and expiry namespace/key used by the Portal;
- Tag Updater schedule, target compartments, and tag default values;
- Extirpater's approved cleanup target, resource categories,
  exclusions, and CronJob schedule.

## Prepare the pinned release

Clone and initialize all projects. This preserves the component revisions that
were tested together in the umbrella repository.

```bash
git clone --recurse-submodules https://github.com/flynnkc/oci-tidy-portal.git
cd oci-tidy-portal
git submodule status
```

For an existing clone:

```bash
git submodule update --init --recursive
git submodule status
```

The output must show a commit for each project without a leading `-`. Do not
use `git submodule update --remote` for a production deployment unless you are
intentionally creating and validating a new umbrella release.

## Collect configuration inputs

Set non-secret, session-scoped values before starting. Replace every placeholder
with an environment-specific value.

```bash
export OCI_REGION="us-ashburn-1"
export OCI_HOME_REGION="<tenancy-home-region>"
export TENANCY_OCID="ocid1.tenancy.oc1..<unique-id>"
export DEPLOYMENT_COMPARTMENT_OCID="ocid1.compartment.oc1..<unique-id>"
export CLEANUP_COMPARTMENT_OCID="ocid1.compartment.oc1..<unique-id>"
export IDENTITY_DOMAIN_OCID="ocid1.domain.oc1..<unique-id>"
export PORTAL_URL="https://portal.example.com"
export PORTAL_CERTIFICATE_OCID="ocid1.certificate.oc1..<unique-id>"
export TAG_NAMESPACE="Usage-Management"
export TAG_KEY="Owner"
export EXPIRY_NAMESPACE="Usage-Management"
export EXPIRY_KEY="Expires"
export OCIR_NAMESPACE="$(oci os ns get --query data --raw-output)"
export REGISTRY="iad.ocir.io" # OCIR host for OCI_REGION; replace for other regions
export OCIR_USERNAME="<namespace>/<identity-domain>/<username>"
export PORTAL_REPOSITORY="oci-management-portal"
export TAG_UPDATER_REPOSITORY="tag-updater"
export EXTIRPATER_REPOSITORY="ociextirpater"
export PORTAL_TAG="$(git -C projects/oci-management-portal rev-parse --short HEAD)"
export TAG_UPDATER_TAG="$(git -C projects/tag-updater rev-parse --short HEAD)"
export EXTIRPATER_TAG="$(git -C projects/ociextirpater rev-parse --short HEAD)"
```

## Provision Portal infrastructure

The Terraform configuration in `deploy/terraform/` creates the
OKE/networking baseline and configures the Identity Domain confidential
application and identity-propagation trust. Use OCI Resource Manager for the
deployment stack. The Terraform or OpenTofu CLI is a backup path for a separate
deployment whose state is managed locally.

Use these inputs for either method:

| Stack variable | Value |
| --- | --- |
| `compartment_ocid` | `${DEPLOYMENT_COMPARTMENT_OCID}` |
| `oke_cluster_type` | `BASIC_CLUSTER` for instance principals (default), or `ENHANCED_CLUSTER` for workload identity |
| `identity_domain_id` | `${IDENTITY_DOMAIN_OCID}` |
| `label` | A unique environment prefix, such as `tidy-prod` |
| `confidential_application_base_url` | `${PORTAL_URL}` |
| `worker_ssh_public_key` | Operator public key, if node access is needed |
| Worker shape, OCPU, memory, and Kubernetes version | Values approved for the environment |

Select the cluster type before applying the stack; use the corresponding
identity track in each component section below. Review the networking inputs,
particularly API endpoint exposure, permitted ingress CIDRs, and load balancer
ingress. The supplied
`schema.yaml` presents the stack variables in Resource Manager.

### Primary method: OCI Resource Manager

**Deploy to Oracle Cloud button: coming soon.** The button will open OCI
Resource Manager with this infrastructure configuration selected.

When the button is available:

1. Select **Deploy to Oracle Cloud** and sign in to the target tenancy. On
   **Create stack**, select the deployment compartment, name the stack, and
   choose a Terraform version supported by `deploy/terraform/versions.tf`.
2. On **Configure variables**, enter the values above. Confirm the target
   region and tenancy, and review the network and OKE settings. Do not enter
   an API signing key in stack variables; Resource Manager authenticates the
   provider for its jobs.
3. On **Review**, clear **Run apply** so you can inspect the changes first,
   then create the stack. Run a **Plan** job and review its proposed resources.
   If it matches the intended deployment, run an **Apply** job and wait for it
   to succeed.
4. Open the completed apply job's **Outputs** page and record the values listed
   under [Use the infrastructure outputs](#use-the-infrastructure-outputs).

See Oracle's [button workflow](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Tasks/deploybutton.htm)
and [job outputs instructions](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Tasks/list-job-outputs.htm)
for the current Console screens.

### Backup method: Terraform or OpenTofu CLI

Use this method when the Resource Manager button is unavailable. Install
Terraform (version 1.3 or later) or OpenTofu and configure OCI provider
authentication for the target tenancy. Run the commands from the umbrella
repository root:

```bash
cp deploy/terraform/terraform.tfvars.example deploy/terraform/terraform.tfvars
```

Edit the ignored `deploy/terraform/terraform.tfvars` with the inputs above.
Set `tenancy_ocid` to the value of `TENANCY_OCID` and `region` to the value of
`OCI_REGION`. Keep `oke_cluster_type = "BASIC_CLUSTER"` for the instance-principal
tracks, or set it to `"ENHANCED_CLUSTER"` for the workload-identity tracks.
Review the plan carefully before changing the type of an existing cluster.
Review the network settings in that file. Then select one CLI and apply:

```bash
export IAC_CLI=terraform # or tofu for OpenTofu
"$IAC_CLI" -chdir=deploy/terraform init
"$IAC_CLI" -chdir=deploy/terraform plan -out=tfplan
"$IAC_CLI" -chdir=deploy/terraform apply tfplan
```

Read the non-secret outputs with `"$IAC_CLI" -chdir=deploy/terraform output`
and retrieve the client secret securely. Keep the CLI state for this deployment
separate from any Resource Manager stack state.

### Use the infrastructure outputs

Record these outputs securely after the apply completes:

- `identity_domain_endpoint`
- `confidential_application_client_id`
- `confidential_application_client_secret`
- `oke_cluster_ocid` and `oke_cluster_type`

Set the non-secret chart inputs in your shell before deploying the Portal:

```bash
export PORTAL_IDM_ENDPOINT="<identity_domain_endpoint output>"
export PORTAL_CLIENT_ID="<confidential_application_client_id output>"
```

For a CLI deployment, you can instead populate them directly from state:

```bash
export PORTAL_IDM_ENDPOINT="$("$IAC_CLI" -chdir=deploy/terraform output -raw identity_domain_endpoint)"
export PORTAL_CLIENT_ID="$("$IAC_CLI" -chdir=deploy/terraform output -raw confidential_application_client_id)"
```

If the initial Portal URL is temporary, update the Identity Domain redirect URI
and post-logout URI after the final load balancer or ingress URL is known. The
callback URL is `${PORTAL_URL}/callback`.

## Prepare OKE and OCIR

### Configure Kubernetes access

Use the [OKE cluster page in OCI Console](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengaccessingclusterkubectl.htm) to obtain the cluster's
kubeconfig access command. If `enable_external_kubectl_access = true`, select
the public endpoint when generating kubeconfig and connect from an address in
`external_kubectl_access_cidr`. Otherwise, use a route into the VCN, such as
[OCI Bastion](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupbastion.htm).
Then verify connectivity:

```bash
kubectl config current-context
kubectl get nodes
kubectl get pods -A
```

Confirm worker architecture before building images:

```bash
kubectl get nodes -o wide
kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}'
```

Build `linux/arm64` for arm64 nodes, `linux/amd64` for amd64 nodes, or a
multi-architecture image for mixed pools.

### Create OCIR repositories

Create the three OCIR repositories if they do not already exist. With the
configuration defaults above, create these exact repository names:
`oci-management-portal`, `tag-updater`, and `ociextirpater`. If you override a
`*_REPOSITORY` value (for example, to use `platform/tag-updater`), create that
exact path instead; it must match the image reference used by the build helper
and Helm.

```bash
oci artifacts container repository create \
  --compartment-id "${DEPLOYMENT_COMPARTMENT_OCID}" \
  --display-name "${PORTAL_REPOSITORY}"

oci artifacts container repository create \
  --compartment-id "${DEPLOYMENT_COMPARTMENT_OCID}" \
  --display-name "${TAG_UPDATER_REPOSITORY}"

oci artifacts container repository create \
  --compartment-id "${DEPLOYMENT_COMPARTMENT_OCID}" \
  --display-name "${EXTIRPATER_REPOSITORY}"
```

If a repository already exists, continue.

## Build and publish images

Use the workspace helper rather than duplicating Docker/Podman commands. One
invocation builds and publishes the Dockerfiles in all three submodules. It
supports Docker Buildx, Podman, OCIR namespace lookup, and multi-architecture
manifests. Pass `--engine podman` to select Podman; otherwise `auto` selects
Docker when available. Each image defaults to its submodule's short Git SHA;
use `--tag` to apply one tag to every image, or `--*-tag` to override one image.

Generate an OCI auth token, then authenticate and build/push all three images
in one command. `--login` prompts for the token unless `OCIR_AUTH_TOKEN` is set
only for the current shell session:

```bash
scripts/build-and-push-image.sh --login \
  --registry "${REGISTRY}" \
  --platform linux/arm64
```

The helper obtains the OCIR tenancy namespace with `oci os ns get` when
`--namespace` and `OCIR_NAMESPACE` are not supplied. Consult the [OCIR username guidance](https://docs.oracle.com/en-us/iaas/Content/Registry/Tasks/registrypushingimagesusingthedockercli.htm)
for the exact default-domain or identity-domain username format.
The same `REGISTRY` value is used for image builds, pull secrets, and Helm image
references.

For mixed node architectures, replace the platform value with
`linux/amd64,linux/arm64`. See [scripts/README.md](scripts/README.md) for all
options.

## Deploy the Portal

### Create the namespace and image-pull secret

```bash
export PORTAL_NAMESPACE="oci-management-portal"
kubectl create namespace "${PORTAL_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

printf 'OCIR auth token: '
IFS= read -r -s OCIR_AUTH_TOKEN
printf '\n'
if [[ -z "${REGISTRY:-}" || -z "${OCIR_USERNAME:-}" || -z "${OCIR_AUTH_TOKEN:-}" ]]; then
  printf 'Set REGISTRY, OCIR_USERNAME, and a non-empty OCIR_AUTH_TOKEN before creating the pull secret.\n' >&2
else
  kubectl create secret docker-registry ocirsecret \
    --namespace "${PORTAL_NAMESPACE}" \
    --docker-server="${REGISTRY}" \
    --docker-username="${OCIR_USERNAME}" \
    --docker-password="${OCIR_AUTH_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi
unset OCIR_AUTH_TOKEN
```

Create a Kubernetes secret for the confidential application client secret. The
value comes from the Terraform output and should not be committed.

```bash
printf 'Portal OIDC client secret: '
IFS= read -r -s PORTAL_CLIENT_SECRET
printf '\n'
kubectl create secret generic oci-management-portal-secrets \
  --namespace "${PORTAL_NAMESPACE}" \
  --from-literal=OCI_MGMT_DASH_CLIENT_SECRET="${PORTAL_CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
unset PORTAL_CLIENT_SECRET
```

### Configure the Portal HTTPS certificate

The Portal chart exposes the OCI load balancer on HTTPS port 443 and uses
[OCI Certificates](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengcreatingloadbalancers-subtopic.htm)
by default. In the OCI Console, open **Identity & Security > Certificates**.
Select an active certificate for the hostname in `PORTAL_URL`, or
[create](https://docs.oracle.com/en-us/iaas/Content/certificates/creating-certificate.htm)
or [import](https://docs.oracle.com/en-us/iaas/Content/certificates/importing-certificate.htm)
one. Record its **leaf certificate OCID** as `PORTAL_CERTIFICATE_OCID`. The
certificate must be in the same region as the load balancer.

Grant the OKE cluster resource principal access to the certificate's
compartment. Create this IAM policy in OCI if an equivalent policy is not
already in place; replace both OCID placeholders with the actual values:

```text
Allow any-user to manage certificate-authority-family in compartment id <certificate-compartment-ocid> where all {request.principal.type = 'cluster', request.principal.id = '<oke-cluster-ocid>'}
```

Helm creates the listener certificate mapping ConfigMap in the Portal namespace
from `PORTAL_CERTIFICATE_OCID` and connects it to the Service. The chart also
enables OCI application cookie session persistence using the Portal's `omid`
cookie. Use Redis for shared Portal session storage when running multiple
Portal replicas.

#### Kubernetes TLS Secret alternative

If you manage certificates in Kubernetes, set `PORTAL_CERTIFICATE_OCID` to an
empty string and add
`service.beta.kubernetes.io/oci-load-balancer-tls-secret: portal-tls` under
`service.annotations` in `values.local.yaml`. Create that Secret in the Portal
namespace using the certificate and private key for `PORTAL_URL`:

```bash
kubectl create secret tls portal-tls \
  --namespace "${PORTAL_NAMESPACE}" \
  --cert=/path/to/fullchain.pem \
  --key=/path/to/privkey.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

**Testing only — self-signed certificate (do not use in production).** If you
do not yet have a certificate for a test deployment, generate one for the
hostname in `PORTAL_URL` and upload it as the `portal-tls` Kubernetes Secret:

```bash
PORTAL_HOST="${PORTAL_URL#https://}"
PORTAL_HOST="${PORTAL_HOST%%/*}"
PORTAL_HOST="${PORTAL_HOST%%:*}"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 7 \
  -keyout portal-test.key \
  -out portal-test.crt \
  -subj "/CN=${PORTAL_HOST}" \
  -addext "subjectAltName=DNS:${PORTAL_HOST}"
kubectl create secret tls portal-tls \
  --namespace "${PORTAL_NAMESPACE}" \
  --cert=portal-test.crt \
  --key=portal-test.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

Browsers will warn that this certificate is untrusted. Replace it with a
certificate issued by a trusted CA before production use.

If you use another Secret name, set the annotation to that name. OCI cannot
provision the load balancer if a TLS Secret and an OCI certificate mapping are
configured together.

### Configure runtime IAM

The Portal uses the signed-in user's context for Portal actions. Cost and usage
operations use its configured runtime identity. Choose the track matching the
OKE cluster. The chart defaults to the basic-cluster settings.

#### Track 1: Basic OKE cluster — instance principal (default)

Create a dynamic group containing the worker nodes that run the Portal (or
their dedicated compartment). For example:

```text
ALL {instance.compartment.id = '<worker-node-compartment-ocid>'}
```

Grant the dynamic group only the permissions needed by enabled Portal features.
These examples support cost and compartment discovery; add narrowly scoped
resource-family permissions only for approved runtime operations:

```text
Allow dynamic-group <portal-node-dynamic-group> to read usage-reports in tenancy
Allow dynamic-group <portal-node-dynamic-group> to inspect compartments in tenancy
```

Instance-principal permissions apply to every workload placed on a matching
node. Use a dedicated node pool or compartment if this identity must not be
shared with other workloads. Start with the Portal component guide's runtime
IAM section, then scope policies to the cleanup compartment rather than tenancy
where possible.

The chart defaults to `config.authType: instance_principal`, uses the default
Kubernetes service account, and does not mount its token. Keep these defaults
in `values.local.yaml` for a basic cluster.

#### Track 2: Enhanced OKE cluster — workload identity

Use the Portal namespace `oci-management-portal` and the chart-created service
account `oci-management-portal` with the Helm release name in this guide. Grant
the workload the runtime permissions needed by the enabled Portal features;
for the cost and compartment discovery examples above:

```text
Allow any-user to read usage-reports in tenancy where all {request.principal.type = 'workload', request.principal.namespace = 'oci-management-portal', request.principal.service_account = 'oci-management-portal', request.principal.cluster_id = '<cluster-ocid>'}
Allow any-user to inspect compartments in tenancy where all {request.principal.type = 'workload', request.principal.namespace = 'oci-management-portal', request.principal.service_account = 'oci-management-portal', request.principal.cluster_id = '<cluster-ocid>'}
```

Set these fields in `values.local.yaml` to select workload identity:

```yaml
config:
  authType: workload_principal
serviceAccount:
  create: true
  automountServiceAccountToken: true
```

The chart then creates the service account and mounts its token into Portal
pods. Add narrowly scoped resource-family permissions for any other approved
Portal features.

### Install the Helm release

Create `deploy/helm/oci-management-portal/values.local.yaml` from the chart's
`values.yaml` defaults. Set deployment-specific options such as the session
backend and the selected identity track there. The chart's HTTPS listener and
OCI session persistence settings are already enabled. The Helm command below
supplies the certificate OCID,
image, public URL, tag settings, cleanup compartment, and Identity Domain
values collected earlier.
Helm does not read these shell variables automatically; the `--set-string`
arguments pass them into the chart.
The chart defaults to the `ocirsecret` image-pull secret and the existing
`oci-management-portal-secrets` client secret created above. For more than one
Portal replica, use Redis or Valkey rather than filesystem sessions.

To deploy Redis with the Portal chart, set `redis.enabled: true` in
`values.local.yaml`. The chart uses `docker.io/library/redis:7.0-alpine`,
creates a Redis Deployment and an internal Service, and configures the Portal
session backend and URL automatically. The Redis pod uses temporary storage;
restarting it ends active sessions. For password protection, add an
`OCI_MGMT_DASH_SESSION_REDIS_PASSWORD` key to the existing
`oci-management-portal-secrets` Kubernetes Secret and set
`redis.auth.enabled: true`. Keep the password out of `values.local.yaml`.

If Redis is managed separately, leave `redis.enabled: false` and set
`config.sessionBackend: redis` plus `config.sessionRedisUrl` to that Service's
Redis URL. Keep credentials in the Kubernetes Secret rather than the URL.
For a custom `config.logFormat`, use a Python logging format string such as
`%(asctime)s - %(name)s - %(levelname)s - %(message)s`.

```bash
helm upgrade --install oci-management-portal \
  ./deploy/helm/oci-management-portal \
  --namespace "${PORTAL_NAMESPACE}" \
  -f deploy/helm/oci-management-portal/values.local.yaml \
  --set-string image.repository="${REGISTRY}/${OCIR_NAMESPACE}/${PORTAL_REPOSITORY}" \
  --set-string image.tag="${PORTAL_TAG}" \
  --set-string service.tlsCertificateOcid="${PORTAL_CERTIFICATE_OCID}" \
  --set-string config.appUri="${PORTAL_URL}" \
  --set-string config.tagNamespace="${TAG_NAMESPACE}" \
  --set-string config.tagKey="${TAG_KEY}" \
  --set-string config.filterNamespace="${EXPIRY_NAMESPACE}" \
  --set-string config.filterKey="${EXPIRY_KEY}" \
  --set-string config.cleanupCompartment="${CLEANUP_COMPARTMENT_OCID}" \
  --set-string config.idmEndpoint="${PORTAL_IDM_ENDPOINT}" \
  --set-string config.clientId="${PORTAL_CLIENT_ID}"
```

## Deploy Tag Updater

Select the track for your OKE cluster: **instance principal for a basic cluster** (the
chart default), or **workload identity for an enhanced cluster**. Basic clusters
do not support workload identity. Configure only the selected track's IAM
policy and Helm settings. Review the permissions before applying them: Tag
Updater can change tag defaults in every permitted scope.

### Shared setup: create the namespace and pull secret

```bash
export TAG_UPDATER_NAMESPACE="tag-updater"
kubectl create namespace "${TAG_UPDATER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

printf 'OCIR auth token: '
IFS= read -r -s OCIR_AUTH_TOKEN
printf '\n'
if [[ -z "${REGISTRY:-}" || -z "${OCIR_USERNAME:-}" || -z "${OCIR_AUTH_TOKEN:-}" ]]; then
  printf 'Set REGISTRY, OCIR_USERNAME, and a non-empty OCIR_AUTH_TOKEN before creating the pull secret.\n' >&2
else
  kubectl create secret docker-registry ocir-pull-secret \
    --namespace "${TAG_UPDATER_NAMESPACE}" \
    --docker-server="${REGISTRY}" \
    --docker-username="${OCIR_USERNAME}" \
    --docker-password="${OCIR_AUTH_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi
unset OCIR_AUTH_TOKEN
```

Review the schedule before installing; the chart default is daily at midnight.
Set `config.compartments` only when the job must be constrained to specific
compartments. Omit it only when tenancy-wide tag-default updates are intended.
`config.tagKey` is the defined tag whose default Tag Updater changes; the
examples use the expiry key rather than the Portal's owner tag.

### Track 1: Basic OKE cluster — instance principal (default)

Create a dynamic group for the worker-node instances that run Tag Updater. A
compartment-based membership rule works for a dedicated node compartment:

```text
ALL {instance.compartment.id = '<tag-updater-node-compartment-ocid>'}
```

Grant that dynamic group the tag permissions:

```text
Allow dynamic-group <tag-updater-node-dynamic-group> to manage tag-defaults in tenancy
Allow dynamic-group <tag-updater-node-dynamic-group> to use tag-namespaces in tenancy
```

Every pod on a matching node can use that node's instance principal. Use a
dedicated node pool or compartment when this scope must be isolated. The chart
defaults to `INSTANCE_PRINCIPAL` and does not mount a service-account token.
Install the CronJob with the instance-principal signer explicit:

```bash
helm upgrade --install tag-updater \
  ./deploy/helm/tag-updater \
  --namespace "${TAG_UPDATER_NAMESPACE}" \
  --set-string image.repository="${REGISTRY}/${OCIR_NAMESPACE}/${TAG_UPDATER_REPOSITORY}" \
  --set-string image.tag="${TAG_UPDATER_TAG}" \
  --set-string config.tagNamespace="${EXPIRY_NAMESPACE}" \
  --set-string config.tagKey="${EXPIRY_KEY}" \
  --set-string config.ociSigner="INSTANCE_PRINCIPAL" \
  --set-string config.ociIdentityRegion="${OCI_HOME_REGION}" \
  --set-string config.ociResourcePrincipalRegion="${OCI_REGION}" \
  --set-string config.ociTenancyId="${TENANCY_OCID}" \
  --set-string imagePullSecrets="ocir-pull-secret"
```

### Track 2: Enhanced OKE cluster — workload identity

Obtain the cluster OCID and choose the Kubernetes namespace and service-account
names. With this release name, the chart creates the service account
`tag-updater`. Create IAM policies with the exact cluster OCID and names:

```text
Allow any-user to manage tag-defaults in tenancy where all {
  request.principal.type = 'workload',
  request.principal.namespace = 'tag-updater',
  request.principal.service_account = 'tag-updater',
  request.principal.cluster_id = '<cluster-ocid>'
}
Allow any-user to use tag-namespaces in tenancy where all {
  request.principal.type = 'workload',
  request.principal.namespace = 'tag-updater',
  request.principal.service_account = 'tag-updater',
  request.principal.cluster_id = '<cluster-ocid>'
}
```

Install the CronJob with its service account and token enabled for workload
identity:

```bash
helm upgrade --install tag-updater \
  ./deploy/helm/tag-updater \
  --namespace "${TAG_UPDATER_NAMESPACE}" \
  --set-string image.repository="${REGISTRY}/${OCIR_NAMESPACE}/${TAG_UPDATER_REPOSITORY}" \
  --set-string image.tag="${TAG_UPDATER_TAG}" \
  --set-string config.tagNamespace="${EXPIRY_NAMESPACE}" \
  --set-string config.tagKey="${EXPIRY_KEY}" \
  --set-string config.ociSigner="WORKLOAD_IDENTITY" \
  --set-string config.ociIdentityRegion="${OCI_HOME_REGION}" \
  --set-string config.ociResourcePrincipalRegion="${OCI_REGION}" \
  --set-string config.ociTenancyId="${TENANCY_OCID}" \
  --set serviceAccount.create=true \
  --set serviceAccount.automountServiceAccountToken=true \
  --set-string imagePullSecrets="ocir-pull-secret"
```

### Test the selected track

Run an immediate, observable test before relying on the schedule:

```bash
kubectl create job --from=cronjob/tag-updater tag-updater-smoke-test \
  --namespace "${TAG_UPDATER_NAMESPACE}"
kubectl get jobs --namespace "${TAG_UPDATER_NAMESPACE}"
kubectl logs --namespace "${TAG_UPDATER_NAMESPACE}" job/tag-updater-smoke-test
```

## Deploy Extirpater

Extirpater runs as an OKE CronJob from `deploy/helm/ociextirpater/`; its chart
is suspended by default for initial review. Complete this section to enable
scheduled cleanup. Select the instance-principal track for a basic OKE cluster
or the workload-identity track for an enhanced cluster.

### Shared setup: create the namespace and pull secret

```bash
export EXTIRPATER_NAMESPACE="ociextirpater"
kubectl create namespace "${EXTIRPATER_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

printf 'OCIR auth token: '
IFS= read -r -s OCIR_AUTH_TOKEN
printf '\n'
if [[ -z "${REGISTRY:-}" || -z "${OCIR_USERNAME:-}" || -z "${OCIR_AUTH_TOKEN:-}" ]]; then
  printf 'Set REGISTRY, OCIR_USERNAME, and a non-empty OCIR_AUTH_TOKEN before creating the pull secret.\n' >&2
else
  kubectl create secret docker-registry ocir-pull-secret \
    --namespace "${EXTIRPATER_NAMESPACE}" \
    --docker-server="${REGISTRY}" \
    --docker-username="${OCIR_USERNAME}" \
    --docker-password="${OCIR_AUTH_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi
unset OCIR_AUTH_TOKEN
```

Create the ignored `deploy/helm/ociextirpater/values.local.yaml` from the
chart's `values.yaml`. Set at least one `config.compartments` OCID, approved
`config.objects` and `config.regions`, a reviewed schedule, and the pull secret:

```yaml
imagePullSecrets:
  - name: ocir-pull-secret
config:
  compartments:
    - ocid1.compartment.oc1..<approved-target>
cronJob:
  suspend: true
```

Keep `cronJob.suspend: true` while configuring the selected identity track.
Grant only the resource-family permissions needed for the approved object
categories and target compartments.

### Track 1: Basic OKE cluster — instance principal (default)

Create a dynamic group for the worker-node instances that run Extirpater. For
nodes in a dedicated compartment, use this membership rule:

```text
ALL {instance.compartment.id = '<extirpater-node-compartment-ocid>'}
```

Grant the dynamic group the approved delete permissions, repeating the policy
for each required resource family and target compartment:

```text
Allow dynamic-group <extirpater-node-dynamic-group> to manage <approved-resource-family> in compartment id <approved-target-compartment-ocid>
```

The chart defaults to `config.authType: instance_principal` and does not mount
a service-account token. These node permissions are available to other pods on
matching nodes; isolate the nodes when that shared scope is unacceptable.

### Track 2: Enhanced OKE cluster — workload identity

With the namespace and release name in this guide, the chart creates service
account `ociextirpater`. Grant permissions to that exact workload, repeating
the policy for each approved resource family and target compartment:

```text
Allow any-user to manage <approved-resource-family> in compartment id <approved-target-compartment-ocid> where all {request.principal.type = 'workload', request.principal.namespace = 'ociextirpater', request.principal.service_account = 'ociextirpater', request.principal.cluster_id = '<cluster-ocid>'}
```

Set these fields in `values.local.yaml`:

```yaml
config:
  authType: workload_identity
serviceAccount:
  create: true
  automountServiceAccountToken: true
```

### Install and review the suspended CronJob

After configuring the selected track, install the suspended release:

```bash
helm upgrade --install ociextirpater \
  ./deploy/helm/ociextirpater \
  --namespace "${EXTIRPATER_NAMESPACE}" \
  --values deploy/helm/ociextirpater/values.local.yaml \
  --set-string image.repository="${REGISTRY}/${OCIR_NAMESPACE}/${EXTIRPATER_REPOSITORY}" \
  --set-string image.tag="${EXTIRPATER_TAG}" \
  --set-string config.tenancy="${TENANCY_OCID}"
```

Confirm that the CronJob is suspended and inspect the rendered signer setting:

```bash
kubectl get cronjob ociextirpater --namespace "${EXTIRPATER_NAMESPACE}"
helm template ociextirpater ./deploy/helm/ociextirpater \
  --namespace "${EXTIRPATER_NAMESPACE}" \
  --values deploy/helm/ociextirpater/values.local.yaml \
  --set-string image.repository="${REGISTRY}/${OCIR_NAMESPACE}/${EXTIRPATER_REPOSITORY}" \
  --set-string config.tenancy="${TENANCY_OCID}"
```

Only after independently validating the target compartments, object categories,
selected principal, IAM policy, image, and schedule, set
`cronJob.suspend: false` in the local values file and run `helm upgrade` again.
A successful installation is not approval to delete resources.

## Validate the environment

### Portal

```bash
kubectl rollout status deployment/oci-management-portal --namespace "${PORTAL_NAMESPACE}"
kubectl get pods,svc --namespace "${PORTAL_NAMESPACE}"
kubectl logs deployment/oci-management-portal --namespace "${PORTAL_NAMESPACE}" --tail=100
```

Open `${PORTAL_URL}`, complete an OIDC login, and validate the least-privilege
workflow in a non-production test compartment before performing lifecycle
actions in the cleanup target. Confirm the callback URL is exactly
`${PORTAL_URL}/callback` in the Identity Domain application.

### Tag Updater

```bash
kubectl get cronjob,jobs --namespace "${TAG_UPDATER_NAMESPACE}"
kubectl logs --namespace "${TAG_UPDATER_NAMESPACE}" job/tag-updater-smoke-test
```

Verify the tag default changed only in the intended scope. Investigate any
authentication error against the selected track: node dynamic-group membership
and IAM policy for basic clusters, or workload identity policy and
namespace/service-account/cluster names for enhanced clusters.

### Extirpater

Confirm the CronJob is enabled after the scope and permissions review. After a
controlled run, inspect the Job logs and confirm the cleanup target is the
intended compartment:

```bash
kubectl get cronjob,jobs --namespace "${EXTIRPATER_NAMESPACE}"
kubectl logs --namespace "${EXTIRPATER_NAMESPACE}" job/<job-name>
```

## Operate and update the release

The umbrella repository pins exact component revisions. To upgrade a component:

1. Update and test that submodule in its own repository.
2. Commit and push the submodule change there.
3. Update the umbrella submodule reference and commit it as a new umbrella
   release.
4. Build images from the new pinned revision using a new immutable tag.
5. Run `helm upgrade` with the new tag and validate rollout before retiring the
   prior image.

Do not rely on `latest` in production. Record the umbrella commit, all three
submodule commits, image tags/digests, Terraform plan/apply metadata, Helm
release revisions, and the applied IAM policy names in the change record.

## Troubleshooting

| Symptom | Initial checks |
| --- | --- |
| `exec format error` in a pod | Compare node architecture with the image platform; rebuild for the target architecture or publish a multi-architecture manifest. |
| Pod cannot pull from OCIR | Check registry host, image repository/tag, `ocirsecret`, OCIR username format, auth token, and repository permissions. |
| Portal login redirects or fails | Verify `${PORTAL_URL}/callback`, Identity Domain endpoint/client ID/client secret, and proxy configuration. |
| Portal pod starts but OCI calls fail | On basic OKE, check `instance_principal`, worker-node dynamic-group membership, and IAM policy. On enhanced OKE, check `workload_principal`, service account, cluster OCID, and workload IAM policy. |
| Tag Updater job fails authentication | On basic OKE, check `INSTANCE_PRINCIPAL`, worker-node dynamic-group membership, and IAM policy. On enhanced OKE, check `WORKLOAD_IDENTITY`, cluster OCID, namespace, service account, and IAM policy. |
| Extirpater does not run | Check whether the CronJob is suspended, its schedule, Job events, and image pull secret. For OCI authentication, check node dynamic-group membership on basic OKE or the service account and workload IAM policy on enhanced OKE. |

For component behavior and troubleshooting beyond this deployment flow, consult
the source project documentation pinned under `projects/`.
