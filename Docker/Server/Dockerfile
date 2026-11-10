# BakaShrot server image.
#
# Built from the repository's root, with the compiler image (Docker/Compiler)
# already built, and the PB-MessagePack submodule checked out:
#   git submodule update --init --recursive
#   docker build -t bakashrot-server -f Docker/Server/Dockerfile .
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
# `docker stop` stops it cleanly (SIGTERM). Console commands (names, vacuum,
# restart...): start it with -it, then `docker attach bakashrot`, and
# detach with Ctrl+P, Ctrl+Q.


# --- Build ---------------------------------------------------------------------

ARG COMPILER_IMAGE=purebasic:6.41
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
