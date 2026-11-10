# PureBasic compiler image, console programs only (no GUI libraries).
#
# PureBasic's Linux build needs glibc 2.38+, hence Debian 13 (glibc 2.41).
# The PureBasic archive isn't in git (it's licensed): copy it next to this
# file first, then:
#   docker build -t purebasic:6.41 --build-arg PUREBASIC_ARCHIVE=PureBasic_Linux3_X64_6.41_xxxx.tgz Docker/Compiler
#   docker run --rm -v "$PWD":/src -w /src purebasic:6.41 pbcompiler -t Server/BakaShrot_Server.pb -e Build/BakaShrot_Server
# Both backends are on the PATH: pbcompiler (asm) and pbcompilerc (C).

FROM debian:trixie-slim

# gcc links every program (and is the C backend), libssl-dev is for
# PureBasic's Network library.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends gcc libc6-dev libssl-dev \
	&& rm -rf /var/lib/apt/lists/*

ARG PUREBASIC_ARCHIVE
ADD ${PUREBASIC_ARCHIVE} /opt/

ENV PUREBASIC_HOME=/opt/purebasic
ENV PATH=/opt/purebasic/compilers:$PATH
