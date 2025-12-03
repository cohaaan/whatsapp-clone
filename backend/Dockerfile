# Multi-stage Dockerfile for Production

ARG ELIXIR_VERSION=1.16.0
ARG OTP_VERSION=26.2
ARG DEBIAN_VERSION=bookworm-20231009

FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}-slim AS builder

WORKDIR /app

# Install build dependencies
RUN apt-get update -y && apt-get install -y \
    build-essential \
    git \
    nodejs \
    npm \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Install Hex + Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Set build ENV
ENV MIX_ENV="prod"

# Install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Copy compile-time config files before we compile dependencies
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# Copy application code
COPY priv priv
COPY lib lib

# Compile application
RUN mix compile

# Build assets (if any)
# COPY assets assets
# RUN mix assets.deploy

# Build release
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# Runtime stage
FROM debian:${DEBIAN_VERSION}-slim AS runner

# Install runtime dependencies
RUN apt-get update -y && apt-get install -y \
    libstdc++6 \
    openssl \
    libncurses5 \
    locales \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Increase file descriptor limits
RUN echo "* soft nofile 1000000" >> /etc/security/limits.conf && \
    echo "* hard nofile 1000000" >> /etc/security/limits.conf

WORKDIR /app

# Set runner ENV
ENV MIX_ENV="prod"

# Copy release from builder
COPY --from=builder /app/_build/prod/rel/chat ./

# Create user for running the app
RUN useradd -m -u 1001 chat && \
    chown -R chat:chat /app

USER chat

# Expose ports
EXPOSE 4000

# Start the Phoenix app
CMD ["bin/chat", "start"]
