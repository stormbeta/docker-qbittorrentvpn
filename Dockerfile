# qBittorrent, OpenVPN and WireGuard, qbittorrentvpn
#
# Only libtorrent-rasterbar and qBittorrent are compiled from source; Boost,
# CMake, Ninja and Qt6 come from Debian. Versions are pinned via build args so
# builds are reproducible:
#   docker build --build-arg QBITTORRENT_VERSION=release-5.2.3 .

ARG QBITTORRENT_VERSION=release-5.2.3
ARG LIBTORRENT_VERSION=v2.0.14


FROM debian:trixie-slim AS builder

ARG QBITTORRENT_VERSION
ARG LIBTORRENT_VERSION
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /opt

RUN apt update \
    && apt upgrade -y \
    && apt install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    cmake \
    curl \
    libboost-dev \
    libboost-system-dev \
    libssl-dev \
    ninja-build \
    pkg-config \
    qt6-base-dev \
    qt6-base-private-dev \
    qt6-l10n-tools \
    qt6-tools-dev \
    qt6-tools-dev-tools \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Compile and install libtorrent-rasterbar
RUN LIBTORRENT_TARBALL="libtorrent-rasterbar-${LIBTORRENT_VERSION#v}.tar.gz" \
    && curl -fsSL -o "/opt/${LIBTORRENT_TARBALL}" \
    "https://github.com/arvidn/libtorrent/releases/download/${LIBTORRENT_VERSION}/${LIBTORRENT_TARBALL}" \
    && tar -xzf "/opt/${LIBTORRENT_TARBALL}" \
    && rm "/opt/${LIBTORRENT_TARBALL}" \
    && cd /opt/libtorrent-rasterbar-* \
    && cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local \
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=ON \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build \
    && ldconfig \
    && cd /opt \
    && rm -rf /opt/libtorrent-rasterbar-*

# Compile and install qBittorrent
RUN curl -fsSL -o "/opt/qBittorrent-${QBITTORRENT_VERSION}.tar.gz" \
    "https://github.com/qbittorrent/qBittorrent/archive/${QBITTORRENT_VERSION}.tar.gz" \
    && tar -xzf "/opt/qBittorrent-${QBITTORRENT_VERSION}.tar.gz" \
    && rm "/opt/qBittorrent-${QBITTORRENT_VERSION}.tar.gz" \
    && cd /opt/qBittorrent-* \
    && cmake -G Ninja -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local -DGUI=OFF \
    && cmake --build build --parallel "$(nproc)" \
    && cmake --install build \
    && cd /opt \
    && rm -rf /opt/qBittorrent-*


FROM debian:trixie-slim AS runtime

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /opt

RUN usermod -u 99 nobody

# Make directories
RUN mkdir -p /downloads /config/qBittorrent /etc/openvpn /etc/qbittorrent

# qBittorrent runtime libraries, WireGuard/OpenVPN, and the utilities the
# scripts in /etc/vpn and /etc/qbittorrent rely on.
# sysvinit-utils provides /lib/init/vars.sh and /lib/lsb/init-functions, which
# qbittorrent.init sources. openssl is used to generate the WebUI certificate.
RUN apt update \
    && apt upgrade -y \
    && apt install -y --no-install-recommends \
    ca-certificates \
    dos2unix \
    inetutils-ping \
    ipcalc \
    iproute2 \
    iptables \
    kmod \
    libqt6core6t64 \
    libqt6network6 \
    libqt6sql6 \
    libqt6sql6-sqlite \
    libqt6xml6 \
    libssl3t64 \
    moreutils \
    net-tools \
    openresolv \
    openssl \
    openvpn \
    procps \
    sysvinit-utils \
    wireguard-tools \
    zlib1g \
    && apt-get clean \
    && apt --purge autoremove -y \
    && rm -rf \
    /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/*

# Install (un)compressing tools like unrar, 7z, unzip and zip
RUN echo "deb http://deb.debian.org/debian trixie main non-free" > /etc/apt/sources.list.d/non-free-unrar.list \
    && apt update \
    && apt -y upgrade \
    && apt -y install --no-install-recommends \
    unrar \
    p7zip-full \
    unzip \
    zip \
    && apt-get clean \
    && apt --purge autoremove -y \
    && rm -rf \
    /var/lib/apt/lists/* \
    /tmp/* \
    /var/tmp/*

COPY --from=builder /usr/local /usr/local
RUN ldconfig

# Remove src_valid_mark from wg-quick
RUN sed -i /net\.ipv4\.conf\.all\.src_valid_mark/d `which wg-quick`

VOLUME /config /downloads

COPY vpn/ /etc/vpn/
COPY qbittorrent/ /etc/qbittorrent/

RUN chmod +x /etc/qbittorrent/*.sh /etc/qbittorrent/*.init /etc/vpn/*.sh

EXPOSE 8080
EXPOSE 8999
EXPOSE 8999/udp
CMD ["/bin/bash", "/etc/vpn/start.sh"]
