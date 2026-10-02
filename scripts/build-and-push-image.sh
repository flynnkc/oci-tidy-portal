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
  -n, --namespace NAME     OCIR tenancy namespace (defaults to `oci os ns get`)
  -t, --tag TAG            Tag for every image (default: each submodule's Git short SHA)
  -e, --engine NAME        Container engine: auto, docker, or podman (default: auto)
  -r, --registry HOST      OCIR registry host (required unless REGISTRY is set)
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
  OCIR_NAMESPACE, REGISTRY, IMAGE_TAG, PORTAL_REPOSITORY,
  TAG_UPDATER_REPOSITORY, EXTIRPATER_REPOSITORY, PORTAL_TAG,
  TAG_UPDATER_TAG, EXTIRPATER_TAG, CONTAINER_ENGINE, PLATFORM,
  OCIR_USERNAME, and OCIR_AUTH_TOKEN.

Examples:
  scripts/build-and-push-image.sh \
    --registry iad.ocir.io --tag 1.2.0 --platform linux/arm64

  scripts/build-and-push-image.sh \
    --tag-updater-repository platform/tag-updater \
    --registry iad.ocir.io --platform linux/amd64,linux/arm64 --also-tag-latest
EOF
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

require_option_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || fail "$1 requires a value."
}

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
    -n|--namespace) require_option_value "$1" "${2:-}"; namespace="$2"; shift 2 ;;
    -t|--tag) require_option_value "$1" "${2:-}"; tag="$2"; shift 2 ;;
    -e|--engine) require_option_value "$1" "${2:-}"; engine="$2"; shift 2 ;;
    -r|--registry) require_option_value "$1" "${2:-}"; registry="$2"; shift 2 ;;
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

[[ -n "$registry" ]] || fail "Set --registry HOST or REGISTRY to the OCIR registry host."

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
