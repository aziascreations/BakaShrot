# The BakaShrot server's image: bakashrot-server, with the bakashrot tool
# beside it (bakashrot cert for the certificates). Built from the
# repository's root:
#   docker build -f docker/Dockerfile -t bakashrot-server .
# CI builds it for amd64 and arm64 on a version tag, checks it
# (docker/test.sh) and pushes it to ghcr.io/aziascreations/bakashrot-server
# (.github/workflows/ci.yml).
#
# The config goes in /etc/bakashrot (read-only: server.toml, the CA's
# certificate, the server's certificate and key, the CRL if any), the
# database in /var/lib/bakashrot (a volume). In server.toml:
#   listen = "0.0.0.0:7000"      every interface: 127.0.0.1 isn't reachable
#                                from outside the container
#   database = "/var/lib/bakashrot/bakashrot.sqlite"
# and the certificates relative to it (ca = "ca.crt", ...). The server runs
# as uid 10001, which must be able to read its key (bakashrot cert writes
# keys readable by their owner only): chown 10001:10001 config/server-1.key
#
#   docker run -d --name bakashrot -p 7000:7000 \
#     -v ./config:/etc/bakashrot:ro -v bakashrot-data:/var/lib/bakashrot \
#     ghcr.io/aziascreations/bakashrot-server
#
# Or docker/compose.yml. `docker stop` stops it cleanly (SIGTERM).
# The tool: docker run --rm <image> bakashrot cert ... (or bakashrot push ...).


# --- Build ---------------------------------------------------------------------

FROM rust:1-slim-trixie AS build

WORKDIR /src
# Only what the programs are built from (Dockerfile.dockerignore).
COPY . .
# The toolchain rust-toolchain.toml pins, then the release build, the tool
# with its own profile (release-tools, Cargo.toml).
RUN rustup toolchain install \
	&& cargo build --release --locked -p bakashrot-server \
	&& cargo build --profile release-tools --locked -p bakashrot-tools \
	&& mkdir /out \
	&& cp target/release/bakashrot-server target/release-tools/bakashrot /out/


# --- Runtime -------------------------------------------------------------------

# The same Debian as the build: the programs only need its glibc.
FROM debian:trixie-slim

# The source label links the package to the repository on ghcr.io. CI
# pushes each architecture's image as is, then an index of both with the
# same as annotations: GitHub reads those on an index.
LABEL org.opencontainers.image.source="https://github.com/aziascreations/BakaShrot" \
      org.opencontainers.image.description="BakaShrot server" \
      org.opencontainers.image.licenses="CC0-1.0"

RUN groupadd --system --gid 10001 bakashrot \
	&& useradd --system --uid 10001 --gid 10001 --home-dir /var/lib/bakashrot --shell /usr/sbin/nologin bakashrot \
	&& mkdir -p /etc/bakashrot /var/lib/bakashrot \
	&& chown bakashrot:bakashrot /var/lib/bakashrot

COPY --from=build /out/ /usr/local/bin/

USER bakashrot
WORKDIR /var/lib/bakashrot
VOLUME /var/lib/bakashrot
EXPOSE 7000

CMD ["bakashrot-server", "/etc/bakashrot/server.toml"]
