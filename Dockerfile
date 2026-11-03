# Contentoid's release image. CI builds and publishes it (.github/images.pkl); locally,
# `mise run release` or `docker build -t contentoid .`.
#
# Builder and runner share a Debian release; the versions match mise.lock.
#   - https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian - builder tags
#
# Running it: docs/deployment.md.

ARG ELIXIR_VERSION=1.20.5
ARG OTP_VERSION=29.1.2
ARG DEBIAN_VERSION=trixie-20261027-slim
ARG BUN_VERSION=1.4.4

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM docker.io/oven/bun:${BUN_VERSION} AS bun

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config before the deps, so a change recompiles them (Iconex reads its stroke
# width when it compiles).
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY assets/package.json assets/bun.lock assets/
RUN cd assets && bun install --frozen-lockfile

COPY priv priv
COPY lib lib
RUN mix compile

COPY assets assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code.
COPY config/runtime.exs config/

# CLDR locale data into the app's priv (config :localize, otp_app:), after `mix compile` made it.
RUN mix localize.download_locales

COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

ARG VERSION=dev
LABEL org.opencontainers.image.title="Contentoid" \
      org.opencontainers.image.version="${VERSION}"
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"

ENV MIX_ENV="prod"
# The release writes its runtime config here at boot. /tmp, so the image runs as any user: run it
# as the host user who should own the downloads (`--user`), not the default `nobody`.
ENV RELEASE_TMP=/tmp
ENV PORT=4100

# Readable by any user; only RELEASE_TMP is written.
COPY --from=builder --chown=root:root /app/_build/${MIX_ENV}/rel/contentoid ./

USER nobody

EXPOSE 4100

# Migrations first, then the server; the BEAM handles SIGTERM itself as PID 1.
CMD ["/bin/sh", "-c", "/app/bin/migrate && exec /app/bin/server"]
