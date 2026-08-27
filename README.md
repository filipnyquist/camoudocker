# camoudocker

[![build](https://github.com/filipnyquist/camoudocker/actions/workflows/build.yml/badge.svg)](https://github.com/filipnyquist/camoudocker/actions/workflows/build.yml)

A [Camoufox remote server](https://camoufox.com/python/remote-server/) packaged into
`gcr.io/distroless/python3-debian12` — no shell, no package manager, no apt
database, running as a non-root user. Clients connect over websockets with
plain Playwright and never need Camoufox or a browser download of their own.

## Run it

```sh
docker run -d -p 4444:4444 --shm-size=2g ghcr.io/filipnyquist/camoudocker:latest
```

| Tag | Font sets | `CAMOUFOX_OS` | Size |
| --- | --- | --- | --- |
| `:latest` | Linux | `linux` | ~740 MB |
| `:latest-all` | Windows, macOS, Linux | rotates freely | ~1.7 GB |

Both are also tagged per commit (`:sha-abc1234`) and per release tag
(`:1.2.3`, `:1.2`). See [Image size](#image-size) for why the font sets are the
thing that decides which one you want.

To build it yourself:

```sh
docker compose up --build          # or:
docker build -t camoufox:distroless .
docker run -d -p 4444:4444 --shm-size=2g camoufox:distroless
```

Then, from anywhere that can reach the port:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.firefox.connect('ws://localhost:4444/camoufox')
    page = browser.new_page()
    page.goto('https://example.com')
```

`examples/client.py` is a runnable version of the above.

The client's Playwright version has to match the server's, or the connection is
closed during the handshake with `WebSocket was closed before the connection was
established`. Camoufox 0.5.5 pins Playwright 1.60.0, so clients need
`pip install playwright==1.60.0`. To read the version out of an image directly:

```sh
docker run --rm --entrypoint /usr/bin/python3.11 camoufox:distroless \
  -c 'from playwright._repo_version import version; print(version)'
```

`--shm-size=2g` is not optional in practice: Firefox puts its cross-process
shared memory in `/dev/shm`, and Docker's 64 MB default makes it crash on
heavier pages.

## Configuration

Everything is set through environment variables. Empty values are ignored, so
an unset variable and `VAR=""` behave the same.

| Variable | Default | Notes |
| --- | --- | --- |
| `CAMOUFOX_HOST` | `0.0.0.0` | Bind address inside the container. |
| `CAMOUFOX_PORT` | `4444` | |
| `CAMOUFOX_WS_PATH` | `camoufox` | Path component of the websocket URL. |
| `CAMOUFOX_HEADLESS` | `true` | The image ships no X server, so `false` will not start. |
| `CAMOUFOX_OS` | the font sets built in | `windows`, `macos`, `linux`, a comma-separated subset, or `all`. Only widen it to OSes whose fonts the image actually ships. |
| `CAMOUFOX_LOCALE` | | e.g. `en-US` or `de-DE,de`. |
| `CAMOUFOX_GEOIP` | off | `true` to derive locale/timezone/geolocation from the exit IP, or a literal IP. |
| `CAMOUFOX_PROXY_SERVER` | | e.g. `http://proxy:8080`, `socks5://proxy:1080`. |
| `CAMOUFOX_PROXY_USERNAME` / `_PASSWORD` / `_BYPASS` | | Only used when `_SERVER` is set. |
| `CAMOUFOX_HUMANIZE` | off | `true`, or a number for the max cursor-movement duration in seconds. |
| `CAMOUFOX_BLOCK_IMAGES` / `_BLOCK_WEBRTC` / `_BLOCK_WEBGL` | off | |
| `CAMOUFOX_WINDOW` | | `1280,720`. |
| `CAMOUFOX_ENABLE_CACHE`, `CAMOUFOX_MAIN_WORLD_EVAL`, `CAMOUFOX_DISABLE_COOP` | off | |
| `CAMOUFOX_FF_VERSION` | | Firefox major version to present. |
| `CAMOUFOX_EXCLUDE_ADDONS` | | `UBO` to drop the bundled uBlock Origin. |
| `CAMOUFOX_ARGS` | | JSON array of extra browser arguments. |
| `CAMOUFOX_CONFIG` / `CAMOUFOX_FIREFOX_USER_PREFS` | | JSON objects. |
| `CAMOUFOX_I_KNOW_WHAT_IM_DOING` | off | Silences Camoufox's leak warnings. |
| `CAMOUFOX_DEBUG` | off | |
| `CAMOUFOX_OPTIONS` | | JSON object merged last, for launch options with no variable of their own — `webgl_config`, `screen`, `fingerprint_preset`. |

Setting `CAMOUFOX_GEOIP=true` without a proxy makes the container look its own
public IP up at startup, which is one outbound request to a third-party
service. With a proxy configured, Camoufox uses the proxy's IP and no such
lookup happens.

## Read-only root filesystem

The image writes nowhere outside three paths, so it runs under `--read-only`:

```sh
docker run -d -p 4444:4444 --shm-size=2g --read-only \
  --tmpfs /tmp:rw,exec,mode=1777,size=512m \
  --tmpfs /home/nonroot:rw,mode=1777,size=64m \
  --tmpfs /opt/cache/fontconfig:rw,mode=1777,size=64m \
  camoufox:distroless
```

`mode=1777` is the part that is easy to get wrong: without it Docker mounts the
tmpfs root-owned and mode 0755, the non-root user cannot write, and the browser
hangs during launch instead of reporting an error.

## Image size

About 740 MB, built for Linux fingerprints only. Where it goes:

| | |
| --- | --- |
| Firefox core (`libxul.so`, `omni.ja`) | 294 MB |
| Playwright's Node runtime | 100 MB |
| Python dependencies (numpy, Playwright, ...) | 168 MB |
| distroless base | 55 MB |
| GeoLite2 database | 43 MB |
| Bundled Linux fonts | 40 MB |
| Collected shared libraries | 38 MB |
| uBlock Origin | 15 MB |

The thing that decides the size is fonts. Camoufox bundles the Windows, macOS
and Linux system font sets — 930 MB together, against a 294 MB browser — so
that the fonts a page can enumerate match the OS being spoofed. Keeping all
three makes the image about 1.7 GB.

`INCLUDE_FONTS` picks which sets to ship, and `CAMOUFOX_OS` is derived from it
at build time so the OSes the server spoofs can never drift away from the fonts
available to back them up:

```sh
docker build -t camoufox:distroless .                             # linux, ~740 MB
docker build --build-arg INCLUDE_FONTS=linux,windows -t ... .     # ~1.1 GB
docker build --build-arg INCLUDE_FONTS=all -t ... .               # ~1.7 GB, rotates freely
```

Do not widen `CAMOUFOX_OS` beyond the sets you built in. A fingerprint claiming
macOS while exposing a Linux-only font list is more detectable than not spoofing
at all.

Two more build arguments trade features for bytes. `INCLUDE_GEOIP=0` drops the
GeoLite2 database (43 MB) and makes `CAMOUFOX_GEOIP` unusable.
`INCLUDE_ADDONS=0` drops uBlock Origin (15 MB); the server then excludes it
automatically instead of trying to re-download it at launch.

`CAMOUFOX_VERSION` pins the Camoufox release, which also decides which browser
bundle is fetched. `PYTHON_VERSION` has to match the distroless base's
interpreter — 3.11 for `python3-debian12`.

Note that `docker pull` transfers roughly half these numbers: fonts and the
browser compress about 2:1 in the layer tarballs.

## How the image is put together

`gcr.io/distroless/python3-debian12` has a Python interpreter and glibc and
almost nothing else, while Camoufox is a Firefox build that wants GTK, X11 and
friends. There is no package manager in the final image to install those with,
so the build does it from the outside:

1. A `debian:bookworm-slim` builder — bookworm being the release distroless is
   built from, so the libraries stay ABI-compatible — installs Camoufox into a
   venv, runs `playwright install-deps firefox` for the browser's system
   dependencies, and runs `camoufox fetch` for the browser bundle, uBlock
   Origin and the GeoIP database.
2. `docker/collect-libs.sh` walks every ELF file in the browser bundle and in
   site-packages, resolves each one's shared libraries with `ldd`, and copies
   just those into a staging rootfs. Firefox also `dlopen`s a few libraries
   that no `DT_NEEDED` entry mentions, so the script resolves those by SONAME
   as well. glibc itself is skipped: the distroless base ships it, and its
   `ld.so` has to stay paired with its own `libc`.
3. Camoufox rewrites the bundled `fonts.conf` with absolute paths on first
   launch, and fontconfig then indexes the bundled fonts. The build does both
   ahead of time so the first request is not the one that pays for it.
4. `docker/prune-site-packages.sh` removes the packages that the launch path
   never imports — Camoufox's interactive CLI machinery, Rich's optional
   renderers, and a handful of transitive dependencies — and Playwright's
   bundled Node is stripped of its symbol table. The script documents how to
   re-derive that list after a Camoufox upgrade.
5. The runtime stage copies the staging rootfs, the browser cache, and
   site-packages onto distroless, and starts `docker/server.py` — which reads
   the environment variables above and calls `camoufox.server.launch_server`.

Because there is no shell in the final image, `docker exec` and
`docker run --entrypoint sh` will not work. To look inside, build the builder
stage instead: `docker build --target builder -t camoufox:builder .`.

## Known limitations

- **One browser instance per server.** This is Camoufox's design: every client
  that connects shares the same browser, so the fingerprint does not rotate
  between sessions. Run a server per session, or per pool slot, if you need
  rotation.
- **No WebGL.** Firefox cannot create a WebGL context in headless mode — it
  reports `FEATURE_FAILURE_WEBGL_EXHAUSTED_DRIVERS` and `getContext('webgl')`
  returns `null`. This is a Firefox limitation, not a consequence of the
  distroless base; a full Debian install with Mesa behaves identically.
  Getting WebGL requires running the browser against a real display (Xvfb),
  which this image deliberately does not include.
- The remote-server mode is marked experimental upstream and uses undocumented
  Playwright methods.
