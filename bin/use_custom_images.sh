#!/bin/bash -e

# vim: tabstop=4 shiftwidth=4 softtabstop=4
# -*- sh-basic-offset: 4 -*-

# Run custom-built anthias-server / anthias-viewer images (for example
# the ones .github/workflows/custom-x86-images.yaml pushes to a fork's
# own registry) on an installed device, without building them here.
#
# Each image is pulled and re-tagged as the ghcr.io/screenly/anthias-*
# reference docker-compose.yml already uses, so the compose file stays
# untouched and `up -d` recreates only the containers whose image
# changed (anthias-celery shares the server image, so it follows).
#
# A later upgrade_containers.sh run pulls the stock images back over
# these tags. Re-run this script afterwards to keep the custom build.
#
# Usage:
#   IMAGE_PREFIX=ghcr.io/<owner>/anthias [IMAGE_TAG=x86] \
#       ./bin/use_custom_images.sh

IMAGE_PREFIX="${IMAGE_PREFIX:?set IMAGE_PREFIX, e.g. ghcr.io/<owner>/anthias}"
IMAGE_TAG="${IMAGE_TAG:-x86}"
ANTHIAS_DIR="/home/${USER}/anthias"
COMPOSE_FILE="${ANTHIAS_DIR}/docker-compose.yml"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "error: ${COMPOSE_FILE} not found; install Anthias first." >&2
    exit 1
fi

for service in server viewer; do
    target=$(
        grep -E "^\s*image:\s*ghcr\.io/screenly/anthias-${service}:" \
            "$COMPOSE_FILE" | head -n 1 | awk '{print $2}'
    )
    if [[ -z "$target" ]]; then
        echo "error: no anthias-${service} image in ${COMPOSE_FILE}" >&2
        exit 1
    fi
    custom="${IMAGE_PREFIX}-${service}:${IMAGE_TAG}"
    sudo docker pull "$custom"
    sudo docker tag "$custom" "$target"
    echo "anthias-${service}: ${custom} -> ${target}"
done

COMPOSE_FILES=(-f "$COMPOSE_FILE")
SSL_OVERRIDE="${ANTHIAS_DIR}/docker-compose.ssl.override.yml"
if [[ -f "$SSL_OVERRIDE" ]]; then
    COMPOSE_FILES+=(-f "$SSL_OVERRIDE")
fi

sudo -E docker compose "${COMPOSE_FILES[@]}" up -d --remove-orphans
