import json
import logging
import os
import subprocess
import sys
import time
import urllib.request

logger = logging.getLogger("TabCircle")

REPO = "sniperravan/TabCircle"
API_URL = f"https://api.github.com/repos/{REPO}/releases/latest"
CHECK_INTERVAL = 24 * 3600  # once a day
STATE_FILE = os.path.join(os.path.expanduser("~/.cache/tabcircle"), "update_state.json")
BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def current_version():
    vfile = os.path.join(BASE_DIR, "VERSION")
    try:
        with open(vfile, "r", encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return "0.0.0"


def _version_tuple(v):
    return tuple(int(p) for p in v.split(".") if p.isdigit())


def _should_check_now():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            last = json.load(f).get("last_check", 0)
        return (time.time() - last) >= CHECK_INTERVAL
    except Exception:
        return True


def _record_check_time():
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump({"last_check": time.time()}, f)
    except Exception:
        pass


def _notify(title, body):
    """Best-effort desktop notification; falls back to a log line if notify-send is missing."""
    try:
        subprocess.run(["notify-send", "-i", "dialog-information", title, body], timeout=2)
    except Exception:
        logger.info(f"{title}: {body}")


def check_for_update(force=False):
    if not force and not _should_check_now():
        return
    _record_check_time()
    try:
        req = urllib.request.Request(API_URL, headers={"User-Agent": "TabCircle-Updater"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.load(resp)
        latest = data.get("tag_name", "").lstrip("v")
        current = current_version()
        if latest and _version_tuple(latest) > _version_tuple(current):
            release_url = data.get("html_url", f"https://github.com/{REPO}/releases/latest")
            logger.info(f"Update available: {current} -> {latest} ({release_url})")
            _notify(
                "TabCircle update available",
                f"v{latest} is available (you have v{current}). Download: {release_url}"
            )
        elif force:
            logger.info(f"TabCircle is up to date (v{current}).")
    except Exception as e:
        logger.debug(f"Update check failed (non-fatal): {e}")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
    force = "--force" in sys.argv
    check_for_update(force=force)
