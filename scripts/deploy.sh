#!/usr/bin/env bash
# Blue-Green deployment script.
#
# Usage: bash scripts/deploy.sh <image>
#
# The script:
#   1. Detects which slot (blue / green) is currently running and serving traffic.
#   2. Pulls the new image and starts the INACTIVE slot with it.
#   3. Waits up to 60 s for the new slot's Docker health check to report healthy.
#   4. Rewrites nginx/conf.d/active_upstream.conf to point at the new slot.
#   5. Sends `nginx -s reload` for a zero-downtime upstream swap.
#   6. Stops the old slot.
#
# If the health check does not pass within the timeout the script exits with a
# non-zero status, leaving the old slot active (automatic rollback by inaction).

set -euo pipefail

IMAGE="${1:?Usage: deploy.sh <image>}"

# ============================================================================
# Detect active / inactive slots
# ============================================================================
#
# We inspect actual container state rather than reading active_upstream.conf
# from disk: actions/checkout reverts the committed default (app-blue) on every
# run, so the file is unreliable as a source of truth after checkout.

BLUE_ID=$(docker compose ps -q app-blue 2>/dev/null || true)
BLUE_STATUS=$(docker inspect --format '{{.State.Status}}' "$BLUE_ID" 2>/dev/null || echo "absent")

if [ "$BLUE_STATUS" = "running" ]; then
    CURRENT="app-blue"
    NEW="app-green"
else
    CURRENT="app-green"
    NEW="app-blue"
fi

echo ">>> Active slot : $CURRENT"
echo ">>> Deploy slot : $NEW"
echo ">>> Image       : $IMAGE"

# ============================================================================
# Pull and start the inactive slot with the new image
# ============================================================================

docker pull "$IMAGE"

# APP_IMAGE is read by docker compose from the environment; both service
# definitions use ${APP_IMAGE:-devops-sonarqube:latest} so this controls
# which image the new slot starts with.
APP_IMAGE="$IMAGE" docker compose up -d --no-deps "$NEW"

# ============================================================================
# Health-check polling
# ============================================================================
#
# Docker evaluates the HEALTHCHECK instruction every 10 s with up to 3 retries
# before marking a container unhealthy. We poll for up to 60 s (30 × 2 s) to
# give the container time to start and pass its first check.

echo ">>> Waiting for $NEW to become healthy..."
MAX_RETRIES=30
NEW_ID=$(docker compose ps -q "$NEW")

for i in $(seq 1 $MAX_RETRIES); do
    HEALTH=$(docker inspect --format '{{.State.Health.Status}}' "$NEW_ID" 2>/dev/null || echo "starting")

    if [ "$HEALTH" = "healthy" ]; then
        echo ">>> $NEW is healthy (attempt $i/$MAX_RETRIES)"
        break
    fi

    if [ "$i" -eq "$MAX_RETRIES" ]; then
        echo "ERROR: $NEW failed health check after $MAX_RETRIES attempts — aborting deploy"
        echo ">>> $CURRENT remains active (rollback by inaction)"
        docker compose stop "$NEW"
        exit 1
    fi

    echo "    attempt $i/$MAX_RETRIES — status: $HEALTH — retrying in 2 s..."
    sleep 2
done

# ============================================================================
# Swap nginx upstream (zero-downtime cutover)
# ============================================================================
#
# Write a new upstream block pointing at the new slot. The file is bind-mounted
# into the nginx container (read-write), so nginx -s reload picks it up
# immediately without restarting the container.

printf 'upstream active_app {\n    server %s:8000;\n}\n' "$NEW" \
    > nginx/conf.d/active_upstream.conf

# Start nginx if it isn't running yet (first deploy or after a full stack restart).
# If it is already running, reload it to pick up the new upstream without
# dropping in-flight connections.
NGINX_STATUS=$(docker inspect --format '{{.State.Status}}' "$(docker compose ps -q nginx 2>/dev/null)" 2>/dev/null || echo "absent")

if [ "$NGINX_STATUS" = "running" ]; then
    docker compose exec nginx nginx -s reload
    echo ">>> nginx reloaded — traffic now flowing to $NEW"
else
    APP_IMAGE="$IMAGE" docker compose up -d --no-deps nginx
    echo ">>> nginx started — traffic now flowing to $NEW"
fi

# ============================================================================
# Gracefully stop the old slot
# ============================================================================

docker compose stop "$CURRENT"
echo ">>> Stopped old slot: $CURRENT"
echo ">>> Deployment complete: $CURRENT → $NEW"
