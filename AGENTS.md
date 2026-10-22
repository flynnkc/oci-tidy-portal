# Project guidance for coding agents

This repository is the umbrella workspace for OCI Management Portal, Tag Updater,
and OCI Extirpater. `projects/` contains pinned Git submodules. Keep infrastructure,
Helm charts, and the deployment guide in this repository aligned with those pinned
versions. Make source changes inside a submodule's own repository and update its
pin deliberately.

## Project priorities

- Keep the default deployment affordable and manageable by OCI administrators.
  Basic OKE with worker-node instance principals is the first and default track
  for all three components. Enhanced OKE with workload
  identity is a clearly labeled alternative throughout the deployment guide for
  advanced administrators.
- Deploy the Portal, Tag Updater, and Extirpater as one system. All three are
  intended to work together; do not describe Tag Updater or Extirpater as
  optional or leave either out of the deployment path.
- Use OCI Resource Manager as the primary infrastructure deployment path.
  Terraform CLI is the backup path. Do not instruct users to upload Terraform
  files or a zip to Resource Manager; there is an intended Deploy to Oracle
  Cloud button to begin implementation.
- Make the Portal's public endpoint HTTPS by default on port 443. Prefer OCI
  Certificates for load-balancer TLS administration. Kubernetes TLS Secrets are
  an alternative; self-signed certificates are for testing only.
- Use OCI load-balancer application-cookie persistence with the Portal's `omid`
  cookie. Support Redis for shared Portal sessions when replicas need it.
- Require an explicit cleanup scope for Extirpater. Install its CronJob suspended
  while its targets, permissions, and schedule are reviewed, then enable it as
  part of completing the deployment.
- Keep permissions and resource scope as narrow as the chosen deployment allows.
  In particular, worker-node instance principals grant access to workloads on
  those nodes; document that consequence when using the basic-cluster track.

## Changes to deployment behavior

- Before changing defaults or adding prerequisites, check the full path through
  Terraform variables and Resource Manager schema, Helm values and templates,
  helper scripts, `DEPLOYMENT_GUIDE.md`, and the README variable reference.
  Commands in the guide should consume the inputs collected earlier in the guide.
- Preserve the documented Portal secret names `ocirsecret` and
  `oci-management-portal-secrets`. Use an explicit OCIR `REGISTRY` input for image
  operations; do not add a region selector back to the image-build script.
- When changing cost, security, identity, TLS, or deployment defaults, record
  the reason and tradeoffs in the change summary. Keep the basic/instance-principal
  track first when documenting both OKE options.
