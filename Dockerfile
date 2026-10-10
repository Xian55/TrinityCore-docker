# syntax=docker/dockerfile:1

# TrinityCore's own images (built by their CI on every commit, binaries only) plus what it
# takes to run them: the config files, the TDB world database release, and an entrypoint that
# sets up the databases and the realm.
#
#   docker build --platform linux/amd64 --build-arg TC_BRANCH=cata_classic --build-arg TC_TAG=cata_classic .
#   docker build --platform linux/amd64 --build-arg TC_BRANCH=3.3.5 --build-arg TC_TAG=<commit> .
#
# The official images are amd64 only; on Apple silicon they run under Rosetta.

ARG TC_IMAGE=trinitycore/trinitycore
ARG TC_TAG=cata_classic

FROM ${TC_IMAGE}:${TC_TAG}

ARG TC_BRANCH=cata_classic
ARG TC_REPO_RAW=https://raw.githubusercontent.com/TrinityCore/TrinityCore

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
    raw="${TC_REPO_RAW}/${rev}"; \
    mkdir -p "$TC_CONF_DIR"; \
    for server in worldserver bnetserver authserver; do \
      [ -x "/usr/local/bin/$server" ] || continue; \
      curl -fsSL -o "$TC_CONF_DIR/$server.conf.dist" "$raw/src/server/$server/$server.conf.dist"; \
      cp "$TC_CONF_DIR/$server.conf.dist" "$TC_CONF_DIR/$server.conf"; \
      mkdir -p "$TC_CONF_DIR/$server.conf.d"; \
    done

# The world (and hotfixes) base data is a release download, named in revision_data.h.in.cmake.
# 3.3.5 ships it as TDB_full_world_<version>.7z, the classic branches as TDB_full_<version>.7z.
RUN set -eu; \
    raw="${TC_REPO_RAW}/$(cat /home/circleci/project/REVISION)"; \
    full=$(curl -fsSL "$raw/revision_data.h.in.cmake" | sed -n 's/.*_FULL_DATABASE *"\(.*\)\.sql".*/\1/p'); \
    rest=${full#TDB_full_world_}; \
    tag="TDB${rest%%_*}"; \
    mkdir -p /opt/tdb; \
    for asset in "TDB_full_${rest}.7z" "TDB_full_world_${rest}.7z"; do \
      if curl -fsSL -o "/opt/tdb/${asset}" "https://github.com/TrinityCore/TrinityCore/releases/download/${tag}/${asset}"; then \
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
      org.opencontainers.image.description="TrinityCore ${TC_BRANCH}, ready to run: official binaries, configs, TDB and database setup" \
      org.opencontainers.image.source="https://github.com/Xian55/TrinityCore-docker" \
      org.opencontainers.image.licenses="GPL-2.0-only"

ENTRYPOINT ["tc-entrypoint"]
CMD ["worldserver"]
