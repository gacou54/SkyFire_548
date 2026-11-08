# syntax=docker/dockerfile:1.7
#
# This file is part of Project SkyFire https://www.projectskyfire.org.
# See COPYRIGHT file for Copyright information
#
# Builds worldserver, authserver and the map/vmap/mmap tools into a single
# runtime image. See doc/Docker.md and docker-compose.yml.

ARG UBUNTU_VERSION=24.04

############################################################################
# deps: toolchain + Boost (headers) + OpenSSL with the legacy provider.
# Kept separate so source changes don't rebuild Boost/OpenSSL.
############################################################################
FROM ubuntu:${UBUNTU_VERSION} AS deps

ARG BOOST_VERSION=1.91.0
ARG OPENSSL_VERSION=4.0.0
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        ccache \
        cmake \
        g++-14 \
        gcc-14 \
        libbz2-dev \
        libmysqlclient-dev \
        libreadline-dev \
        ninja-build \
        perl \
        pkg-config \
        wget \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    boost_dir="boost_$(echo "$BOOST_VERSION" | tr . _)"; \
    cd /tmp; \
    wget -q "https://archives.boost.io/release/${BOOST_VERSION}/source/${boost_dir}.tar.gz"; \
    tar -xzf "${boost_dir}.tar.gz"; \
    cd "${boost_dir}"; \
    ./bootstrap.sh; \
    ./b2 install --prefix=/opt/boost --with-headers -j"$(nproc)"; \
    cd /; rm -rf /tmp/boost_*

RUN set -eux; \
    cd /tmp; \
    wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"; \
    tar -xzf "openssl-${OPENSSL_VERSION}.tar.gz"; \
    cd "openssl-${OPENSSL_VERSION}"; \
    ./Configure \
        --prefix=/opt/openssl \
        --openssldir=/opt/openssl/ssl \
        --libdir=lib \
        shared \
        enable-legacy \
        no-tests; \
    make -j"$(nproc)"; \
    make install_sw install_ssldirs; \
    cd /; rm -rf /tmp/openssl-*

############################################################################
# build: compile and install SkyFire into /opt/skyfire.
############################################################################
FROM deps AS build

ARG BUILD_TYPE=Release
ARG BUILD_JOBS=
ARG SCRIPTS=ON
ARG MODULES=ON
ARG TOOLS=ON

ENV CCACHE_DIR=/ccache \
    CCACHE_MAXSIZE=5G \
    CCACHE_SLOPPINESS=pch_defines,time_macros,include_file_mtime,include_file_ctime \
    LD_LIBRARY_PATH=/opt/openssl/lib

# Only the inputs the build needs, so SQL/doc edits don't invalidate this layer.
COPY CMakeLists.txt PreLoad.cmake revision.h.in.cmake /src/
COPY cmake /src/cmake
COPY dep /src/dep
COPY modules /src/modules
COPY src /src/src

RUN --mount=type=cache,target=/ccache,id=skyfire-ccache \
    set -eux; \
    cmake -S /src -B /build -G Ninja \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_C_COMPILER=gcc-14 \
        -DCMAKE_CXX_COMPILER=g++-14 \
        -DCMAKE_C_COMPILER_LAUNCHER=ccache \
        -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
        -DCMAKE_INSTALL_PREFIX=/opt/skyfire \
        -DCONF_DIR=/opt/skyfire/etc \
        -DSCRIPTS="${SCRIPTS}" \
        -DMODULES="${MODULES}" \
        -DTOOLS="${TOOLS}" \
        -DPACKET_LOG_SERVER=OFF \
        -DSKYFIRE_BUILD_TESTS=OFF \
        -DWITHOUT_GIT=ON \
        -DBOOST_ROOT=/opt/boost \
        -DOPENSSL_ROOT_DIR=/opt/openssl; \
    cmake --build /build --parallel "${BUILD_JOBS:-$(nproc)}"; \
    cmake --install /build; \
    ccache --show-stats || true; \
    rm -rf /build

############################################################################
# runtime
############################################################################
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG SKYFIRE_UID=1000
ARG SKYFIRE_GID=1000
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        libbz2-1.0 \
        libmysqlclient21 \
        libreadline8t64 \
        mysql-client-core-8.0 \
        unzip \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

# ubuntu images ship a uid/gid 1000 "ubuntu" account; replace it.
RUN set -eux; \
    userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g "${SKYFIRE_GID}" skyfire; \
    useradd -u "${SKYFIRE_UID}" -g skyfire -d /opt/skyfire -s /bin/bash skyfire

COPY --from=deps /opt/openssl/lib /opt/openssl/lib
COPY --from=build /opt/skyfire /opt/skyfire
COPY sql/base /opt/skyfire/sql/base
COPY sql/updates /opt/skyfire/sql/updates
COPY sql/pending_updates /opt/skyfire/sql/pending_updates
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/skyfire-entrypoint
COPY --chmod=755 docker/extract-data.sh /usr/local/bin/skyfire-extract-data

ENV PATH=/opt/skyfire/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/openssl/lib \
    OPENSSL_MODULES=/opt/openssl/lib/ossl-modules

# Fail the image build early if a shared library is missing.
RUN set -eux; \
    for bin in /opt/skyfire/bin/*; do \
        if ldd "$bin" | grep -q "not found"; then ldd "$bin"; exit 1; fi; \
    done; \
    mkdir -p /opt/skyfire/data /opt/skyfire/logs /opt/skyfire/dbdump /opt/skyfire/run; \
    chown -R skyfire:skyfire /opt/skyfire

USER skyfire
WORKDIR /opt/skyfire/bin

EXPOSE 3724 8085

ENTRYPOINT ["skyfire-entrypoint"]
CMD ["worldserver"]
