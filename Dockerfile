# Camoufox remote server (https://camoufox.com/python/remote-server/) on a
# Google distroless base.
#
# The builder installs Camoufox on Debian bookworm -- the release distroless is
# built from, so the libraries stay ABI-compatible -- fetches the browser
# bundle, and collects only the shared libraries the browser really loads. The
# runtime stage layers those onto distroless/python3-debian12, which has no
# shell and no package manager.

ARG PYTHON_VERSION=3.11

# Which of Camoufox's bundled font sets to keep: `all`, or a comma-separated
# subset of linux,macos,windows. This is the single biggest thing in the image
# -- Camoufox ships all three so the fonts a page can enumerate match the OS
# being spoofed, and together they are 930 MB (macOS 570, Windows 320, Linux
# 40) against a 290 MB browser. The runtime stage derives CAMOUFOX_OS from
# this, so the OSes the server will spoof can never drift away from the fonts
# available to back them up.
ARG INCLUDE_FONTS=linux

# ---------------------------------------------------------------- builder ---
FROM debian:bookworm-slim AS builder

ARG PYTHON_VERSION
# Pinned so a rebuild fetches the same browser bundle. Bump deliberately.
ARG CAMOUFOX_VERSION=0.5.5

ARG INCLUDE_FONTS
# The GeoLite2 database, 43 MB. Only read when CAMOUFOX_GEOIP is set.
ARG INCLUDE_GEOIP=1
# The bundled uBlock Origin build, 15 MB. When dropped, the server excludes it
# automatically rather than re-downloading it at launch.
ARG INCLUDE_ADDONS=1

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    VIRTUAL_ENV=/opt/venv \
    PATH=/opt/venv/bin:$PATH \
    XDG_CACHE_HOME=/opt/cache

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        ca-certificates \
        fontconfig \
        python3 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv "$VIRTUAL_ENV" \
    && pip install "camoufox[geoip]==${CAMOUFOX_VERSION}"

# Firefox's runtime dependencies (GTK, X11, ...). Playwright keeps this list in
# step with the Firefox it ships; collect-libs.sh trims it back down afterwards.
RUN apt-get update \
    && playwright install-deps firefox \
    && apt-get install -y --no-install-recommends libcups2 \
    && rm -rf /var/lib/apt/lists/*

# Browser bundle, uBlock Origin and the GeoIP database, into $XDG_CACHE_HOME.
RUN python3 -m camoufox fetch > /tmp/fetch.log 2>&1 || (cat /tmp/fetch.log; exit 1)

RUN set -eu; \
    if [ "$INCLUDE_FONTS" != all ]; then \
        for name in $(echo "$INCLUDE_FONTS" | tr ',' ' '); do \
            case "$name" in \
                linux|macos|windows) ;; \
                *) echo "INCLUDE_FONTS: unknown font set '$name'" >&2; exit 1 ;; \
            esac; \
        done; \
        for name in linux macos windows; do \
            case ",$INCLUDE_FONTS," in \
                *",$name,"*) ;; \
                *) rm -rf /opt/cache/camoufox/browsers/*/*/fonts/"$name" ;; \
            esac; \
        done; \
    fi; \
    [ "$INCLUDE_GEOIP" = 1 ] || rm -rf /opt/cache/camoufox/geoip; \
    [ "$INCLUDE_ADDONS" = 1 ] || rm -rf /opt/cache/camoufox/addons

# Camoufox rewrites the bundled fonts.conf with absolute paths on first launch,
# and fontconfig then indexes ~2000 bundled fonts. Doing both now keeps the
# first request fast and lets the container run with a read-only root filesystem.
RUN python3 -c "\
from camoufox.utils import get_env_vars; \
print('\n'.join(get_env_vars({}, os_name)['FONTCONFIG_FILE'] for os_name in ('lin', 'mac', 'win')))" \
        > /tmp/fontconfigs.txt \
    && while read -r conf; do FONTCONFIG_FILE="$conf" fc-cache --force; done < /tmp/fontconfigs.txt

# Shrink site-packages: the image never installs anything, so pip and friends
# are dead weight, and Playwright's bundled Node ships with a symbol table it
# does not need to run (17 MB). Stripping leaves .dynsym intact, so dynamic
# linking still works.
COPY docker/prune-site-packages.sh /usr/local/bin/prune-site-packages.sh
RUN pip uninstall -y pip setuptools wheel \
    && rm -rf /opt/venv/lib/python${PYTHON_VERSION}/site-packages/pkg_resources \
              /opt/venv/bin /opt/venv/include /opt/venv/share \
    && /usr/local/bin/prune-site-packages.sh /opt/venv/lib/python${PYTHON_VERSION}/site-packages \
    && strip --strip-unneeded /opt/venv/lib/python${PYTHON_VERSION}/site-packages/playwright/driver/node

COPY docker/collect-libs.sh /usr/local/bin/collect-libs.sh
RUN /usr/local/bin/collect-libs.sh /rootfs \
        /opt/cache/camoufox/browsers \
        /opt/venv/lib/python${PYTHON_VERSION}/site-packages

# The only paths written at runtime are these two caches, $HOME (already
# nonroot-owned in the base image) and /tmp. Everything else can stay
# root-owned, which is what makes --read-only workable.
RUN chown -R 65532:65532 /opt/cache/fontconfig /opt/cache/camoufox/fontconfig

# ---------------------------------------------------------------- runtime ---
FROM gcr.io/distroless/python3-debian12:nonroot

ARG PYTHON_VERSION
ARG INCLUDE_FONTS

COPY --from=builder /rootfs/ /
COPY --from=builder /opt/cache /opt/cache
COPY --from=builder /opt/venv/lib/python${PYTHON_VERSION}/site-packages /opt/camoufox/site-packages
COPY docker/server.py /opt/camoufox/server.py

ENV PYTHONPATH=/opt/camoufox/site-packages \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    XDG_CACHE_HOME=/opt/cache \
    HOME=/home/nonroot \
    CAMOUFOX_PORT=4444 \
    CAMOUFOX_WS_PATH=camoufox \
    CAMOUFOX_OS=$INCLUDE_FONTS

EXPOSE 4444
USER nonroot
# Exec-form ENTRYPOINT cannot expand ARGs, so this interpreter path is spelled
# out; it has to stay in step with PYTHON_VERSION and the distroless base.
ENTRYPOINT ["/usr/bin/python3.11", "/opt/camoufox/server.py"]
