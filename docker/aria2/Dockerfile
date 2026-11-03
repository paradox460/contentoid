# aria2 (`aria2c`): segmented, resumable HTTP(S) and FTP downloads, plus curl and jq for driving its
# JSON-RPC interface from a shell script. aria2 publishes no image of its own. Contentoid's default
# aria2c downloader runs its script in this image, published as ghcr.io/paradox460/contentoid-aria2
# by CI (.github/images.pkl); build locally with `docker compose -f compose.dev.yml build aria2`.
FROM alpine:3.24

ARG ARIA2_VERSION=1.37.0-r2

RUN apk add --no-cache "aria2=${ARIA2_VERSION}" ca-certificates curl jq

ENV HOME=/tmp
ENTRYPOINT ["aria2c"]
