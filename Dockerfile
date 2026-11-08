# syntax=docker/dockerfile:1.10
#
# Kanzo (https://github.com/emanuele-em/kanzo) as a multi-arch container image.
# Builds a static musl binary from the upstream git tag, cross-compiling on the
# build machine's own platform with tonistiigi/xx (no QEMU emulation needed).
#
#   docker buildx build --platform linux/amd64,linux/arm64 .                # default image
#   docker buildx build --platform linux/amd64,linux/arm64 --target git .   # + git for `kanzo sync`

ARG KANZO_VERSION=0.4.1
ARG RUST_VERSION=1.99
ARG ALPINE_VERSION=3.24
ARG XX_VERSION=1.10.0

FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

# ---------------------------------------------------------------- build ----
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION}-alpine${ALPINE_VERSION} AS build
COPY --from=xx / /
# clang + lld cross-link for any target; the target's musl headers and crt files come from xx-apk.
RUN apk add --no-cache clang lld
ARG TARGETPLATFORM
RUN xx-apk add --no-cache musl-dev gcc

ARG KANZO_VERSION
# BuildKit fetches the exact tag; --keep-git-dir is not needed for a cargo build.
ADD https://github.com/emanuele-em/kanzo.git#v${KANZO_VERSION} /src
WORKDIR /src

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/target,id=kanzo-target-${TARGETPLATFORM} \
    set -eux; \
    xx-cargo build --release --locked; \
    cp "target/$(xx-cargo --print-target-triple)/release/kanzo" /kanzo; \
    xx-verify --static /kanzo; \
    /kanzo --version 2>/dev/null || true

# -------------------------------------------------------------- runtime ----
FROM alpine:${ALPINE_VERSION} AS runtime
ARG KANZO_VERSION

# tini: PID 1 that reaps the short-lived children kanzo runs (hostname, git).
# No curl on purpose: without it Kanzo's self-update can't run; update by pulling a new image tag.
RUN set -eux; \
    apk add --no-cache tini ca-certificates; \
    addgroup -S -g 10001 kanzo; \
    adduser -S -D -u 10001 -G kanzo -h /home/kanzo -s /sbin/nologin kanzo; \
    install -d -o kanzo -g kanzo -m 0750 /data

COPY --from=build --chmod=0755 /kanzo /usr/local/bin/kanzo
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# HOME stays outside /data: `kanzo sync` commits everything in the data folder.
ENV KANZO_HOME=/data \
    HOME=/home/kanzo \
    KANZO_PORT=4242 \
    KANZO_MCP_HTTP=true

USER 10001:10001
WORKDIR /data
VOLUME ["/data"]
EXPOSE 4242

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -T 4 -O /dev/null "http://127.0.0.1:${KANZO_PORT}/api/ping" || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/sbin/tini", "--", "docker-entrypoint.sh"]
CMD ["kanzo"]

LABEL org.opencontainers.image.title="kanzo" \
      org.opencontainers.image.description="Kanzo kanban board + MCP server for humans and coding agents (unofficial container image)" \
      org.opencontainers.image.version="${KANZO_VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.url="https://github.com/emanuele-em/kanzo"

# ------------------------------------------------------------ git variant --
FROM runtime AS git
USER root
# KANZO_GIT_TOKEN (and optional KANZO_GIT_USER) authenticate `kanzo sync` over HTTPS.
# The helper reads them from the environment at call time: nothing is written to
# disk, the token never appears in a URL, and `docker exec … kanzo sync` works too.
RUN set -eux; \
    apk add --no-cache git openssh-client; \
    ! command -v curl; \
    git config --system credential.helper \
      '!f() { [ "$1" = get ] && [ -n "$KANZO_GIT_TOKEN" ] || exit 0; echo "username=${KANZO_GIT_USER:-x-access-token}"; echo "password=$KANZO_GIT_TOKEN"; }; f'
USER 10001:10001

# ---------------------------------------------------- default (no git) -----
FROM runtime AS default
