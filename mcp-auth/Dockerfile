# syntax=docker/dockerfile:1.10@sha256:865e5dd094beca432e8c0a1d5e1c465db5f998dca4e439981029b3b81fb39ed5
#
# sigbit/mcp-auth-proxy (https://github.com/sigbit/mcp-auth-proxy, MIT) as a small static
# image for deploy/compose.mcp-oauth.yaml: OAuth sign-in (with GitHub) in front of Kanzo's
# /mcp, so Claude and other MCP clients connect without a shared password.
# Upstream's own image also carries Node.js and Python for stdio servers; this one is only
# the Go binary on distroless, running as a non-root user.
#
#   docker buildx build --platform linux/amd64,linux/arm64 mcp-auth

# The upstream release, pinned by version and by its commit: a moved or replaced tag
# can't change what gets built.
ARG UPSTREAM_VERSION=2.10.2
ARG UPSTREAM_COMMIT=c8868adee557e793b73c7e8a3b3d37e080854c20

# Base images are pinned by digest (Dependabot keeps them current).
FROM --platform=$BUILDPLATFORM golang:1.26-alpine@sha256:87c65a688975c0b1d4585d204874c45ca78354670e3a5f11368c5a492303d696 AS build
ARG UPSTREAM_COMMIT
# BuildKit fetches the exact commit.
ADD https://github.com/sigbit/mcp-auth-proxy.git#${UPSTREAM_COMMIT} /src
WORKDIR /src
# Build with the Go in this image, never a toolchain downloaded on the fly.
ENV GOTOOLCHAIN=local CGO_ENABLED=0
RUN --mount=type=cache,target=/root/go/pkg/mod go mod download
ARG TARGETOS
ARG TARGETARCH
RUN --mount=type=cache,target=/root/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w" -o /out/mcp-auth-proxy . \
 && mkdir -p /out/data /out/licenses \
 && cp LICENSE /out/licenses/LICENSE

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
ARG UPSTREAM_VERSION
LABEL org.opencontainers.image.title="mcp-auth-proxy for Kanzo" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.licenses="MIT"
COPY --from=build /out/mcp-auth-proxy /usr/local/bin/mcp-auth-proxy
COPY --from=build /out/licenses /usr/share/licenses/mcp-auth-proxy
# Signing keys, client registrations and tokens live here: mount a volume.
COPY --from=build --chown=65532:65532 /out/data /data
# Plain HTTP behind Caddy, which does HTTPS: never try to get a certificate itself.
ENV DATA_PATH=/data \
    LISTEN=:8080 \
    NO_AUTO_TLS=true
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/mcp-auth-proxy"]
