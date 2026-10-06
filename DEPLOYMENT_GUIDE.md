# OCI Tidy Portal Deployment Guide

This is the production deployment runbook for the OCI Tidy Portal workspace.
It deploys and connects the independently versioned projects pinned by this
umbrella repository:

| Component | Deployment target | Purpose |
| --- | --- | --- |
| OCI Management Portal | Helm on OKE | Authenticated interface for resource discovery and lifecycle actions |
| Tag Updater | Helm CronJob on OKE | Periodically updates defined-tag defaults |
| OCI Extirpater | Suspended Helm CronJob on OKE | Scheduled cleanup of explicitly selected compartments |

The Portal is the primary deployment. Tag Updater and Extirpater are optional,
independent automation components; deploy either only after approving its IAM
scope and schedule. In particular, Extirpater deletes resources and its target
compartment must be reviewed carefully.

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
  ├── Portal Helm chart → OKE Deployment + Service
  ├── Tag Updater Helm chart → OKE CronJob + workload identity
  └── Extirpater Helm chart → suspended OKE CronJob + workload identity
```

Use this order for a new environment:

1. Clone the umbrella release and initialize the exact submodule revisions.
2. Decide the managed tags, cleanup compartment, and which optional automation
   components are approved.
3. Provision the Portal's OKE, networking, Identity Domain application, and
   baseline IAM through OCI Resource Manager using `deploy/terraform`.
4. Create OCIR repositories, publish the Portal image, and deploy the Portal.
5. Optionally publish and deploy Tag Updater after creating workload-identity
   policies.
6. Optionally install Extirpater as a suspended OKE CronJob, then enable it
   only after its schedule, delete permissions, and cleanup target are reviewed.

## Prerequisites

### OCI access

The deployment operator needs access to create or use the following in the
target tenancy:

- a deployment compartment for OKE, networking, load balancers, and OCIR
  repositories;
- a cleanup compartment, including approval to perform lifecycle actions there;
- an OCI Identity Domain for the Portal's confidential OIDC application;
- OCIR repositories;
- IAM policies, dynamic groups, and OKE workload-identity policies;
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
- Portal public URL and TLS/ingress approach;
- Identity Domain OCID;
- defined-tag namespace/key and expiry namespace/key used by the Portal;
- Tag Updater schedule, target compartments, and tag default values;
- whether Extirpater is approved, its cleanup target, resource categories,
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
| `identity_domain_id` | `${IDENTITY_DOMAIN_OCID}` |
| `label` | A unique environment prefix, such as `tidy-prod` |
| `confidential_application_base_url` | `${PORTAL_URL}` |
| `worker_ssh_public_key` | Operator public key, if node access is needed |
| Worker shape, OCPU, memory, and Kubernetes version | Values approved for the environment |

Review the networking inputs before applying, particularly API endpoint
exposure, permitted ingress CIDRs, and load balancer ingress. The supplied
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
`OCI_REGION`.
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
- OKE cluster OCID/name from the OCI Console

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

### Configure runtime IAM

The Portal uses the signed-in user's context for Portal actions. Cost and usage
operations use its configured runtime identity. For the documented
`instance_principal` configuration, create a dynamic group containing the OKE
worker nodes (or their compartment). For example:

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

### Install the Helm release

Create `deploy/helm/oci-management-portal/values.local.yaml` from the chart's
safe `values.yaml` defaults. Set deployment-specific options such as the session
backend there. The Helm command below supplies the image, public URL, tag
settings, cleanup compartment, and Identity Domain values collected earlier.
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

Skip this section if periodic tag-default updates are not approved. Choose one
runtime identity model: workload identity for an enhanced OKE cluster, or the
worker-node instance principal for a standard/basic cluster. Do not grant both
models to the same deployment.

### Create the runtime IAM policy

#### Workload identity (enhanced OKE clusters)

Obtain the cluster OCID and choose the Kubernetes namespace/service-account
names. The chart's default service-account name is the release name,
`tag-updater`. Create IAM policies following this pattern, with the exact
cluster OCID and names:

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

Narrow policy scope where OCI policy syntax supports it. Review the policy
before applying: Tag Updater can change tag defaults in every permitted scope.

#### Instance principal (basic OKE clusters)

Create a dynamic group for the node instances that run Tag Updater. A
compartment-based membership rule is convenient for a dedicated node pool:

```text
ALL {instance.compartment.id = '<tag-updater-node-compartment-ocid>'}
```

Grant that dynamic group the same tag permissions as the workload identity:

```text
Allow dynamic-group <tag-updater-node-dynamic-group> to manage tag-defaults in tenancy
Allow dynamic-group <tag-updater-node-dynamic-group> to use tag-namespaces in tenancy
```

This identity is shared by every pod on the matching nodes. Use dedicated nodes
or accept that shared scope deliberately. In the Helm command below, replace
`--set config.ociSigner="WORKLOAD_IDENTITY"` with
`--set config.ociSigner="INSTANCE_PRINCIPAL"`; no workload-identity policy is
needed for this option.

### Create the namespace and pull secret

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

### Install the CronJob

Review the schedule before running this command; the chart default is daily at
midnight. Set `config.compartments` only when the job must be constrained to
specific compartments. Omit it only when tenancy-wide tag-default updates are
intended.

```bash
helm upgrade --install tag-updater \
  ./deploy/helm/tag-updater \
  --namespace "${TAG_UPDATER_NAMESPACE}" \
  --set image.repository="${REGISTRY}/${OCIR_NAMESPACE}/${TAG_UPDATER_REPOSITORY}" \
  --set image.tag="${TAG_UPDATER_TAG}" \
  --set-string config.tagNamespace="${EXPIRY_NAMESPACE}" \
  --set-string config.tagKey="${EXPIRY_KEY}" \
  --set config.ociSigner="WORKLOAD_IDENTITY" \
  --set config.ociIdentityRegion="${OCI_HOME_REGION}" \
  --set config.ociResourcePrincipalRegion="${OCI_REGION}" \
  --set config.ociTenancyId="${TENANCY_OCID}" \
  --set imagePullSecrets=ocir-pull-secret
```

`config.tagKey` is the defined tag whose default Tag Updater changes. It need
not be the Portal's owner tag; in the example above it is the expiry key. Set
it deliberately for the desired lifecycle model.

Run an immediate, observable test before relying on the schedule:

```bash
kubectl create job --from=cronjob/tag-updater tag-updater-smoke-test \
  --namespace "${TAG_UPDATER_NAMESPACE}"
kubectl get jobs --namespace "${TAG_UPDATER_NAMESPACE}"
kubectl logs --namespace "${TAG_UPDATER_NAMESPACE}" job/tag-updater-smoke-test
```

## Deploy Extirpater

Skip this section unless scheduled resource deletion has been approved.
Extirpater runs as an OKE CronJob from `deploy/helm/ociextirpater/`; its chart
is suspended by default.

1. Create an OCI workload-identity policy for the Extirpater service account.
   Scope it to the target cleanup compartments and resource families wherever
   OCI policy syntax permits; do not grant blanket tenancy management unless
   that is the explicitly approved cleanup scope.
2. Create the namespace and an OCIR pull secret using the same workflow as Tag
   Updater:

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

3. Create an ignored file at
   `deploy/helm/ociextirpater/values.local.yaml`. Set the image, OCI tenancy,
   one or more `config.compartments`, the required OKE workload-identity
   service-account annotations, and a deliberately reviewed schedule. Keep
   `cronJob.suspend: true`.
4. Install the suspended release:

   ```bash
   helm upgrade --install ociextirpater \
     ./deploy/helm/ociextirpater \
     --namespace "${EXTIRPATER_NAMESPACE}" \
     --values deploy/helm/ociextirpater/values.local.yaml \
     --set-string image.repository="${REGISTRY}/${OCIR_NAMESPACE}/${EXTIRPATER_REPOSITORY}" \
     --set-string image.tag="${EXTIRPATER_TAG}" \
     --set-string config.tenancy="${TENANCY_OCID}"
   ```

5. Confirm the CronJob is suspended and inspect its rendered configuration:

   ```bash
   kubectl get cronjob ociextirpater --namespace "${EXTIRPATER_NAMESPACE}"
   helm template ociextirpater ./deploy/helm/ociextirpater \
     --namespace "${EXTIRPATER_NAMESPACE}" \
     --values deploy/helm/ociextirpater/values.local.yaml
   ```

Only after independently validating the target compartments, object categories,
workload identity, IAM policy, image, and schedule, set `cronJob.suspend: false`
in the local values file and run `helm upgrade` again. A successful installation
is not approval to delete resources.

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
authentication error as a workload-identity policy or service-account/cluster
name mismatch before changing the job's IAM scope.

### Extirpater

Confirm the CronJob remains suspended until it has been approved. After a
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
| Portal pod starts but OCI calls fail | Check configured auth type, runtime dynamic-group membership, and least-privilege IAM policies. |
| Tag Updater job fails authentication | Verify enhanced OKE/workload identity, cluster OCID, namespace, service-account name, and IAM policy conditions. |
| Extirpater does not run | Check whether the CronJob is suspended, its schedule, Job events, image pull secret, and workload-identity IAM policy. |

For component behavior and troubleshooting beyond this deployment flow, consult
the source project documentation pinned under `projects/`.
