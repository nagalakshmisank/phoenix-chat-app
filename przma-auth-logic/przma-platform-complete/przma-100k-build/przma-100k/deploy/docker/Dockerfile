# deploy/docker/Dockerfile
#
# Multi-stage Docker build for PRZMA Phoenix application.
# Stage 1: Build the Elixir release + compile Rust NIFs
# Stage 2: Minimal runtime image
#
# The final image is ~150MB (Debian slim + BEAM runtime + compiled NIFs).
# No Elixir or Rust toolchain in the final image.

# ── STAGE 1: Builder ──────────────────────────────────────────────────────────
FROM elixir:1.16-otp-26-slim AS builder

# Install Rust (for Rustler NIFs) and system dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    curl \
    git \
    libssl-dev \
    pkg-config \
    && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /app

# Install Hex and Rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency files first (for layer caching)
COPY mix.exs mix.lock ./
COPY config config/

# Install Elixir dependencies
ENV MIX_ENV=prod
RUN mix deps.get --only prod

# Copy Rust NIF source (Rustler compiles this during mix compile)
COPY native native/

# Copy application source
COPY lib lib/
COPY priv priv/

# Compile (this compiles Rust NIFs via Rustler)
RUN mix compile

# Build the Elixir release
RUN mix release przma

# ── STAGE 2: Runtime ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

# Install runtime dependencies only (no build tools)
RUN apt-get update && apt-get install -y \
    libssl3 \
    libncurses6 \
    ca-certificates \
    curl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN useradd --uid 1000 --gid 0 --shell /bin/bash --create-home przma

WORKDIR /app

# Copy the compiled release from builder
COPY --from=builder --chown=przma:root /app/_build/prod/rel/przma ./

# Copy entrypoint
COPY --chown=przma:root deploy/docker/entrypoint.sh /app/bin/entrypoint.sh
RUN chmod +x /app/bin/entrypoint.sh

USER przma

# Data directory for vault files (mounted as volume)
RUN mkdir -p /data/vaults /data/logs /etc/przma/keys

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:4000/health || exit 1

ENTRYPOINT ["/app/bin/entrypoint.sh"]
CMD ["start"]
