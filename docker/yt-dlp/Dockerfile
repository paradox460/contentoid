# yt-dlp with ffmpeg (merging formats, post-processing) and deno (YouTube's JavaScript challenges).
# yt-dlp publishes no image of its own. Contentoid's default yt-dlp downloader runs its script in this
# image, published as ghcr.io/paradox460/contentoid-yt-dlp by CI (.github/images.pkl); build locally
# with `docker compose -f compose.dev.yml build yt-dlp`. To update, bump the versions and rebuild:
# sites break often enough that yt-dlp wants a bump every few weeks.
ARG DENO_VERSION=2.9.8

FROM denoland/deno:bin-${DENO_VERSION} AS deno

FROM python:3.14-slim

ARG YT_DLP_VERSION=2026.10.26

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates ffmpeg \
  && rm -rf /var/lib/apt/lists/*

COPY --from=deno /deno /usr/local/bin/deno

RUN pip install --no-cache-dir "yt-dlp[default]==${YT_DLP_VERSION}"

# Writable by whatever user a container runs as. A named volume mounted here starts as a copy of
# this directory, permissions included, so it stays writable too (the default downloader keeps yt-dlp's
# cache in one).
RUN mkdir -m 1777 /cache

ENV HOME=/tmp XDG_CACHE_HOME=/cache
ENTRYPOINT ["yt-dlp"]
