#!/bin/bash

# vim: tabstop=4 shiftwidth=4 softtabstop=4
# -*- sh-basic-offset: 4 -*-

# Install Anthias from a fork, running that fork's own prebuilt
# anthias-server/viewer images (published by
# .github/workflows/custom-x86-images.yaml) instead of the stock
# ghcr.io/screenly ones. x86 only: that is the one board the workflow
# builds.
#
# This reuses the official installer rather than copying it: the fork's
# bin/install.sh is fetched at the same branch and sourced (it only runs
# its own main() when executed directly), its repository/branch globals
# are pointed at the fork, and its install steps are called in order. The
# image prefix is saved to /etc/anthias/images.env, which
# bin/upgrade_containers.sh reads, so later upgrades keep pulling the
# fork's images; /usr/local/sbin/upgrade_anthias.sh becomes this script.
#
# Run as the user that will own the install (not root):
#   bash <(curl -fsSL https://raw.githubusercontent.com/NIKIBG12/Anthias/volume-control/bin/install_custom.sh)
#
# Defaults can be overridden with ANTHIAS_FORK_REPO (owner/name),
# ANTHIAS_FORK_BRANCH and ANTHIAS_IMAGE_PREFIX. ANTHIAS_SKIP_IMAGE_CHECK=1
# skips the up-front check that the images are publicly pullable.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "error: install_custom.sh must be run with bash, not sh/dash." >&2
    exit 1
fi

set -euo pipefail

FORK_REPO="${ANTHIAS_FORK_REPO:-NIKIBG12/Anthias}"
FORK_BRANCH="${ANTHIAS_FORK_BRANCH:-volume-control}"
FORK_OWNER="${FORK_REPO%%/*}"
# GHCR repository names are lowercase.
IMAGE_PREFIX="${ANTHIAS_IMAGE_PREFIX:-ghcr.io/${FORK_OWNER,,}/anthias}"
FORK_RAW_URL="https://raw.githubusercontent.com/${FORK_REPO}"
CUSTOM_INSTALLER_URL="${FORK_RAW_URL}/${FORK_BRANCH}/bin/install_custom.sh"

OFFICIAL_INSTALLER=$(mktemp)
if ! curl -fsSL "${FORK_RAW_URL}/${FORK_BRANCH}/bin/install.sh" \
    -o "${OFFICIAL_INSTALLER}"; then
    echo "error: could not download install.sh from ${FORK_REPO}@${FORK_BRANCH}" >&2
    rm -f "${OFFICIAL_INSTALLER}"
    exit 1
fi

# shellcheck source=bin/install.sh
source "${OFFICIAL_INSTALLER}"

# install.sh registered its own EXIT trap while being sourced; keep it and
# also drop the downloaded copy.
trap 'cleanup_installer_venv; rm -f "${OFFICIAL_INSTALLER}"' EXIT

# Point the official installer's globals at the fork. GITHUB_RAW_URL is
# where upgrade_docker_containers fetches upgrade_containers.sh from, so
# it must be the fork's copy (the one that honours images.env).
REPOSITORY="https://github.com/${FORK_REPO}.git"
GITHUB_RAW_URL="${FORK_RAW_URL}"
BRANCH="${FORK_BRANCH}"
# Installing a branch tip, like "latest": compose resolves the images to
# ${IMAGE_PREFIX}-<service>:latest-x86, the tag the workflow publishes.
DOCKER_TAG="latest"

CUSTOM_INTRO=(
    "This installs Anthias from ${FORK_REPO} (branch ${FORK_BRANCH}),"
    "running the prebuilt images from ${IMAGE_PREFIX}"
    "instead of the official ones."
    ""
    "The host will be repurposed for digital signage and should not be"
    "used for anything else."
)

function require_x86() {
    if [ "${DEVICE_TYPE}" != "x86" ]; then
        echo "error: ${IMAGE_PREFIX} images are built for x86 only;" \
            "this device is ${DEVICE_TYPE}." >&2
        exit 1
    fi
}

# Fail in the first minute, not after the long Ansible run, when the
# images are missing or still private (new GHCR packages can start
# private; make them public in the package settings on GitHub).
function require_custom_images() {
    if [ -n "${ANTHIAS_SKIP_IMAGE_CHECK:-}" ]; then
        return 0
    fi
    local path="${IMAGE_PREFIX#ghcr.io/}"
    if [ "${path}" = "${IMAGE_PREFIX}" ]; then
        # Not on GHCR; nothing to check anonymously.
        return 0
    fi

    local service token status
    local accept='application/vnd.oci.image.index.v1+json'
    accept+=', application/vnd.oci.image.manifest.v1+json'
    accept+=', application/vnd.docker.distribution.manifest.list.v2+json'
    accept+=', application/vnd.docker.distribution.manifest.v2+json'

    for service in server viewer; do
        token=$(
            curl -fsSL --max-time 15 \
                "https://ghcr.io/token?scope=repository:${path}-${service}:pull" \
                2>/dev/null | sed -n 's/.*"token":"\([^"]*\)".*/\1/p'
        ) || token=''
        status=$(
            curl -s -o /dev/null -w '%{http_code}' --max-time 15 -I \
                -H "Authorization: Bearer ${token}" \
                -H "Accept: ${accept}" \
                "https://ghcr.io/v2/${path}-${service}/manifests/latest-x86"
        ) || status='000'
        if [ "${status}" != "200" ]; then
            echo "error: cannot pull ${IMAGE_PREFIX}-${service}:latest-x86" \
                "(HTTP ${status})." >&2
            echo "       Check the Custom x86 Images workflow finished, and" \
                "that the package is public on GitHub." >&2
            exit 1
        fi
    done
}

function point_existing_checkout_at_fork() {
    # clone_repo only clones when ~/anthias is absent; an existing
    # checkout (e.g. a previous stock install) would keep fetching from
    # its old origin.
    if [ -d "${ANTHIAS_REPO_DIR}/.git" ]; then
        git -C "${ANTHIAS_REPO_DIR}" remote set-url origin "${REPOSITORY}"
    fi
}

function save_image_prefix() {
    display_section "Use Images From ${IMAGE_PREFIX}"
    sudo mkdir -p /etc/anthias
    echo "ANTHIAS_IMAGE_PREFIX=${IMAGE_PREFIX}" \
        | sudo tee /etc/anthias/images.env > /dev/null
}

function custom_main() {
    require_supported_environment
    set_device_type
    require_x86

    configure_proxy

    install_prerequisites && clear

    require_network
    require_custom_images

    display_banner "${TITLE_TEXT}"

    local INTRO
    INTRO=$(printf '%s\n' "${CUSTOM_INTRO[@]}")
    whiptail \
        --title "Anthias Installer" \
        --yesno "${INTRO}"$'\n\nDo you still want to continue?' \
        16 76 \
        || exit 0

    if whiptail \
        --title "Anthias Installer" \
        --yesno "${MANAGE_NETWORK_PROMPT[*]}" 10 70; then
        export MANAGE_NETWORK="Yes"
    else
        export MANAGE_NETWORK="No"
    fi

    if whiptail \
        --title "Anthias Installer" \
        --yesno "${SYSTEM_UPGRADE_PROMPT[*]}" 10 70; then
        SYSTEM_UPGRADE="Yes"
    else
        SYSTEM_UPGRADE="No"
        ANSIBLE_PLAYBOOK_ARGS+=("--skip-tags" "system-upgrade")
    fi

    display_section "User Input Summary"
    echo "Repository:         ${FORK_REPO}"
    echo "Branch:             ${BRANCH}"
    echo "Images:             ${IMAGE_PREFIX}-*:${DOCKER_TAG}-${DEVICE_TYPE}"
    echo "Manage Network:     ${MANAGE_NETWORK}"
    echo "System Upgrade:     ${SYSTEM_UPGRADE}"

    # Read by ansible/site.yml: upgrade_anthias.sh becomes this script.
    export ANTHIAS_UPGRADE_SCRIPT_URL="${CUSTOM_INSTALLER_URL}"

    initialize_ansible
    initialize_locales
    install_packages
    migrate_repo_dir
    point_existing_checkout_at_fork
    clone_repo
    post_clone_migrate_legacy_paths
    install_ansible
    provision_host_agent_venv
    stop_docker_stack
    run_ansible_playbook

    save_image_prefix
    upgrade_docker_containers
    cleanup
    modify_permissions

    write_anthias_version
    post_installation
}

custom_main
