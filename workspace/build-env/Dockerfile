# GrapheneOS 17 build + headless emulator environment for n5 (phase W1).
# The source tree is bind-mounted, not copied: /src = /mnt/flash/scratch/grapheneos.
# Build: workspace/build-env/run.sh build    Shell: workspace/build-env/run.sh shell
FROM ubuntu:24.04

ARG UID=3000
ARG GID=3000

ENV DEBIAN_FRONTEND=noninteractive
# AOSP build deps (source.android.com/docs/setup/start/requirements) + emulator runtime libs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git git-lfs gnupg flex bison build-essential zip unzip curl ca-certificates \
        zlib1g-dev libc6-dev-i386 x11proto-core-dev libx11-dev lib32z1-dev \
        libgl1-mesa-dev libxml2-utils xsltproc fontconfig python3 python-is-python3 \
        rsync openssl libssl-dev ccache procps less vim-tiny \
        libpulse0 libnss3 libxcomposite1 libxcursor1 libxdamage1 libxi6 libxtst6 \
        libxkbfile1 libxrandr2 libasound2t64 libdrm2 libgbm1 \
    && rm -rf /var/lib/apt/lists/*

# Match faeton's uid/gid so files in the bind-mounted tree stay owned by faeton.
# ubuntu:24.04 ships a uid-1000 "ubuntu" user; 3000 is free.
RUN groupadd -g ${GID} faeton && useradd -m -u ${UID} -g ${GID} -s /bin/bash faeton \
    && groupadd -f kvm && usermod -aG kvm faeton

USER faeton
# OUT_DIR stays at its default (relative "out"): siso fails to load its config from an
# absolute config dir, and soong derives that dir from OUT_DIR.
ENV PATH=/src/bin:$PATH \
    USE_CCACHE=1 CCACHE_DIR=/src/.ccache
WORKDIR /src/grapheneos-17
