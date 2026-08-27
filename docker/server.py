#!/usr/bin/env python3
"""Entrypoint for the distroless Camoufox image.

Reads CAMOUFOX_* environment variables, turns them into keyword arguments for
``camoufox.server.launch_server``, and starts the Playwright websocket server.
Anything not covered by a dedicated variable can be passed as JSON through
CAMOUFOX_OPTIONS.
"""

from __future__ import annotations

import json
import os
import sys
from typing import Any, Callable, Dict, List, Optional, Tuple

from camoufox.addons import ADDONS_DIR, DefaultAddons
from camoufox.server import launch_server


def as_bool(value: str) -> bool:
    lowered = value.strip().lower()
    if lowered in ('1', 'true', 'yes', 'on'):
        return True
    if lowered in ('0', 'false', 'no', 'off'):
        return False
    raise ValueError(f'expected a boolean, got {value!r}')


def as_bool_or_str(value: str) -> Any:
    """geoip=True to look the IP up, or geoip="1.2.3.4" to pin it."""
    try:
        return as_bool(value)
    except ValueError:
        return value


def as_bool_or_float(value: str) -> Any:
    """humanize=True for the default cursor delay, or a max duration in seconds."""
    try:
        return as_bool(value)
    except ValueError:
        return float(value)


def as_list(value: str) -> List[str]:
    return [item.strip() for item in value.split(',') if item.strip()]


def as_os_list(value: str) -> Optional[List[str]]:
    """`all` means every font set the image shipped with, which is also what
    Camoufox does when the option is left off entirely. Any other value is the
    explicit list of OSes to spoof.
    """
    if value.strip().lower() == 'all':
        return None
    return as_list(value)


def as_addons(value: str) -> List[DefaultAddons]:
    return [DefaultAddons[name.upper()] for name in as_list(value)]


def as_window(value: str) -> Tuple[int, int]:
    width, height = as_list(value)
    return int(width), int(height)


# Environment variable (minus the CAMOUFOX_ prefix) -> launch_server kwarg parser.
# Keys not listed here are Playwright's own launchServer options (host, port,
# ws_path); Camoufox forwards unknown kwargs to it untouched.
PARSERS: Dict[str, Callable[[str], Any]] = {
    'HOST': str,
    'PORT': int,
    'WS_PATH': str,
    'HEADLESS': as_bool,
    'OS': as_os_list,
    'LOCALE': as_list,
    'GEOIP': as_bool_or_str,
    'GEOIP_DB': str,
    'HUMANIZE': as_bool_or_float,
    'BLOCK_IMAGES': as_bool,
    'BLOCK_WEBRTC': as_bool,
    'BLOCK_WEBGL': as_bool,
    'DISABLE_COOP': as_bool,
    'ENABLE_CACHE': as_bool,
    'MAIN_WORLD_EVAL': as_bool,
    'FF_VERSION': int,
    'WINDOW': as_window,
    'ADDONS': as_list,
    'EXCLUDE_ADDONS': as_addons,
    'FONTS': as_list,
    'CUSTOM_FONTS_ONLY': as_bool,
    'I_KNOW_WHAT_IM_DOING': as_bool,
    'DEBUG': as_bool,
    'ARGS': json.loads,
    'CONFIG': json.loads,
    'FIREFOX_USER_PREFS': json.loads,
}

DEFAULTS: Dict[str, Any] = {
    'host': '0.0.0.0',  # nosec B104 - a container port is only as public as its publish rule
    'port': 4444,
    'ws_path': 'camoufox',
    'headless': True,
}


def proxy_from_env() -> Dict[str, str]:
    server = os.environ.get('CAMOUFOX_PROXY_SERVER')
    if not server:
        return {}
    proxy = {'server': server}
    for key, variable in (
        ('username', 'CAMOUFOX_PROXY_USERNAME'),
        ('password', 'CAMOUFOX_PROXY_PASSWORD'),
        ('bypass', 'CAMOUFOX_PROXY_BYPASS'),
    ):
        value = os.environ.get(variable)
        if value:
            proxy[key] = value
    return {'proxy': proxy}


def missing_addons() -> Dict[str, Any]:
    """Exclude the default addons when the image was built without them.

    Camoufox re-downloads a default addon it cannot find, which needs network
    access and a writable cache at launch -- neither of which a slimmed image
    is meant to rely on. Excluding it up front skips that entirely.
    """
    if ADDONS_DIR.is_dir() and any(ADDONS_DIR.iterdir()):
        return {}
    return {'exclude_addons': list(DefaultAddons)}


def options_from_env() -> Dict[str, Any]:
    options = dict(DEFAULTS)
    options.update(missing_addons())

    for name, parse in PARSERS.items():
        raw = os.environ.get(f'CAMOUFOX_{name}')
        if raw is None or raw == '':
            continue
        try:
            parsed = parse(raw)
        except (ValueError, KeyError, json.JSONDecodeError) as error:
            sys.exit(f'CAMOUFOX_{name}={raw!r} is invalid: {error}')
        # A parser returning None means "leave this option unset".
        if parsed is not None:
            options[name.lower()] = parsed

    options.update(proxy_from_env())

    # Escape hatch for launch options without a dedicated variable, such as
    # webgl_config, screen or fingerprint_preset.
    extra = os.environ.get('CAMOUFOX_OPTIONS')
    if extra:
        try:
            options.update(json.loads(extra))
        except json.JSONDecodeError as error:
            sys.exit(f'CAMOUFOX_OPTIONS is not valid JSON: {error}')

    return options


def main() -> None:
    options = options_from_env()
    redacted = dict(options)
    proxy = redacted.get('proxy')
    if proxy and proxy.get('password'):
        redacted['proxy'] = {**proxy, 'password': '***'}
    print(f'Starting Camoufox server: {redacted}', flush=True)
    launch_server(**options)


if __name__ == '__main__':
    main()
