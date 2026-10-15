FROM ghcr.io/astral-sh/uv:python3.12-bookworm AS base

WORKDIR /app

# Copy configuration files
COPY pyproject.toml uv.lock ./

# UV_COMPILE_BYTECODE for generating .pyc files -> faster application startup.
# UV_LINK_MODE=copy to silence warnings about not being able to use hard links
# since the cache and sync target are on separate file systems.
# UV_HTTP_TIMEOUT=300 for large packages (nvidia, torch) on slow connections.
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_HTTP_TIMEOUT=300

# Install CPU-only PyTorch FIRST before uv sync.
# This prevents uv from downloading the ~4GB CUDA variant that PyPI serves
# on Linux amd64 by default. By pre-installing CPU torch here, uv sync
# finds torch already satisfied and skips the CUDA download entirely.
RUN --mount=type=cache,target=/root/.cache/uv \
    uv venv /app/.venv && \
    . /app/.venv/bin/activate && \
    uv pip install \
        torch torchvision torchaudio \
        --index-url https://download.pytorch.org/whl/cpu

# Install remaining dependencies (torch already satisfied, CUDA never downloaded)
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=/app/uv.lock \
    --mount=type=bind,source=pyproject.toml,target=/app/pyproject.toml \
    . /app/.venv/bin/activate && \
    uv sync --frozen --no-dev --no-install-package torch --no-install-package torchvision --no-install-package torchaudio

# Copy source code
COPY src /app/src

FROM python:3.12.8-slim AS final

EXPOSE 8000

# PYTHONUNBUFFERED=1 to disable output buffering
ENV PYTHONUNBUFFERED=1
ARG VERSION=0.1.0
ENV APP_VERSION=$VERSION

WORKDIR /app

# Copy the virtual environment from the base stage
COPY --from=base /app /app

# Add virtual environment to PATH
ENV PATH="/app/.venv/bin:$PATH"

# Run the application
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "4"]
