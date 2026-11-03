# czkawka (`czkawka_cli`): finds duplicate and similar images and videos, and can delete them. Its
# releases are static-enough binaries (glibc only) and it publishes no CLI image, so this installs
# the official release binary, checked against its pinned checksum, with ffmpeg for video mode.
# Contentoid's czkawka post-processor runs in this image, published as
# ghcr.io/paradox460/contentoid-czkawka by CI (.github/images.pkl); build locally with
# `docker compose -f compose.dev.yml build czkawka`. A new version needs both checksums updated
# (sha256sum of the release assets linux_czkawka_cli_x86_64 and linux_czkawka_cli_arm64).
FROM debian:trixie-slim

ARG CZKAWKA_VERSION=12.0.1
ARG CZKAWKA_SHA256_X86_64=612fdb68c245775b02c34cb52aa7a350ea89cd11fe7a3daf7fd947a26a679d2b
ARG CZKAWKA_SHA256_ARM64=82bcbb671b1cd833e0ecbdd57a39c1e729880fb1bc938ba6075d8d9a771d96d9
ARG TARGETARCH

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl ffmpeg \
  && case "$TARGETARCH" in \
       amd64) asset=linux_czkawka_cli_x86_64 sum="$CZKAWKA_SHA256_X86_64" ;; \
       arm64) asset=linux_czkawka_cli_arm64 sum="$CZKAWKA_SHA256_ARM64" ;; \
       *) echo "no czkawka build for $TARGETARCH" >&2; exit 1 ;; \
     esac \
  && curl -fsSL -o /usr/local/bin/czkawka_cli \
       "https://github.com/qarmin/czkawka/releases/download/${CZKAWKA_VERSION}/${asset}" \
  && echo "$sum  /usr/local/bin/czkawka_cli" | sha256sum -c - \
  && chmod 755 /usr/local/bin/czkawka_cli \
  && apt-get purge -y curl && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/*

# czkawka caches every file's hash here, so a named volume mounted at /cache spares rehashing a
# large reference directory on every run. World-writable (sticky), so a new volume, which copies
# this directory's mode, is writable by whatever user the container runs as.
RUN mkdir -m 1777 /cache

ENV HOME=/tmp XDG_CACHE_HOME=/cache XDG_CONFIG_HOME=/tmp
ENTRYPOINT ["czkawka_cli"]
