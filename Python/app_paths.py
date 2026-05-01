import shutil
import sys
from pathlib import Path

from app_metadata import (
    APP_ASSET_DIR_NAME,
    APP_SUPPORT_DIR_NAME,
    LEGACY_APP_SUPPORT_DIR_NAMES,
)

ASSET_DIR_NAME = APP_ASSET_DIR_NAME
APP_SUPPORT_ROOT = Path.home() / "Library" / "Application Support"
LEGACY_USER_DATA_DIRS = tuple(
    APP_SUPPORT_ROOT / legacy_name for legacy_name in LEGACY_APP_SUPPORT_DIR_NAMES
)


def get_asset_dir() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / ASSET_DIR_NAME
    return Path(__file__).resolve().parent / ASSET_DIR_NAME


ASSET_DIR = get_asset_dir()
USER_DATA_DIR = APP_SUPPORT_ROOT / APP_SUPPORT_DIR_NAME
DB_FILE = USER_DATA_DIR / "archive.db"
TEMP_HTML = USER_DATA_DIR / "Current_View.html"
VIEWER_INDEX_JS = USER_DATA_DIR / "viewer_index.js"
CUSTOM_CSS = USER_DATA_DIR / "custom.css"
THEMES_JSON = USER_DATA_DIR / "themes.json"
HISTORY_FILE = USER_DATA_DIR / "history.json"
CUSTOM_USER_AVATAR = USER_DATA_DIR / "custom_user.png"
CUSTOM_AI_AVATAR = USER_DATA_DIR / "custom_ai.png"


def migrate_legacy_user_data_dir() -> Path:
    if USER_DATA_DIR.exists():
        return USER_DATA_DIR

    USER_DATA_DIR.parent.mkdir(parents=True, exist_ok=True)
    for legacy_dir in LEGACY_USER_DATA_DIRS:
        if not legacy_dir.exists():
            continue
        shutil.move(str(legacy_dir), str(USER_DATA_DIR))
        break
    return USER_DATA_DIR
