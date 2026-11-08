# syntax=docker/dockerfile:1.10@sha256:865e5dd094beca432e8c0a1d5e1c465db5f998dca4e439981029b3b81fb39ed5
#
# Kanzo (https://github.com/emanuele-em/kanzo) as a multi-arch container image.
# Builds a static musl binary from the upstream git tag, cross-compiling on the
# build machine's own platform with tonistiigi/xx (no QEMU emulation needed).
#
#   docker buildx build --platform linux/amd64,linux/arm64 .                # default image
#   docker buildx build --platform linux/amd64,linux/arm64 --target git .   # + git for `kanzo sync`

# The upstream release, pinned by version and by its commit: a moved or replaced
# tag can't change what gets built. .github/workflows/upstream.yml updates both.
ARG KANZO_VERSION=0.4.1
ARG KANZO_COMMIT=672f302b9103ea621f39c7dea0d02018ea61d9bd

# Base images are pinned by digest (Dependabot keeps them current).
FROM --platform=$BUILDPLATFORM tonistiigi/xx:1.10.0@sha256:40fe21f44bb8cddf1eb1226db190d0a984118f62ee02a91b77d99448d28264a6 AS xx

# ---------------------------------------------------------------- build ----
FROM --platform=$BUILDPLATFORM rust:1.99-alpine3.24@sha256:44819b27be4c97b0e4d7203bd2e02c4820f97700211b6a37fb4c246a2de59383 AS build
COPY --from=xx / /
# clang + lld cross-link for any target; the target's musl headers and crt files come from xx-apk.
RUN apk add --no-cache clang lld
ARG TARGETPLATFORM
RUN xx-apk add --no-cache musl-dev gcc

ARG KANZO_VERSION
ARG KANZO_COMMIT
# BuildKit fetches the exact commit; the version check catches a commit/version mismatch.
ADD https://github.com/emanuele-em/kanzo.git#${KANZO_COMMIT} /src
WORKDIR /src
RUN grep -qx "version = \"${KANZO_VERSION}\"" Cargo.toml \
    || { echo "commit ${KANZO_COMMIT} is not Kanzo ${KANZO_VERSION}" >&2; exit 1; }

RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/git,sharing=locked \
    --mount=type=cache,target=/src/target,id=kanzo-target-${TARGETPLATFORM} \
    set -eux; \
    xx-cargo build --release --locked; \
    cp "target/$(xx-cargo --print-target-triple)/release/kanzo" /kanzo; \
    xx-verify --static /kanzo; \
    /kanzo --version 2>/dev/null || true

# -------------------------------------------------------------- runtime ----
FROM alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf AS runtime
ARG KANZO_VERSION
# Changes every day in CI, so the build cache never keeps yesterday's packages.
ARG PACKAGES_DATE

# tini: PID 1 that reaps the short-lived children kanzo runs (hostname, git).
# No curl on purpose: without it Kanzo's self-update can't run; update by pulling a new image tag.
# `apk upgrade`: security fixes published after the base image was built (the weekly
# rebuild picks them up even though the base image is pinned by digest).
RUN set -eux; \
    echo "packages as of ${PACKAGES_DATE:-build time}"; \
    apk upgrade --no-cache; \
    apk add --no-cache tini ca-certificates; \
    addgroup -S -g 10001 kanzo; \
    adduser -S -D -u 10001 -G kanzo -h /home/kanzo -s /sbin/nologin kanzo; \
    install -d -o kanzo -g kanzo -m 0700 /data

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
      '!f() { [ "$1" = get ] && [ -n "$KANZO_GIT_TOKEN" ] || exit 0; echo "username=${KANZO_GIT_USER:-x-access-token}"; echo "password=$KANZO_GIT_TOKEN"; }; f'; \
    # No package manager in the final image.
    apk --no-cache del apk-tools
USER 10001:10001

# ---------------------------------------------------- default (no git) -----
FROM runtime AS default
USER root
# No package manager in the final image.
RUN apk --no-cache del apk-tools
USER 10001:10001
