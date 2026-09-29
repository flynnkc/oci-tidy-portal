#!/usr/bin/env bash
# Build and publish all workspace project images to Oracle Cloud Infrastructure Registry.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/build-and-push-image.sh [options]

Builds and pushes the Dockerfiles in all three project submodules: the OCI
Management Portal, Tag Updater, and OCI Extirpater. Docker must already be
logged in, unless --login is supplied.

This is a Bash script. On Windows, run it from WSL; PowerShell and Command
Prompt do not run it directly.

Options:
  -g, --region NAME        OCI region, e.g. us-ashburn-1 (required unless --registry is set)
  -n, --namespace NAME     OCIR tenancy namespace (defaults to `oci os ns get`)
  -t, --tag TAG            Tag for every image (default: each submodule's Git short SHA)
  -e, --engine NAME        Container engine: auto, docker, or podman (default: auto)
      --registry HOST      OCIR registry host (default: mapped short OCIR endpoint)
      --platform LIST      Buildx platform list (default: linux/arm64)
      --portal-repository NAME
                            Portal repository (default: oci-management-portal)
      --tag-updater-repository NAME
                            Tag Updater repository (default: tag-updater)
      --extirpater-repository NAME
                            Extirpater repository (default: ociextirpater)
      --portal-tag TAG      Override the Portal image tag
      --tag-updater-tag TAG Override the Tag Updater image tag
      --extirpater-tag TAG  Override the Extirpater image tag
      --also-tag-latest    Also publish a latest tag
      --login              Log in to OCIR before building; prompts for credentials when absent
  -h, --help               Show this help

Environment equivalents:
  OCI_REGION, OCIR_NAMESPACE, REGISTRY, IMAGE_TAG, PORTAL_REPOSITORY,
  TAG_UPDATER_REPOSITORY, EXTIRPATER_REPOSITORY, PORTAL_TAG,
  TAG_UPDATER_TAG, EXTIRPATER_TAG, CONTAINER_ENGINE, PLATFORM,
  OCIR_USERNAME, and OCIR_AUTH_TOKEN.

Examples:
  scripts/build-and-push-image.sh \
    --region us-ashburn-1 --tag 1.2.0 --platform linux/arm64

  scripts/build-and-push-image.sh \
    --tag-updater-repository platform/tag-updater \
    --region us-ashburn-1 --platform linux/amd64,linux/arm64 --also-tag-latest
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_option_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || fail "$1 requires a value."
}

region="${OCI_REGION:-}"
namespace="${OCIR_NAMESPACE:-}"
registry="${REGISTRY:-}"
tag="${IMAGE_TAG:-}"
portal_repository="${PORTAL_REPOSITORY:-oci-management-portal}"
tag_updater_repository="${TAG_UPDATER_REPOSITORY:-tag-updater}"
extirpater_repository="${EXTIRPATER_REPOSITORY:-ociextirpater}"
portal_tag="${PORTAL_TAG:-}"
tag_updater_tag="${TAG_UPDATER_TAG:-}"
extirpater_tag="${EXTIRPATER_TAG:-}"
engine="${CONTAINER_ENGINE:-auto}"
platform="${PLATFORM:-linux/arm64}"
also_tag_latest=false
login=false

while (($#)); do
  case "$1" in
    -g|--region) require_option_value "$1" "${2:-}"; region="$2"; shift 2 ;;
    -n|--namespace) require_option_value "$1" "${2:-}"; namespace="$2"; shift 2 ;;
    -t|--tag) require_option_value "$1" "${2:-}"; tag="$2"; shift 2 ;;
    -e|--engine) require_option_value "$1" "${2:-}"; engine="$2"; shift 2 ;;
    --registry) require_option_value "$1" "${2:-}"; registry="$2"; shift 2 ;;
    --platform) require_option_value "$1" "${2:-}"; platform="$2"; shift 2 ;;
    --portal-repository) require_option_value "$1" "${2:-}"; portal_repository="$2"; shift 2 ;;
    --tag-updater-repository) require_option_value "$1" "${2:-}"; tag_updater_repository="$2"; shift 2 ;;
    --extirpater-repository) require_option_value "$1" "${2:-}"; extirpater_repository="$2"; shift 2 ;;
    --portal-tag) require_option_value "$1" "${2:-}"; portal_tag="$2"; shift 2 ;;
    --tag-updater-tag) require_option_value "$1" "${2:-}"; tag_updater_tag="$2"; shift 2 ;;
    --extirpater-tag) require_option_value "$1" "${2:-}"; extirpater_tag="$2"; shift 2 ;;
    --also-tag-latest) also_tag_latest=true; shift ;;
    --login) login=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1. Run with --help for usage." ;;
  esac
done

case "$engine" in
  auto)
    if command -v docker >/dev/null 2>&1; then
      engine=docker
      docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required when Docker is selected."
    elif command -v podman >/dev/null 2>&1; then
      engine=podman
    else
      fail "Docker or Podman is required."
    fi
    ;;
  docker)
    command -v docker >/dev/null 2>&1 || fail "Docker is required for --engine docker."
    docker buildx version >/dev/null 2>&1 || fail "Docker Buildx is required for --engine docker."
    ;;
  podman)
    command -v podman >/dev/null 2>&1 || fail "Podman is required for --engine podman."
    ;;
  *) fail "Unsupported engine: $engine. Choose auto, docker, or podman." ;;
esac

[[ -n "$platform" ]] || fail "--platform must not be empty."

projects=(
  "projects/oci-management-portal:$portal_repository:$portal_tag"
  "projects/tag-updater:$tag_updater_repository:$tag_updater_tag"
  "projects/ociextirpater:$extirpater_repository:$extirpater_tag"
)
for project_spec in "${projects[@]}"; do
  IFS=: read -r project_path project_repository project_tag <<< "$project_spec"
  [[ -d "$project_path" ]] || fail "Project directory does not exist: $project_path"
  [[ -f "$project_path/Dockerfile" ]] || fail "No Dockerfile found in: $project_path"
  [[ -n "$project_repository" ]] || fail "Repository must not be empty for: $project_path"
done

if [[ -z "$registry" ]]; then
  [[ -n "$region" ]] || fail "--region is required when --registry is not supplied."
  # OCIR image pushes use the OCIR data-plane endpoint, not the Artifacts API
  # endpoint (ocir.<region>.oci.oraclecloud.com). This map follows Oracle's
  # published OC1 Container Registry endpoint table.
  case "$region" in
    af-johannesburg-1) registry="jnb.ocir.io" ;;
    af-casablanca-1) registry="lej.ocir.io" ;;
    ap-melbourne-1) registry="mel.ocir.io" ;;
    ap-hyderabad-1) registry="hyd.ocir.io" ;;
    ap-mumbai-1) registry="bom.ocir.io" ;;
    ap-batam-1) registry="hsg.ocir.io" ;;
    ap-osaka-1) registry="kix.ocir.io" ;;
    ap-kulai-2) registry="jbp.ocir.io" ;;
    ap-singapore-1) registry="sin.ocir.io" ;;
    ap-singapore-2) registry="xsp.ocir.io" ;;
    ap-seoul-1) registry="icn.ocir.io" ;;
    ap-chuncheon-1) registry="yny.ocir.io" ;;
    ap-sydney-1) registry="syd.ocir.io" ;;
    ap-tokyo-1) registry="nrt.ocir.io" ;;
    ca-montreal-1) registry="yul.ocir.io" ;;
    ca-toronto-1) registry="yyz.ocir.io" ;;
    eu-amsterdam-1) registry="ams.ocir.io" ;;
    eu-frankfurt-1) registry="fra.ocir.io" ;;
    eu-madrid-1) registry="mad.ocir.io" ;;
    eu-madrid-3) registry="orf.ocir.io" ;;
    eu-marseille-1) registry="mrs.ocir.io" ;;
    eu-milan-1) registry="lin.ocir.io" ;;
    eu-turin-1) registry="nrq.ocir.io" ;;
    eu-paris-1) registry="cdg.ocir.io" ;;
    eu-stockholm-1) registry="arn.ocir.io" ;;
    eu-zurich-1) registry="zrh.ocir.io" ;;
    il-jerusalem-1) registry="mtz.ocir.io" ;;
    me-abudhabi-1) registry="auh.ocir.io" ;;
    me-dubai-1) registry="dxb.ocir.io" ;;
    me-riyadh-1) registry="ruh.ocir.io" ;;
    me-jeddah-1) registry="jed.ocir.io" ;;
    eu-jovanovac-1) registry="ocir.eu-jovanovac-1.oci.oraclecloud20.com" ;;
    mx-queretaro-1) registry="qro.ocir.io" ;;
    mx-monterrey-1) registry="mty.ocir.io" ;;
    sa-santiago-1) registry="scl.ocir.io" ;;
    sa-valparaiso-1) registry="vap.ocir.io" ;;
    sa-bogota-1) registry="bog.ocir.io" ;;
    sa-saopaulo-1) registry="gru.ocir.io" ;;
    sa-vinhedo-1) registry="vcp.ocir.io" ;;
    uk-london-1) registry="lhr.ocir.io" ;;
    uk-cardiff-1) registry="cwl.ocir.io" ;;
    us-ashburn-1) registry="iad.ocir.io" ;;
    us-chicago-1) registry="ord.ocir.io" ;;
    us-phoenix-1) registry="phx.ocir.io" ;;
    us-sanjose-1) registry="sjc.ocir.io" ;;
    *) fail "No default OCIR registry endpoint is configured for region: $region. Supply --registry HOST (or set REGISTRY) with that region's OCIR endpoint." ;;
  esac
fi

if [[ -z "$namespace" ]]; then
  command -v oci >/dev/null 2>&1 || fail "Set --namespace or install and configure the OCI CLI."
  namespace="$(oci os ns get --query data --raw-output)"
fi
[[ -n "$namespace" ]] || fail "Could not determine the OCIR namespace."

IFS=',' read -r -a platforms <<< "$platform"
for target_platform in "${platforms[@]}"; do
  [[ -n "$target_platform" ]] || fail "--platform contains an empty platform value."
done

if "$login"; then
  username="${OCIR_USERNAME:-}"
  auth_token="${OCIR_AUTH_TOKEN:-}"
  if [[ -z "$username" ]]; then
    read -r -p 'OCIR username: ' username
  fi
  if [[ -z "$auth_token" ]]; then
    read -r -s -p 'OCIR auth token: ' auth_token
    printf '\n'
  fi
  [[ -n "$username" && -n "$auth_token" ]] || fail "OCIR username and auth token are required for --login."
  printf '%s' "$auth_token" | "$engine" login "$registry" --username "$username" --password-stdin
fi

printf 'Engine: %s\n' "$engine"
printf 'Platform(s): %s\n' "$platform"

build_and_push() {
  local project_path="$1"
  local repository="$2"
  local image_tag="$3"
  local image_repository="${registry}/${namespace}/${repository}"
  local image="${image_repository}:${image_tag}"

  printf '\nBuilding and pushing: %s\n' "$image"

  if [[ "$engine" == docker ]]; then
    build_args=(docker buildx build --platform "$platform" --push --tag "$image")
    if "$also_tag_latest" && [[ "$image_tag" != "latest" ]]; then
      build_args+=(--tag "${image_repository}:latest")
    fi
    build_args+=("$project_path")
    "${build_args[@]}"
  elif ((${#platforms[@]} == 1)); then
    build_args=(podman build --platform "${platforms[0]}" --tag "$image")
    if "$also_tag_latest" && [[ "$image_tag" != "latest" ]]; then
      build_args+=(--tag "${image_repository}:latest")
    fi
    build_args+=("$project_path")
    "${build_args[@]}"
    podman push "$image"
    if "$also_tag_latest" && [[ "$image_tag" != "latest" ]]; then
      podman push "${image_repository}:latest"
    fi
  else
    podman manifest create "$image"
    for target_platform in "${platforms[@]}"; do
      podman build --platform "$target_platform" --manifest "$image" "$project_path"
    done
    podman manifest push --all "$image" "docker://${image}"
    if "$also_tag_latest" && [[ "$image_tag" != "latest" ]]; then
      podman manifest push --all "$image" "docker://${image_repository}:latest"
    fi
  fi

  printf 'Published: %s\n' "$image"
  if "$also_tag_latest" && [[ "$image_tag" != "latest" ]]; then
    printf 'Published: %s:latest\n' "$image_repository"
  fi
}

for project_spec in "${projects[@]}"; do
  IFS=: read -r project_path repository project_tag <<< "$project_spec"
  if [[ -z "$project_tag" ]]; then
    project_tag="$tag"
    if [[ -z "$project_tag" ]]; then
      project_tag="$(git -C "$project_path" rev-parse --short HEAD 2>/dev/null || printf 'latest')"
    fi
  fi
  build_and_push "$project_path" "$repository" "$project_tag"
done
