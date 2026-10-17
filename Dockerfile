# syntax=docker/dockerfile:1

# TrinityCore binaries plus what it takes to run them: the config files, the TDB world database
# release, and an entrypoint that sets up the databases and the realm.
#
#   docker build --platform linux/amd64 --build-arg TC_BRANCH=cata_classic --build-arg TC_TAG=cata_classic .
#   docker build --platform linux/arm64 --build-arg TC_BRANCH=3.3.5 --build-arg TC_TAG=<commit> .
#   docker build --build-arg TC_GITHUB=Xian55/TrinityCore \
#                --build-arg TC_RELEASES=The-Cataclysm-Preservation-Project/TrinityCore \
#                --build-arg TC_BASE=compiled --build-arg TC_BRANCH=master --build-arg TC_TAG=master .
#   docker build --build-arg TC_GITHUB=Xian55/3.4.3_Source --build-arg TC_BASE=compiled \
#                --build-arg TC_BRANCH=main --build-arg TC_TAG=main --build-arg TC_DATABASES=<url> .
#
# amd64 starts from TrinityCore's own image (built by their CI for every commit). They publish no
# arm64 image, so on arm64 the same commit is compiled here, into the same layout, and everything
# after the base stage is shared. A fork without such an image is compiled on both.

ARG TC_IMAGE=trinitycore/trinitycore
# The official image's tag: the branch or a full commit hash. arm64 compiles that same ref.
ARG TC_TAG=cata_classic
# The GitHub repository the source, the config files and the TDB release come from.
ARG TC_GITHUB=TrinityCore/TrinityCore
# The repository whose releases hold that TDB, when TC_GITHUB is a fork without them.
ARG TC_RELEASES=
# Where the binaries come from. Empty: TC_IMAGE on amd64, compiled on arm64. "compiled": compiled
# on every architecture.
ARG TC_BASE=
# For source without an sql folder (Wrathion): the URL of a .7z holding one full dump per
# database, auth.sql, characters.sql, world.sql and hotfixes.sql, taken in place of a TDB release.
# TC_DATABASES_SHA256, when given, has to match the download.
ARG TC_DATABASES=
ARG TC_DATABASES_SHA256=
ARG UBUNTU_VERSION=24.04

FROM ${TC_IMAGE}:${TC_TAG} AS base-amd64


FROM ubuntu:${UBUNTU_VERSION} AS compile

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates git cmake make clang \
      libboost-all-dev libssl-dev libmysqlclient-dev \
      libreadline-dev libncurses-dev libbz2-dev zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

ARG TC_GITHUB
ARG TC_TAG
ARG TC_BRANCH=cata_classic
RUN git init --quiet /src \
 && git -C /src fetch --quiet --depth 1 "https://github.com/${TC_GITHUB}.git" "${TC_TAG}" \
 && git -C /src checkout --quiet -B "${TC_BRANCH}" FETCH_HEAD \
 && git -C /src log -1 --format='%H %cs %s'

# Source that predates TrinityCore's arm64 support (the 4.3.4 fork) fails there in two places.
# Each is looked for in the source, so a tree that has it fixed builds as written:
#  - the bundled jemalloc is set up for x86 (cmake never sets TRINITY_SYSTEM_PROCESSOR, so it
#    takes the x86 spin-wait instruction): the servers are built on the system allocator;
#  - PCGRand.cpp includes <emmintrin.h>, x86-only, for an aligned malloc: docker/arm64 has a
#    stand-in for that header.
COPY docker/arm64/ /opt/arm64/
RUN : > /tmp/cmake-args; \
    if [ "$(uname -m)" = aarch64 ]; then \
      if grep -qs TRINITY_SYSTEM_PROCESSOR /src/dep/jemalloc/CMakeLists.txt \
         && ! grep -rqs 'set(TRINITY_SYSTEM_PROCESSOR' /src/cmake /src/CMakeLists.txt; then \
        echo "-DNOJEM=1" >> /tmp/cmake-args; \
      fi; \
      if grep -qs '<emmintrin.h>' /src/src/common/Utilities/PCGRand.cpp; then \
        echo "-DCMAKE_CXX_FLAGS=-I/opt/arm64" >> /tmp/cmake-args; \
      fi; \
    fi; \
    echo "extra cmake arguments: $(tr '\n' ' ' < /tmp/cmake-args)"

# The official images' paths: the config directory is compiled in, and the entrypoint and the
# layers below expect binaries in /usr/local/bin and the SQL under /home/circleci/project.
ARG BUILD_JOBS=
RUN cmake -S /src -B /build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
      -DCMAKE_INSTALL_PREFIX=/home/circleci/project/bin/check_install \
      -DTOOLS=1 -DSERVERS=1 -DSCRIPTS=static \
      -DWITH_WARNINGS=0 -DWITH_COREDEBUG=0 -DBUILD_TESTING=0 \
      $(cat /tmp/cmake-args) \
 && cmake --build /build --parallel "${BUILD_JOBS:-$(nproc)}" \
 && cmake --install /build \
 && mkdir -p /out/usr/local/bin /out/usr/local/lib /out/home/circleci/project \
 && cp -a /home/circleci/project/bin/check_install/bin/. /out/usr/local/bin/ \
 && if [ -d /home/circleci/project/bin/check_install/lib ]; then cp -a /home/circleci/project/bin/check_install/lib/. /out/usr/local/lib/; fi \
 && if [ -d /src/sql ]; then cp -r /src/sql /out/home/circleci/project/; fi \
 && find /out/usr/local/bin -type f -perm -u+x -exec strip {} + \
 && rm -rf /build

# Runtime packages are whatever the binaries link against, resolved here so the list stays right
# on every branch.
RUN ldd /out/usr/local/bin/* 2>/dev/null \
      | awk '/=> \// { print $3 }' | sort -u \
      | while read -r lib; do dpkg -S "*/$(basename "$(readlink -f "$lib")")" 2>/dev/null | grep -v '^diversion ' | head -n1 | cut -d: -f1; done \
      | sort -u > /out/runtime-packages.txt \
 && cat /out/runtime-packages.txt


FROM ubuntu:${UBUNTU_VERSION} AS base-compiled

ARG DEBIAN_FRONTEND=noninteractive
COPY --from=compile /out/runtime-packages.txt /tmp/
RUN apt-get update \
 && xargs -a /tmp/runtime-packages.txt apt-get install -y --no-install-recommends \
 && apt-get install -y --no-install-recommends mysql-client-core-8.0 \
 && rm -rf /var/lib/apt/lists/* /tmp/runtime-packages.txt \
 && { userdel --remove ubuntu 2>/dev/null || true; } \
 && groupadd --gid 1002 circleci \
 && useradd --uid 1001 --gid 1002 --create-home --home-dir /home/circleci --shell /bin/bash circleci
COPY --from=compile /out/usr/local/ /usr/local/
COPY --from=compile --chown=circleci:circleci /out/home/circleci/project/ /home/circleci/project/
RUN ldconfig \
 && if ldd /usr/local/bin/* 2>/dev/null | grep 'not found'; then exit 1; fi
USER circleci
WORKDIR /home/circleci


FROM base-compiled AS base-arm64


FROM base-${TC_BASE:-${TARGETARCH}}

ARG TC_BRANCH=cata_classic
ARG TC_GITHUB
ARG TC_RELEASES
ARG TC_DATABASES
ARG TC_DATABASES_SHA256

USER root

# The base image's repo.mysql.com source has an expired signing key, which fails `apt-get update`;
# its mysql client is already installed and nothing here needs that repository.
RUN rm -f /etc/apt/sources.list.d/mysql.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl 7zip \
 && rm -rf /var/lib/apt/lists/*

# Everything else has to match the commit the binaries were built from, which they report.
ENV TC_CONF_DIR=/home/circleci/project/bin/check_install/etc
RUN set -eu; \
    rev=$(worldserver --version 2>/dev/null | sed -n 's/.*rev\. \([0-9a-f]\{12\}\).*/\1/p'); \
    test -n "$rev"; \
    echo "$rev" > /home/circleci/project/REVISION; \
    raw="https://raw.githubusercontent.com/${TC_GITHUB}/${rev}"; \
    mkdir -p "$TC_CONF_DIR"; \
    for server in worldserver bnetserver authserver; do \
      [ -x "/usr/local/bin/$server" ] || continue; \
      curl -fsSL -o "$TC_CONF_DIR/$server.conf.dist" "$raw/src/server/$server/$server.conf.dist"; \
      cp "$TC_CONF_DIR/$server.conf.dist" "$TC_CONF_DIR/$server.conf"; \
      mkdir -p "$TC_CONF_DIR/$server.conf.d"; \
    done

# TrinityCore reads TC_* environment variables over its config files. Source from before that
# (the 4.3.4 fork) does not, so the entrypoint writes them into the config file instead.
RUN set -eu; \
    raw="https://raw.githubusercontent.com/${TC_GITHUB}/$(cat /home/circleci/project/REVISION)"; \
    curl -fsSL -o /tmp/Config.cpp "$raw/src/common/Configuration/Config.cpp"; \
    if ! grep -q getenv /tmp/Config.cpp; then \
      touch "$TC_CONF_DIR/.env-to-conf"; \
      echo "no TC_* support in this source: the entrypoint writes the config files"; \
    fi; \
    rm /tmp/Config.cpp

# The world (and hotfixes) base data is a release download, named in revision_data.h.in.cmake.
# 3.3.5 ships it as TDB_full_world_<version>.7z, the classic branches as TDB_full_<version>.7z.
# With TC_DATABASES the full dumps are taken instead; the entrypoint imports those itself.
RUN set -eu; \
    if [ -n "${TC_DATABASES}" ]; then \
      mkdir -p /opt/databases; \
      curl -fsSL -o /opt/databases/databases.7z "${TC_DATABASES}"; \
      if [ -n "${TC_DATABASES_SHA256}" ]; then \
        echo "${TC_DATABASES_SHA256}  /opt/databases/databases.7z" | sha256sum -c -; \
      fi; \
      ls -l /opt/databases; \
      exit 0; \
    fi; \
    raw="https://raw.githubusercontent.com/${TC_GITHUB}/$(cat /home/circleci/project/REVISION)"; \
    full=$(curl -fsSL "$raw/revision_data.h.in.cmake" | sed -n 's/.*_FULL_DATABASE *"\(.*\)\.sql".*/\1/p'); \
    rest=${full#TDB_full_world_}; \
    tag="TDB${rest%%_*}"; \
    mkdir -p /opt/tdb; \
    for asset in "TDB_full_${rest}.7z" "TDB_full_world_${rest}.7z"; do \
      if curl -fsSL -o "/opt/tdb/${asset}" "https://github.com/${TC_RELEASES:-${TC_GITHUB}}/releases/download/${tag}/${asset}"; then \
        echo "${tag}/${asset}"; break; \
      fi; \
      rm -f "/opt/tdb/${asset}"; \
    done; \
    ls /opt/tdb/*.7z

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/tc-entrypoint

RUN mkdir -p /data /logs /client \
 && chown -R circleci:circleci /data /logs "$TC_CONF_DIR"

ENV TC_BRANCH=${TC_BRANCH} \
    TC_DATA_DIR=/data \
    TC_LOGS_DIR=/logs \
    TC_SOURCE_DIRECTORY=/home/circleci/project \
    TC_MY_SQLEXECUTABLE=/usr/bin/mysql \
    TC_CERTIFICATES_FILE=/usr/local/bin/bnetserver.cert.pem \
    TC_PRIVATE_KEY_FILE=/usr/local/bin/bnetserver.key.pem

USER circleci
WORKDIR /home/circleci
VOLUME ["/data", "/logs"]

LABEL org.opencontainers.image.title="TrinityCore ${TC_BRANCH}" \
      org.opencontainers.image.description="${TC_GITHUB} ${TC_BRANCH}, ready to run: binaries, configs, TDB and database setup" \
      org.opencontainers.image.source="https://github.com/Xian55/TrinityCore-docker" \
      org.opencontainers.image.licenses="GPL-2.0-only"

ENTRYPOINT ["tc-entrypoint"]
CMD ["worldserver"]
