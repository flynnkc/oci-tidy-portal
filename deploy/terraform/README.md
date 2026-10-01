# Deploy Terraform (OCI OKE)

This directory contains Terraform configuration for deploying an OCI OKE cluster with:

- OCI VCN IP Native pod networking
- Subnets for the private API endpoint, worker nodes, additional private workloads, and the public load balancer
- Node and API endpoint NSGs, plus subnet security lists
- Optional auto-selection of latest OKE platform image by selected node shape
- Private OKE API endpoint
- OCI Identity Domain confidential application for portal OIDC login
- Same-domain JWT Identity Propagation Trust for the confidential application

## File layout

- `versions.tf` - Terraform and OCI provider requirements
- `providers.tf` - OCI provider configuration
- `variables.tf` - Input variables and validations
- `data.tf` - Data sources (ADs, region/home-region lookup, OSN services, OKE platform images)
- `locals.tf` - Derived values and selection logic
- `networking.tf` - VCN, gateways, route tables, NSGs, subnets
- `okecluster_node.tf` - OKE cluster and node pool resources
- `confidential_application.tf` - OCI Identity Domain confidential application and JWT propagation trust
- `outputs.tf` - Identity Domain, confidential application, and propagation trust outputs
- `schema.yaml` - OCI Resource Manager UI schema

## Image selection behavior

- `use_latest_platform_oke_image = true` (default):
  - Uses latest Oracle Linux OKE platform image compatible with `node_shape`.
- `use_latest_platform_oke_image = false`:
  - Uses explicit `node_image_ocid`.

## Notes

- Attach `nsg_ssh_source` to your bastion/private endpoint VNIC to permit SSH (22) into worker nodes.
- Keep `schema.yaml` aligned with variables if you modify inputs.

## Confidential application

Select an existing OCI Identity Domain with `identity_domain_id`. Terraform creates an OIDC confidential application in that domain using the custom web application template.
OCI auto-generates the OAuth client ID for the confidential application.

By default, Terraform registers `${confidential_application_base_url}/callback` as the redirect URI and `${confidential_application_base_url}` as the post-logout redirect URI. After apply, use these outputs when configuring the Helm chart:

- `identity_domain_endpoint` -> `config.idmEndpoint`
- `confidential_application_client_id` -> `config.clientId`
- `confidential_application_client_secret` -> `secret.clientSecret`

Terraform enables the `authorization_code` and `client_credentials` OAuth grants for the confidential application.
It also always enables HTTP redirect URLs, bypasses user consent, enables force delete for stack destroy, and configures the OAuth client operation as `introspect`.

Terraform also creates a same-domain JWT Identity Propagation Trust equivalent to the Identity Domains API payload with:

- `issuer = "https://identity.oraclecloud.com/"`
- `type = "JWT"`
- `subject_claim_name = "sub"`
- `subject_mapping_attribute = "userName"`
- `subject_type = "User"`
- `allow_impersonation = false`
- `oauth_clients = [confidential_application_id]`
- `public_key_endpoint = <identity-domain-endpoint>/admin/v1/SigningCert/jwk`

If the application receives a new public load balancer URL after Helm deployment, update `confidential_application_base_url` (or set explicit redirect URI variables) and rerun `terraform apply` so the Identity Domain application callback matches the deployed URL.

## Network architecture

- **VCN CIDR**: `10.0.0.0/16`
- **Subnets**:
  - API endpoint subnet: private by default, public when `enable_external_kubectl_access = true` (`subnet_endpoint_private`, `10.0.5.0/24`)
  - Load balancer subnet: public (`subnet_lb_public`, `10.0.10.0/24`)
  - Worker nodes subnet: private (`subnet_nodes_private`, `10.0.20.0/24`)
  - Additional private subnet: private (`subnet_addl_private`, `10.0.30.0/24`)
- **Route tables**:
  - Public route table -> Internet Gateway (`0.0.0.0/0`)
  - Private route table -> NAT Gateway (`0.0.0.0/0`) + Service Gateway (`All <region> Services in Oracle Services Network`)

## Security and exposure controls

- **OKE API endpoint exposure**: private by default. With `enable_external_kubectl_access = true`, the dedicated endpoint subnet uses the public route table, OKE assigns the endpoint a public IP, and its security list and `nsg_endpoint` admit TCP 6443 from `external_kubectl_access_cidr`. Set `create_endpoint_subnet = true` and supply a trusted source CIDR, preferably your public IP as `/32`.
- **Load balancer ingress**: public load balancer subnet security list allows HTTP (80) and HTTPS (443).
- **Worker networking**: `nsg_nodes` is attached to worker nodes and pods created through OCI VCN IP Native networking.

For an existing private cluster, review the Resource Manager plan before applying
the public-access setting. The endpoint subnet's private/public property is not
updatable in the Terraform provider, so the plan can replace the subnet and
cluster. To use the existing cluster without replacement, connect to its
private endpoint through [OCI Bastion](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengsettingupbastion.htm)
or another route into the VCN. For a public cluster, generate kubeconfig for
the `PUBLIC_ENDPOINT` and verify access from an address inside the allowed CIDR.
