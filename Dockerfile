##############################################################################
# Stage: base
# Shared foundation — uv binary, system user, and common environment variables.
# Both the development and builder stages inherit from here to avoid repeating
# these instructions.
##############################################################################
FROM python:3.13-slim AS base

# Copy uv from the official distroless image — no installer script needed.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# PYTHONUNBUFFERED ensures stdout/stderr reach the container log driver
# immediately rather than being buffered.
ENV PYTHONUNBUFFERED=1
# Prevent uv from downloading a managed Python; use the system Python instead.
ENV UV_PYTHON_DOWNLOADS=0
# Required when using cache mounts: uv hard-links from its cache by default,
# which fails when the cache and the target directory live on different
# filesystems inside a BuildKit layer.
ENV UV_LINK_MODE=copy

# Non-root user for the production stage. Builder and development run as root
# so they can write to /app; production drops privileges.
RUN groupadd --gid 1000 appuser \
 && useradd --uid 1000 --gid appuser --shell /bin/bash --create-home appuser

WORKDIR /app


##############################################################################
# Stage: development
# All dependencies including dev tools (pytest, ruff). Hot-reload enabled.
# Runs as root so a bind-mounted source tree remains writable.
##############################################################################
FROM base AS development

# Suppress .pyc files — hot-reload makes them useless clutter at dev time.
ENV PYTHONDONTWRITEBYTECODE=1
ENV PATH="/app/.venv/bin:$PATH"

# STEP 1: Install ALL deps (runtime + dev) without the project package.
# This layer is invalidated only when uv.lock or pyproject.toml changes,
# so routine source edits do not re-trigger a full dependency install.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project

# STEP 2: Copy source code.
COPY . .

# STEP 3: Install the project itself (editable, with dev deps).
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked

EXPOSE 8000

# --reload watches for source changes when the directory is bind-mounted.
CMD ["/app/.venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]


##############################################################################
# Stage: builder
# Runtime dependencies only — no pytest, ruff, or other dev tooling.
# Compiles bytecode for a faster cold-start in production.
# The resulting .venv is the sole artifact copied into the production stage.
##############################################################################
FROM base AS builder

# Compile .pyc files at build time so the production container starts faster.
ENV UV_COMPILE_BYTECODE=1

# STEP 1: Install runtime deps only; omit dev deps entirely.
# Invalidated only when uv.lock or pyproject.toml changes.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev

# STEP 2: Copy source code.
COPY . .


##############################################################################
# Stage: production
# Fresh python:3.13-slim — uv is intentionally absent so the image cannot
# install or upgrade packages at runtime.  Only the virtual environment from
# the builder stage and the application source are copied in.
##############################################################################
FROM python:3.13-slim AS production

# Recreate appuser with the same UID/GID as in base so file ownership is
# consistent with what the builder wrote into .venv.
RUN groupadd --gid 1000 appuser \
 && useradd --uid 1000 --gid appuser --shell /bin/bash --create-home appuser

# Copy only the virtual environment from the builder stage.
# No uv binary, no dev dependencies, no lock files reach this image.
COPY --from=builder /app/.venv /app/.venv

# Copy application source separately from the builder's source tree.
# Only main.py is needed; tests, scripts, and config files are excluded.
COPY --from=builder /app/main.py /app/main.py

# Add .venv binaries to PATH and keep stdout unbuffered.
ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Drop to non-root before the process starts.
USER appuser

# Two-layer health check strategy:
#   1. Docker monitors this every 10 s and marks the container (un)healthy.
#   2. The deploy script polls this status before cutting nginx traffic over.
# Using Python's stdlib avoids adding curl/wget to the image.
HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')" || exit 1

EXPOSE 8000

CMD ["/app/.venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
