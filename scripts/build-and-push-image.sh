#!/usr/bin/env bash
# Build and publish a project image to Oracle Cloud Infrastructure Registry.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/build-and-push-image.sh [options]

Builds a Docker image with Buildx and pushes it to OCIR. Docker must already be
logged in, unless --login is supplied.

This is a Bash script. On Windows, run it from WSL; PowerShell and Command
Prompt do not run it directly.

Options:
  -p, --project PATH       Build context relative to the workspace (required)
  -r, --repository NAME    OCIR repository name (required)
  -g, --region NAME        OCI region, e.g. us-ashburn-1 (required unless --registry is set)
  -n, --namespace NAME     OCIR tenancy namespace (defaults to `oci os ns get`)
  -t, --tag TAG            Image tag (default: current Git short SHA, or latest)
  -e, --engine NAME        Container engine: auto, docker, or podman (default: auto)
      --registry HOST      OCIR registry host (default: ocir.<region>.oci.oraclecloud.com)
      --platform LIST      Buildx platform list (default: linux/arm64)
      --also-tag-latest    Also publish a latest tag
      --login              Log in to OCIR before building; prompts for credentials when absent
  -h, --help               Show this help

Environment equivalents:
  PROJECT, OCIR_REPOSITORY, OCI_REGION, OCIR_NAMESPACE, REGISTRY, IMAGE_TAG,
  CONTAINER_ENGINE, PLATFORM, OCIR_USERNAME, and OCIR_AUTH_TOKEN.

Examples:
  scripts/build-and-push-image.sh \
    --project projects/oci-management-portal \
    --repository oci-management-portal \
    --region us-ashburn-1 --tag 1.2.0 --platform linux/arm64

  scripts/build-and-push-image.sh \
    --project projects/tag-updater --repository platform/tag-updater \
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

project="${PROJECT:-}"
repository="${OCIR_REPOSITORY:-}"
region="${OCI_REGION:-}"
namespace="${OCIR_NAMESPACE:-}"
registry="${REGISTRY:-}"
tag="${IMAGE_TAG:-}"
engine="${CONTAINER_ENGINE:-auto}"
platform="${PLATFORM:-linux/arm64}"
also_tag_latest=false
login=false

while (($#)); do
  case "$1" in
    -p|--project) require_option_value "$1" "${2:-}"; project="$2"; shift 2 ;;
    -r|--repository) require_option_value "$1" "${2:-}"; repository="$2"; shift 2 ;;
    -g|--region) require_option_value "$1" "${2:-}"; region="$2"; shift 2 ;;
    -n|--namespace) require_option_value "$1" "${2:-}"; namespace="$2"; shift 2 ;;
    -t|--tag) require_option_value "$1" "${2:-}"; tag="$2"; shift 2 ;;
    -e|--engine) require_option_value "$1" "${2:-}"; engine="$2"; shift 2 ;;
    --registry) require_option_value "$1" "${2:-}"; registry="$2"; shift 2 ;;
    --platform) require_option_value "$1" "${2:-}"; platform="$2"; shift 2 ;;
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

[[ -n "$project" ]] || fail "--project is required."
[[ -d "$project" ]] || fail "Project directory does not exist: $project"
[[ -f "$project/Dockerfile" ]] || fail "No Dockerfile found in: $project"
[[ -n "$repository" ]] || fail "--repository is required."
[[ -n "$platform" ]] || fail "--platform must not be empty."

if [[ -z "$registry" ]]; then
  [[ -n "$region" ]] || fail "--region is required when --registry is not supplied."
  registry="ocir.${region}.oci.oraclecloud.com"
fi

if [[ -z "$namespace" ]]; then
  command -v oci >/dev/null 2>&1 || fail "Set --namespace or install and configure the OCI CLI."
  namespace="$(oci os ns get --query data --raw-output)"
fi
[[ -n "$namespace" ]] || fail "Could not determine the OCIR namespace."

if [[ -z "$tag" ]]; then
  tag="$(git -C "$project" rev-parse --short HEAD 2>/dev/null || printf 'latest')"
fi

image_repository="${registry}/${namespace}/${repository}"
image="${image_repository}:${tag}"

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

printf 'Building and pushing: %s\n' "$image"
printf 'Engine: %s\n' "$engine"
printf 'Platform(s): %s\n' "$platform"

if [[ "$engine" == docker ]]; then
  build_args=(docker buildx build --platform "$platform" --push --tag "$image")
  if "$also_tag_latest" && [[ "$tag" != "latest" ]]; then
    build_args+=(--tag "${image_repository}:latest")
  fi
  build_args+=("$project")
  "${build_args[@]}"
elif ((${#platforms[@]} == 1)); then
  build_args=(podman build --platform "${platforms[0]}" --tag "$image")
  if "$also_tag_latest" && [[ "$tag" != "latest" ]]; then
    build_args+=(--tag "${image_repository}:latest")
  fi
  build_args+=("$project")
  "${build_args[@]}"
  podman push "$image"
  if "$also_tag_latest" && [[ "$tag" != "latest" ]]; then
    podman push "${image_repository}:latest"
  fi
else
  podman manifest create "$image"
  for target_platform in "${platforms[@]}"; do
    podman build --platform "$target_platform" --manifest "$image" "$project"
  done
  podman manifest push --all "$image" "docker://${image}"
  if "$also_tag_latest" && [[ "$tag" != "latest" ]]; then
    podman manifest push --all "$image" "docker://${image_repository}:latest"
  fi
fi

printf 'Published: %s\n' "$image"
if "$also_tag_latest" && [[ "$tag" != "latest" ]]; then
  printf 'Published: %s:latest\n' "$image_repository"
fi
