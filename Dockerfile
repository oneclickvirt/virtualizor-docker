FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG='C.UTF-8' LANGUAGE='C.UTF-8' LC_ALL='C.UTF-8'
ARG S6_OVERLAY_VERSION=3.2.3.0
ARG TARGETARCH
ARG TARGETVARIANT

RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        cron \
        curl \
        e2fsprogs \
        fuse3 \
        gcc \
        gnupg \
        iproute2 \
        iputils-ping \
        kpartx \
        lsb-release \
        make \
        openssl \
        python-is-python3 \
        python3 \
        sendmail \
        tar \
        tzdata \
        unzip \
        vim \
        wget \
        xz-utils; \
    rm -rf /var/lib/apt/lists/*

# Add s6-overlay. BuildKit provides TARGETARCH/TARGETVARIANT for multi-arch builds.
RUN set -eux; \
    case "${TARGETARCH:-$(dpkg --print-architecture)}${TARGETVARIANT:-}" in \
        amd64|x86_64) s6_arch="x86_64" ;; \
        arm64|aarch64|arm64v8|aarch64v8) s6_arch="aarch64" ;; \
        armv7|arm/v7|armhf) s6_arch="armhf" ;; \
        armv6|arm/v6|arm|armel) s6_arch="arm" ;; \
        386|i386|i686) s6_arch="i686" ;; \
        *) echo "Unsupported architecture for s6-overlay: ${TARGETARCH:-unknown}${TARGETVARIANT:-}" >&2; exit 1 ;; \
    esac; \
    base_url="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    for asset in "s6-overlay-noarch.tar.xz" "s6-overlay-${s6_arch}.tar.xz" "s6-overlay-symlinks-noarch.tar.xz"; do \
        wget -q -O "/tmp/${asset}" "${base_url}/${asset}"; \
        wget -q -O "/tmp/${asset}.sha256" "${base_url}/${asset}.sha256"; \
        cd /tmp; sha256sum -c "${asset}.sha256"; \
        tar -C / -Jxpf "/tmp/${asset}"; \
        rm -f "/tmp/${asset}" "/tmp/${asset}.sha256"; \
    done

# Copy S6 init scripts
COPY s6/ /etc
COPY s6/scripts/healthcheck.sh /usr/local/bin/virtualizor-healthcheck
RUN chmod 0755 /usr/local/bin/virtualizor-healthcheck

ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2
HEALTHCHECK --interval=30s --timeout=10s --start-period=3m --retries=3 CMD ["/usr/local/bin/virtualizor-healthcheck"]
ENTRYPOINT ["/init"]
