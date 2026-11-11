# BakaShrot server image.
#
# Built from the repository's root, with the PB-MessagePack submodule checked
# out and a login to the registry holding the PureBasic images (they're
# licensed, so not public):
#   git submodule update --init --recursive
#   docker login git.nibblepoker.lu
#   docker build --provenance=false -t bakashrot-server -f Docker/Server/Dockerfile .
# Another compiler image: --build-arg COMPILER_IMAGE=<image>, any Debian 13
# (trixie) image with PureBasic's compilers on the PATH, gcc and libssl-dev.
#
# Run it with a config and a volume for the database:
#   docker run -d --name bakashrot -p 12345:12345 \
#     -v ./server.ini:/etc/bakashrot/server.ini:ro \
#     -v bakashrot-data:/var/lib/bakashrot \
#     bakashrot-server
# In server.ini's [BakaShrot.Server]: Port = 12345, Host empty (every
# interface: 127.0.0.1 can't be reached from outside the container), and
# DatabasePath = /var/lib/bakashrot/server.sqlite (relative paths are from
# that folder too).
#
# Or with docker-compose.yml, next to this file, and its empty server.ini
# to fill in.
#
# `docker stop` stops it cleanly (SIGTERM). Console commands (names, vacuum,
# restart...): start it with -it, then `docker attach bakashrot`, and
# detach with Ctrl+P, Ctrl+Q.


# --- Build ---------------------------------------------------------------------

# PureBasic 6.41 for linux3 (PureBasic's newest Linux build) on
# debian:trixie-slim, the same Debian as the runtime stage below.
ARG COMPILER_IMAGE=git.nibblepoker.lu/packages/purebasic:6.41-linux3-trixie-slim
FROM ${COMPILER_IMAGE} AS build

RUN apt-get update \
	&& apt-get install -y --no-install-recommends libsodium-dev \
	&& rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Everything Server/BakaShrot_Server.pb includes, and nothing else.
COPY Client/BakaShrot_ErrorCodes.pbi Client/
COPY Commons Commons
COPY Includes Includes
COPY Server Server

# The release build: C backend, optimized, thread-safe.
RUN mkdir /out && pbcompilerc --thread --optimizer Server/BakaShrot_Server.pb --executable /out/bakashrot-server


# --- Runtime -------------------------------------------------------------------

FROM debian:trixie-slim

# The source label links the package to the repository on ghcr.io. GitHub
# reads it from the image itself, not from an index: build with
# --provenance=false, or the attestation hides it (Docker/README.md).
LABEL org.opencontainers.image.source="https://github.com/aziascreations/BakaShrot" \
      org.opencontainers.image.description="BakaShrot server" \
      org.opencontainers.image.licenses="CC0-1.0"

# libsodium for the cryptography, SQLite 3.38+ for the storage: the server
# loads libsqlite3.so.0 itself (Server/Storage/Storage.pbi).
RUN apt-get update \
	&& apt-get install -y --no-install-recommends libsodium23 libsqlite3-0 \
	&& rm -rf /var/lib/apt/lists/*

RUN useradd --system --home-dir /var/lib/bakashrot --shell /usr/sbin/nologin bakashrot \
	&& mkdir -p /etc/bakashrot /var/lib/bakashrot \
	&& chown bakashrot:bakashrot /var/lib/bakashrot

COPY --from=build /out/bakashrot-server /usr/local/bin/bakashrot-server

USER bakashrot
WORKDIR /var/lib/bakashrot
VOLUME /var/lib/bakashrot
EXPOSE 12345

ENTRYPOINT ["/usr/local/bin/bakashrot-server"]
CMD ["/etc/bakashrot/server.ini"]
