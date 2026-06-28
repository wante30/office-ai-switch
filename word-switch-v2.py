from __future__ import annotations

import argparse
import base64
import ctypes
import getpass
import io
import json
import os
import re
import secrets as _secrets
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from ctypes import wintypes
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
GATEWAY_DIR = ROOT / "gateway_unified"
ENV_FILE = GATEWAY_DIR / ".env"
PYTHON_EXE = GATEWAY_DIR / ".venv" / "Scripts" / "python.exe"
STATE_DIR = Path(os.environ["USERPROFILE"]) / ".word-switch-v2"
PROFILES_FILE = STATE_DIR / "profiles.json"
SECRETS_FILE = STATE_DIR / "secrets.json"
STATE_FILE = STATE_DIR / "state.json"
BACKUP_DIR = STATE_DIR / "backups"
CLOUDFLARED = Path(os.environ["USERPROFILE"]) / "cloudflared.exe"
CLOUDFLARED_CONFIG = Path(os.environ["USERPROFILE"]) / ".cloudflared" / "config.yml"
TUNNEL_NAME = "word-deepseek"
LOCAL_PORT = 8790
UI_PORT = 8791
PLACEHOLDER_PUBLIC_URL = "https://word.example.com"

SCHEMA_VERSION = 3
WORD_ALIASES = ("opus", "sonnet", "haiku")
DEFAULT_API_FORMAT = "anthropic"


def _read_env_file_value(path: Path, key: str) -> str:
    try:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            if name.strip() == key:
                return value.strip().strip('"').strip("'")
    except OSError:
        return ""
    return ""


def _read_cloudflared_public_url(path: Path) -> str:
    try:
        for raw_line in path.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^\s*(?:-\s*)?hostname:\s*(\S+)\s*$", raw_line)
            if match:
                return f"https://{match.group(1)}"
    except OSError:
        return ""
    return ""


PUBLIC_URL = (
    os.getenv("OFFICE_AI_PUBLIC_URL")
    or os.getenv("WORD_AI_PUBLIC_URL")
    or _read_env_file_value(ENV_FILE, "OFFICE_AI_PUBLIC_URL")
    or _read_env_file_value(ENV_FILE, "WORD_AI_PUBLIC_URL")
    or _read_cloudflared_public_url(CLOUDFLARED_CONFIG)
    or PLACEHOLDER_PUBLIC_URL
).rstrip("/")


# ---------------------------------------------------------------------------
# DPAPI helpers (Windows data protection)
# ---------------------------------------------------------------------------


class DATA_BLOB(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]


crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

crypt32.CryptProtectData.argtypes = [
    ctypes.POINTER(DATA_BLOB),
    wintypes.LPCWSTR,
    ctypes.POINTER(DATA_BLOB),
    ctypes.c_void_p,
    ctypes.c_void_p,
    wintypes.DWORD,
    ctypes.POINTER(DATA_BLOB),
]
crypt32.CryptProtectData.restype = wintypes.BOOL
crypt32.CryptUnprotectData.argtypes = [
    ctypes.POINTER(DATA_BLOB),
    ctypes.POINTER(wintypes.LPWSTR),
    ctypes.POINTER(DATA_BLOB),
    ctypes.c_void_p,
    ctypes.c_void_p,
    wintypes.DWORD,
    ctypes.POINTER(DATA_BLOB),
]
crypt32.CryptUnprotectData.restype = wintypes.BOOL
kernel32.LocalFree.argtypes = [ctypes.c_void_p]
kernel32.LocalFree.restype = ctypes.c_void_p


def protect_secret(plain: str) -> str:
    data = plain.encode("utf-8")
    in_buf = ctypes.create_string_buffer(data)
    in_blob = DATA_BLOB(len(data), ctypes.cast(in_buf, ctypes.POINTER(ctypes.c_char)))
    out_blob = DATA_BLOB()
    ok = crypt32.CryptProtectData(
        ctypes.byref(in_blob), "Word AI Switch v2", None, None, None, 0, ctypes.byref(out_blob)
    )
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        protected = ctypes.string_at(out_blob.pbData, out_blob.cbData)
        return base64.b64encode(protected).decode("ascii")
    finally:
        kernel32.LocalFree(out_blob.pbData)


def unprotect_secret(cipher: str) -> str:
    protected = base64.b64decode(cipher.encode("ascii"))
    in_buf = ctypes.create_string_buffer(protected)
    in_blob = DATA_BLOB(len(protected), ctypes.cast(in_buf, ctypes.POINTER(ctypes.c_char)))
    out_blob = DATA_BLOB()
    ok = crypt32.CryptUnprotectData(ctypes.byref(in_blob), None, None, None, None, 0, ctypes.byref(out_blob))
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        data = ctypes.string_at(out_blob.pbData, out_blob.cbData)
        return data.decode("utf-8")
    finally:
        kernel32.LocalFree(out_blob.pbData)


# ---------------------------------------------------------------------------
# JSON / state helpers
# ---------------------------------------------------------------------------


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def ensure_state_dir() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)


def read_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def write_json(path: Path, value: Any) -> None:
    ensure_state_dir()
    tmp = path.with_name(path.name + f".{os.getpid()}.{uuid.uuid4().hex}.tmp")
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    for _ in range(10):
        try:
            tmp.replace(path)
            return
        except PermissionError:
            time.sleep(0.1)
    tmp.replace(path)


def backup_file(path: Path) -> None:
    if not path.exists():
        return
    ensure_state_dir()
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(path, BACKUP_DIR / f"{path.stem}.{stamp}.bak")


def slugify(value: str) -> str:
    out = []
    for ch in value.lower().strip():
        if ch.isalnum():
            out.append(ch)
        elif ch in ("-", "_", ".", " "):
            out.append("-")
    slug = "".join(out).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug or f"profile-{_secrets.token_hex(3)}"


def mask_key(value: str) -> str:
    if not value:
        return ""
    if len(value) <= 10:
        return value[:2] + "***" + value[-2:]
    return value[:5] + "..." + value[-4:]


# ---------------------------------------------------------------------------
# Built-in ProviderPreset catalogue
# ---------------------------------------------------------------------------


def builtin_presets() -> list[dict[str, Any]]:
    return [
        {
            "id": "deepseek",
            "name": "DeepSeek 官方",
            "category": "cn_official",
            "websiteUrl": "https://www.deepseek.com",
            "apiKeyUrl": "https://platform.deepseek.com/api_keys",
            "defaultBaseUrl": "https://api.deepseek.com/anthropic",
            "apiFormat": "anthropic",
            "apiKeyField": "ANTHROPIC_API_KEY",
            "endpointCandidates": ["https://api.deepseek.com/anthropic"],
            "modelsUrl": "https://api.deepseek.com/models",
            "defaultRoutes": {
                "opus": "deepseek-v4-pro",
                "sonnet": "deepseek-v4-flash",
                "haiku": "deepseek-v4-flash",
            },
            "icon": "deepseek",
            "iconColor": "#1E88E5",
        },
        {
            "id": "openrouter",
            "name": "OpenRouter",
            "category": "aggregator",
            "websiteUrl": "https://openrouter.ai",
            "apiKeyUrl": "https://openrouter.ai/keys",
            "defaultBaseUrl": "https://openrouter.ai/api/v1",
            "apiFormat": "openai_chat",
            "apiKeyField": "OPENROUTER_API_KEY",
            "endpointCandidates": ["https://openrouter.ai/api/v1"],
            "modelsUrl": "https://openrouter.ai/api/v1/models",
            "defaultRoutes": {
                "opus": "anthropic/claude-opus-4.5",
                "sonnet": "anthropic/claude-sonnet-4.5",
                "haiku": "anthropic/claude-haiku-4.5",
            },
            "icon": "openrouter",
            "iconColor": "#6366F1",
        },
        {
            "id": "siliconflow",
            "name": "SiliconFlow",
            "category": "aggregator",
            "websiteUrl": "https://siliconflow.cn",
            "apiKeyUrl": "https://cloud.siliconflow.cn/account/ak",
            "defaultBaseUrl": "https://api.siliconflow.cn",
            "apiFormat": "openai_chat",
            "apiKeyField": "SILICONFLOW_API_KEY",
            "endpointCandidates": ["https://api.siliconflow.cn"],
            "modelsUrl": "https://api.siliconflow.cn/v1/models",
            "defaultRoutes": {
                "opus": "deepseek-ai/DeepSeek-V3.1",
                "sonnet": "deepseek-ai/DeepSeek-V3.1",
                "haiku": "Qwen/Qwen2.5-7B-Instruct",
            },
            "icon": "siliconflow",
            "iconColor": "#0EA5E9",
        },
        {
            "id": "aihubmix",
            "name": "AiHubMix",
            "category": "aggregator",
            "websiteUrl": "https://aihubmix.com",
            "apiKeyUrl": "https://aihubmix.com/account",
            "defaultBaseUrl": "https://aihubmix.com",
            "apiFormat": "anthropic",
            "apiKeyField": "AIHUBMIX_API_KEY",
            "endpointCandidates": ["https://aihubmix.com"],
            "modelsUrl": "https://aihubmix.com/v1/models",
            "defaultRoutes": {
                "opus": "claude-opus-4-5",
                "sonnet": "claude-sonnet-4-5",
                "haiku": "claude-haiku-4-5",
            },
            "icon": "aihubmix",
            "iconColor": "#10B981",
        },
        {
            "id": "dmxapi",
            "name": "DMXAPI",
            "category": "aggregator",
            "websiteUrl": "https://www.dmxapi.com",
            "apiKeyUrl": "https://www.dmxapi.com/token",
            "defaultBaseUrl": "https://www.dmxapi.com",
            "apiFormat": "anthropic",
            "apiKeyField": "DMXAPI_API_KEY",
            "endpointCandidates": ["https://www.dmxapi.com"],
            "modelsUrl": "https://www.dmxapi.com/v1/models",
            "defaultRoutes": {
                "opus": "claude-opus-4-5",
                "sonnet": "claude-sonnet-4-5",
                "haiku": "claude-haiku-4-5",
            },
            "icon": "dmxapi",
            "iconColor": "#F59E0B",
        },
        {
            "id": "custom_gateway",
            "name": "自定义网关 / 中转站",
            "category": "custom",
            "websiteUrl": "",
            "apiKeyUrl": "",
            "defaultBaseUrl": "",
            "apiFormat": "anthropic",
            "apiKeyField": "CUSTOM_API_KEY",
            "endpointCandidates": [],
            "modelsUrl": "",
            "defaultRoutes": {"opus": "", "sonnet": "", "haiku": ""},
            "icon": "custom",
            "iconColor": "#64748B",
        },
    ]


def find_preset(preset_id: str) -> dict[str, Any] | None:
    for preset in builtin_presets():
        if preset["id"] == preset_id:
            return preset
    return None


def preset_summaries() -> list[dict[str, Any]]:
    return [
        {
            "id": p["id"],
            "name": p["name"],
            "category": p["category"],
            "defaultBaseUrl": p["defaultBaseUrl"],
            "apiFormat": p["apiFormat"],
            "icon": p["icon"],
            "iconColor": p["iconColor"],
            "websiteUrl": p["websiteUrl"],
            "apiKeyUrl": p["apiKeyUrl"],
        }
        for p in builtin_presets()
    ]


# ---------------------------------------------------------------------------
# Profile schema (v3)
# ---------------------------------------------------------------------------


def empty_routes() -> dict[str, str]:
    return {"opus": "", "sonnet": "", "haiku": ""}


def normalize_profile(raw: dict[str, Any]) -> dict[str, Any]:
    """Coerce any legacy dict into the v3 profile schema."""
    raw = dict(raw or {})

    # Migrate legacy `models` -> `routes`
    routes = dict(raw.get("routes") or {})
    legacy_models = raw.get("models")
    if isinstance(legacy_models, dict):
        for tier in WORD_ALIASES:
            if not routes.get(tier) and legacy_models.get(tier):
                routes[tier] = legacy_models[tier]
    for tier in WORD_ALIASES:
        routes.setdefault(tier, "")
    raw["routes"] = routes

    # Required identity
    raw.setdefault("id", slugify(raw.get("name", "profile")))
    raw.setdefault("name", raw["id"])
    raw.setdefault("presetId", raw.get("presetId") or "custom_gateway")
    raw.setdefault("baseUrl", raw.get("baseUrl") or "")
    raw.setdefault("apiFormat", raw.get("apiFormat") or DEFAULT_API_FORMAT)
    raw.setdefault("notes", raw.get("notes") or "")

    # secretRef is just profile:<id> by convention
    raw.setdefault("secretRef", f"profile:{raw['id']}")

    # keyPreview is regenerated from saved secrets in ensure_defaults/migrate
    raw.setdefault("keyPreview", raw.get("keyPreview") or "")

    # lastTest may be missing
    raw.setdefault("lastTest", None)

    raw.setdefault("createdAt", now_iso())
    raw.setdefault("updatedAt", now_iso())

    # Drop legacy fields we no longer use directly
    raw.pop("models", None)
    raw.pop("authMode", None)

    return raw


def refresh_key_preview(profile: dict[str, Any]) -> dict[str, Any]:
    try:
        value = get_key(profile["id"])
    except Exception:
        value = ""
    profile["keyPreview"] = mask_key(value) if value else ""
    return profile


# ---------------------------------------------------------------------------
# Profile / secret / state IO
# ---------------------------------------------------------------------------


def load_profiles() -> dict[str, Any]:
    ensure_defaults()
    return read_json(PROFILES_FILE, {"version": SCHEMA_VERSION, "profiles": []})


def save_profiles(data: dict[str, Any]) -> None:
    data["version"] = SCHEMA_VERSION
    write_json(PROFILES_FILE, data)


def load_state() -> dict[str, Any]:
    ensure_defaults()
    return read_json(STATE_FILE, {"activeProfileId": None, "updatedAt": now_iso()})


def save_state(data: dict[str, Any]) -> None:
    write_json(STATE_FILE, data)


def load_secrets() -> dict[str, str]:
    ensure_state_dir()
    return read_json(SECRETS_FILE, {})


def save_secrets(data: dict[str, str]) -> None:
    write_json(SECRETS_FILE, data)


def get_key(profile_id: str) -> str:
    cipher = load_secrets().get(profile_id)
    return unprotect_secret(cipher) if cipher else ""


def set_key(profile_id: str, api_key: str) -> None:
    data = load_secrets()
    data[profile_id] = protect_secret(api_key)
    save_secrets(data)


def key_saved(profile_id: str) -> bool:
    return bool(load_secrets().get(profile_id))


def masked_key_for(profile_id: str) -> str:
    try:
        value = get_key(profile_id)
    except Exception:
        return "<unreadable>"
    return mask_key(value)


def find_profile(profile_id: str) -> dict[str, Any] | None:
    for profile in load_profiles().get("profiles", []):
        if profile.get("id") == profile_id:
            return profile
    return None


def require_profile(profile_id: str) -> dict[str, Any]:
    profile = find_profile(profile_id)
    if not profile:
        raise SystemExit(f"Profile not found: {profile_id}")
    return profile


def active_profile() -> dict[str, Any] | None:
    active_id = load_state().get("activeProfileId")
    if not active_id:
        return None
    return find_profile(active_id)


def upsert_profile(profile: dict[str, Any]) -> dict[str, Any]:
    data = load_profiles()
    profiles = data.setdefault("profiles", [])
    profile_id = profile.get("id") or slugify(profile.get("name", "profile"))
    profile["id"] = profile_id
    profile["updatedAt"] = now_iso()
    if not profile.get("createdAt"):
        profile["createdAt"] = now_iso()

    for idx, existing in enumerate(profiles):
        if existing.get("id") == profile_id:
            merged = dict(existing)
            merged.update(profile)
            # Preserve lastTest from existing unless caller overrode it
            if "lastTest" not in profile and existing.get("lastTest"):
                merged["lastTest"] = existing.get("lastTest")
            profiles[idx] = merged
            save_profiles(data)
            return merged

    profiles.append(profile)
    save_profiles(data)
    return profile


def set_last_test(profile_id: str, result: dict[str, Any]) -> dict[str, Any]:
    data = load_profiles()
    for profile in data.get("profiles", []):
        if profile.get("id") == profile_id:
            profile["lastTest"] = result
            save_profiles(data)
            return profile
    raise SystemExit(f"Profile not found: {profile_id}")


# ---------------------------------------------------------------------------
# Default profiles + migration
# ---------------------------------------------------------------------------


def default_profiles() -> list[dict[str, Any]]:
    created = now_iso()
    out: list[dict[str, Any]] = []
    for preset in builtin_presets():
        if preset["id"] == "custom_gateway":
            out.append(
                normalize_profile(
                    {
                        "id": "custom-relay-template",
                        "name": "自定义中转站模板",
                        "presetId": "custom_gateway",
                        "baseUrl": "https://your-relay.example/anthropic",
                        "apiFormat": "anthropic",
                        "routes": {"opus": "your-pro-model", "sonnet": "your-fast-model", "haiku": "your-cheap-model"},
                        "notes": "复制或修改这个 profile，填任意 Anthropic-compatible 中转站。",
                        "createdAt": created,
                        "updatedAt": created,
                    }
                )
            )
            continue
        out.append(
            normalize_profile(
                {
                    "id": preset["id"],
                    "name": preset["name"],
                    "presetId": preset["id"],
                    "baseUrl": preset["defaultBaseUrl"],
                    "apiFormat": preset["apiFormat"],
                    "routes": dict(preset["defaultRoutes"]),
                    "notes": f"内置预设：{preset['name']}。可点击自动配置拉取模型列表后调整。",
                    "createdAt": created,
                    "updatedAt": created,
                }
            )
        )
    return out


def migrate_v2_to_v3(profiles_data: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    """Take a v2 profiles dict and return v3 dict + list of migrated ids."""
    old_profiles = profiles_data.get("profiles") or []
    new_profiles: list[dict[str, Any]] = []
    migrated: list[str] = []
    for raw in old_profiles:
        if not isinstance(raw, dict):
            continue
        profile = normalize_profile(raw)
        # Refresh keyPreview from saved secrets when possible
        try:
            value = get_key(profile["id"])
            if value:
                profile["keyPreview"] = mask_key(value)
                migrated.append(profile["id"])
        except Exception:
            pass
        new_profiles.append(profile)
    return {"version": SCHEMA_VERSION, "profiles": new_profiles}, migrated


def ensure_defaults() -> None:
    ensure_state_dir()
    needs_v3_migration = False
    if PROFILES_FILE.exists():
        data = read_json(PROFILES_FILE, {})
        version = data.get("version") if isinstance(data, dict) else None
        if version != SCHEMA_VERSION:
            needs_v3_migration = True
    else:
        write_json(PROFILES_FILE, {"version": SCHEMA_VERSION, "profiles": default_profiles()})

    if needs_v3_migration:
        backup_file(PROFILES_FILE)
        old_data = read_json(PROFILES_FILE, {"version": 2, "profiles": []})
        new_data, _migrated = migrate_v2_to_v3(old_data)
        write_json(PROFILES_FILE, new_data)

    if not STATE_FILE.exists():
        write_json(STATE_FILE, {"activeProfileId": "deepseek", "updatedAt": now_iso()})
    if not SECRETS_FILE.exists():
        write_json(SECRETS_FILE, {})

    # Always refresh key previews on init so UI is honest about Key state
    data = read_json(PROFILES_FILE, {"version": SCHEMA_VERSION, "profiles": []})
    changed = False
    for profile in data.get("profiles", []):
        if not isinstance(profile, dict):
            continue
        normalize_profile_in_place(profile)
        preview = masked_key_for(profile.get("id", ""))
        if profile.get("keyPreview") != preview:
            profile["keyPreview"] = preview
            changed = True
    if changed:
        write_json(PROFILES_FILE, data)


def normalize_profile_in_place(profile: dict[str, Any]) -> None:
    """Normalize fields without losing data (used for in-place refresh)."""
    routes = dict(profile.get("routes") or {})
    legacy = profile.get("models")
    if isinstance(legacy, dict):
        for tier in WORD_ALIASES:
            if not routes.get(tier) and legacy.get(tier):
                routes[tier] = legacy[tier]
    for tier in WORD_ALIASES:
        routes.setdefault(tier, "")
    profile["routes"] = routes
    profile.setdefault("apiFormat", DEFAULT_API_FORMAT)
    profile.setdefault("presetId", "custom_gateway")
    profile.setdefault("secretRef", f"profile:{profile.get('id', '')}")
    profile.setdefault("lastTest", None)
    profile.pop("models", None)
    profile.pop("authMode", None)


# ---------------------------------------------------------------------------
# .env handling for the gateway
# ---------------------------------------------------------------------------


def read_dotenv() -> list[str]:
    if not ENV_FILE.exists():
        return []
    return ENV_FILE.read_text(encoding="utf-8").splitlines()


def read_dotenv_value(key: str) -> str:
    for line in read_dotenv():
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].strip()
    return ""


def write_dotenv_updates(updates: dict[str, str]) -> None:
    ENV_FILE.parent.mkdir(parents=True, exist_ok=True)
    lines = read_dotenv()
    found = set()
    for i, line in enumerate(lines):
        for key, value in updates.items():
            if line.startswith(f"{key}="):
                lines[i] = f"{key}={value}"
                found.add(key)
    for key, value in updates.items():
        if key not in found:
            lines.append(f"{key}={value}")
    tmp = ENV_FILE.with_suffix(".env.v2.tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    tmp.replace(ENV_FILE)


# ---------------------------------------------------------------------------
# Process management (gateway + cloudflared)
# ---------------------------------------------------------------------------


def _powershell_lines(script: str) -> list[str]:
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def gateway_pids() -> list[str]:
    escaped = str(GATEWAY_DIR).replace("\\", "\\\\")
    script = (
        "Get-CimInstance Win32_Process | Where-Object { "
        f"$_.CommandLine -match '{escaped}' -and "
        "$_.CommandLine -match '(claude-gateway|uvicorn)' -and "
        f"$_.CommandLine -match '\\b{LOCAL_PORT}\\b' "
        "} | ForEach-Object { $_.ProcessId }"
    )
    return _powershell_lines(script)


def tunnel_pids() -> list[str]:
    script = (
        "Get-CimInstance Win32_Process -Filter \"Name='cloudflared.exe'\" | "
        f"Where-Object {{ $_.CommandLine -match 'tunnel' -and $_.CommandLine -match 'run\\s+{TUNNEL_NAME}' }} | "
        "ForEach-Object { $_.ProcessId }"
    )
    return _powershell_lines(script)


def stop_gateway() -> None:
    for pid in gateway_pids():
        subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", f"Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    time.sleep(0.7)


def restart_gateway(profile: dict[str, Any]) -> dict[str, Any]:
    stop_gateway()
    if not PYTHON_EXE.exists():
        raise SystemExit(f"Gateway Python not found: {PYTHON_EXE}")
    env = os.environ.copy()
    env["ACTIVE_PROVIDER"] = "generic"
    env["GENERIC_BASE_URL"] = profile.get("baseUrl", "").rstrip("/")
    env["GENERIC_API_KEY"] = get_key(profile["id"])
    routes = profile.get("routes", {})
    env["MODEL_PRIMARY"] = routes.get("opus", "")
    env["MODEL_MID"] = routes.get("sonnet", "")
    env["MODEL_FAST"] = routes.get("haiku", "")
    subprocess.Popen(
        [
            str(PYTHON_EXE),
            "-m",
            "uvicorn",
            "claude_gateway.main:app",
            "--host",
            "127.0.0.1",
            "--port",
            str(LOCAL_PORT),
            "--no-use-colors",
        ],
        cwd=str(GATEWAY_DIR),
        env=env,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    for _ in range(30):
        time.sleep(0.5)
        if local_health().get("ok"):
            return {"ok": True}
    raise SystemExit("Gateway did not become healthy on port 8790")


def start_tunnel() -> dict[str, Any]:
    if tunnel_pids():
        return {"ok": True, "skipped": "already_running"}
    if not CLOUDFLARED.exists():
        return {"ok": False, "error": f"cloudflared.exe not found: {CLOUDFLARED}"}
    if not CLOUDFLARED_CONFIG.exists():
        return {"ok": False, "error": f"cloudflared config not found: {CLOUDFLARED_CONFIG}"}
    subprocess.Popen(
        [
            str(CLOUDFLARED),
            "tunnel",
            "--protocol",
            "http2",
            "--config",
            str(CLOUDFLARED_CONFIG),
            "run",
            TUNNEL_NAME,
        ],
        cwd=str(Path(os.environ["USERPROFILE"])),
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    time.sleep(5)
    return {"ok": True}


def apply_profile(profile_id: str) -> dict[str, Any]:
    """Persist profile into .env, set active, and restart gateway + tunnel."""
    profile = require_profile(profile_id)
    if not key_saved(profile_id):
        raise SystemExit(f"API key is not saved for profile: {profile_id}")
    routes = profile.get("routes", {})
    write_dotenv_updates(
        {
            "ACTIVE_PROVIDER": "generic",
            "GENERIC_BASE_URL": profile.get("baseUrl", "").rstrip("/"),
            "GENERIC_API_KEY": get_key(profile_id),
            "MODEL_PRIMARY": routes.get("opus", ""),
            "MODEL_MID": routes.get("sonnet", ""),
            "MODEL_FAST": routes.get("haiku", ""),
        }
    )
    save_state({"activeProfileId": profile_id, "updatedAt": now_iso()})
    gw = restart_gateway(profile)
    cf = start_tunnel()
    return {"ok": True, "profile": profile, "gateway": gw, "tunnel": cf}


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------


def request_json(
    url: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 12,
) -> dict[str, Any]:
    payload = None
    req_headers = {
        "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Word-AI-Switch/3.0",
        **(headers or {}),
    }
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        req_headers = {"content-type": "application/json", **req_headers}
    req = urllib.request.Request(url, data=payload, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return {
                "ok": True,
                "status": resp.status,
                "data": json.loads(raw) if raw else None,
            }
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        return {"ok": False, "status": exc.code, "error": raw[:1000]}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}


def local_health() -> dict[str, Any]:
    return request_json(f"http://127.0.0.1:{LOCAL_PORT}/healthz", timeout=4)


def public_health() -> dict[str, Any]:
    return request_json(f"{PUBLIC_URL}/healthz", timeout=10)


# ---------------------------------------------------------------------------
# Base URL / model discovery
# ---------------------------------------------------------------------------


def normalize_base_url(base_url: str) -> str:
    return (base_url or "").strip().rstrip("/")


def messages_url_from_base(base_url: str) -> str:
    base = normalize_base_url(base_url)
    lower = base.lower()
    if lower.endswith("/v1/messages") or lower.endswith("/messages"):
        return base
    if lower.endswith("/v1"):
        return f"{base}/messages"
    return f"{base}/v1/messages"


def model_endpoint_candidates(base_url: str) -> list[str]:
    base = normalize_base_url(base_url)
    lower = base.lower()
    candidates: list[str] = []
    if lower.endswith("/v1/messages"):
        candidates.append(re.sub(r"/messages$", "/models", base, flags=re.IGNORECASE))
    elif lower.endswith("/messages"):
        candidates.append(re.sub(r"/messages$", "/models", base, flags=re.IGNORECASE))
    elif lower.endswith("/v1"):
        candidates.append(f"{base}/models")
    else:
        candidates.append(f"{base}/v1/models")
        candidates.append(f"{base}/models")

    if lower.endswith("/anthropic"):
        root = base[: -len("/anthropic")]
        candidates.append(f"{root}/v1/models")
        candidates.append(f"{root}/models")

    deduped: list[str] = []
    for item in candidates:
        if item and item not in deduped:
            deduped.append(item)
    return deduped


def extract_model_ids(payload: Any) -> list[str]:
    if not isinstance(payload, dict):
        return []
    data = payload.get("data")
    if not isinstance(data, list):
        data = payload.get("models")
    if not isinstance(data, list):
        return []
    ids: list[str] = []
    for item in data:
        if isinstance(item, str):
            ids.append(item)
        elif isinstance(item, dict):
            value = item.get("id") or item.get("name") or item.get("model")
            if value:
                ids.append(str(value))
    return sorted(set(ids), key=str.lower)


def fetch_models(base_url: str, api_key: str) -> dict[str, Any]:
    headers = {
        "Authorization": f"Bearer {api_key}",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    attempts: list[dict[str, Any]] = []
    for url in model_endpoint_candidates(base_url):
        result = request_json(url, headers=headers, timeout=20)
        ids = extract_model_ids(result.get("data")) if result.get("ok") else []
        attempts.append(
            {
                "url": url,
                "ok": result.get("ok", False),
                "status": result.get("status"),
                "models": ids[:200],
                "error": result.get("error"),
            }
        )
        if ids:
            return {"ok": True, "url": url, "models": ids, "attempts": attempts}
    return {"ok": False, "models": [], "attempts": attempts}


def score_model(model_id: str, tier: str) -> int:
    value = model_id.lower()
    score = 0
    if tier == "opus":
        patterns = [
            (r"opus", 100), (r"pro", 80), (r"max", 70), (r"v4-pro", 90),
            (r"k2\.6", 75), (r"m2\.7", 75), (r"deepseek-r1", 65),
            (r"deepseek-v3", 60), (r"gpt-4\.1", 55), (r"gemini-2\.5-pro", 70),
        ]
    elif tier == "sonnet":
        patterns = [
            (r"sonnet", 100), (r"flash", 85), (r"v4-flash", 95),
            (r"k2\.5", 80), (r"m2\.5", 75), (r"chat", 50),
            (r"deepseek-v3", 65), (r"deepseek-chat", 70), (r"qwen.*plus", 55),
        ]
    else:
        patterns = [
            (r"haiku", 100), (r"mini", 75), (r"lite", 70), (r"cheap", 65),
            (r"fast", 60), (r"flash", 55), (r"7b", 45), (r"8b", 45),
        ]
    for pattern, points in patterns:
        if re.search(pattern, value):
            score += points
    if any(bad in value for bad in ["embedding", "rerank", "moderation", "tts", "whisper", "image"]):
        score -= 1000
    return score


def choose_model(models: list[str], tier: str, fallback: str = "") -> str:
    if not models:
        return fallback
    ranked = sorted(models, key=lambda item: (score_model(item, tier), -len(item)), reverse=True)
    best = ranked[0]
    if score_model(best, tier) <= 0 and fallback:
        return fallback
    return best


def suggest_mapping(base_url: str, models: list[str], existing: dict[str, str] | None = None) -> dict[str, str]:
    existing = existing or {}
    base = base_url.lower()
    defaults = {
        "opus": existing.get("opus", ""),
        "sonnet": existing.get("sonnet", ""),
        "haiku": existing.get("haiku", ""),
    }
    if "deepseek" in base:
        defaults.update({"opus": "deepseek-v4-pro", "sonnet": "deepseek-v4-flash", "haiku": "deepseek-v4-flash"})
    first = models[0] if models else ""
    return {
        "opus": choose_model(models, "opus", defaults["opus"] or first),
        "sonnet": choose_model(models, "sonnet", defaults["sonnet"] or first),
        "haiku": choose_model(models, "haiku", defaults["haiku"] or defaults["sonnet"] or first),
    }


def auto_configure_profile(profile_id: str, api_key: str | None = None) -> dict[str, Any]:
    profile = require_profile(profile_id)
    key = api_key or get_key(profile_id)
    if not key:
        return {
            "ok": False,
            "error": "未保存 API Key，无法自动配置。请先点\"保存 Key\"。",
            "howToFix": "在右侧详情里填入 API Key 并点\"保存 Key\"，再点\"自动配置\"。",
        }
    if api_key:
        set_key(profile_id, api_key)
        profile["keyPreview"] = mask_key(api_key)
    fetched = fetch_models(profile.get("baseUrl", ""), key)
    if fetched.get("ok"):
        profile["routes"] = suggest_mapping(profile.get("baseUrl", ""), fetched["models"], profile.get("routes", {}))
        profile["updatedAt"] = now_iso()
        upsert_profile(profile)
    return {"ok": bool(fetched.get("ok")), "profile": profile, "fetch": fetched}


# ---------------------------------------------------------------------------
# Test logic (rewritten per design §8)
# ---------------------------------------------------------------------------


def test_selected_profile(profile_id: str) -> dict[str, Any]:
    """Hit the upstream directly with the selected profile's Key + routes.sonnet.

    This does NOT apply the profile to the gateway. Tests must reflect the
    selected profile, not the active one.
    """
    profile = require_profile(profile_id)
    if not key_saved(profile_id):
        result = {
            "status": "failed",
            "profileId": profile_id,
            "profileName": profile.get("name", ""),
            "baseUrl": profile.get("baseUrl", ""),
            "apiFormat": profile.get("apiFormat", DEFAULT_API_FORMAT),
            "wordAlias": "sonnet",
            "upstreamModel": (profile.get("routes") or {}).get("sonnet", ""),
            "message": "未保存 API Key，无法测试上游鉴权。",
            "howToFix": "在右侧详情里填入 API Key 并点\"保存 Key\"。",
            "checkedAt": now_iso(),
        }
        set_last_test(profile_id, result)
        return result

    api_key = get_key(profile_id)
    base_url = profile.get("baseUrl", "")
    routes = profile.get("routes") or {}
    upstream_model = routes.get("sonnet", "")
    if not upstream_model:
        result = {
            "status": "failed",
            "profileId": profile_id,
            "profileName": profile.get("name", ""),
            "baseUrl": base_url,
            "apiFormat": profile.get("apiFormat", DEFAULT_API_FORMAT),
            "wordAlias": "sonnet",
            "upstreamModel": "",
            "message": "Word sonnet 还没有映射到任何上游模型。",
            "howToFix": "请填写 sonnet 对应的上游模型，或点击\"自动配置\"。",
            "checkedAt": now_iso(),
        }
        set_last_test(profile_id, result)
        return result

    url = messages_url_from_base(base_url)
    headers = {
        "x-api-key": api_key,
        "Authorization": f"Bearer {api_key}",
        "anthropic-version": "2023-06-01",
    }
    body = {
        "model": upstream_model,
        "max_tokens": 8,
        "messages": [{"role": "user", "content": "ping"}],
    }
    started = time.time()
    result = request_json(url, method="POST", body=body, headers=headers, timeout=60)
    latency = int((time.time() - started) * 1000)

    if result.get("ok"):
        data = result.get("data") or {}
        text = ""
        for block in data.get("content", []):
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
        out = {
            "status": "passed",
            "profileId": profile_id,
            "profileName": profile.get("name", ""),
            "baseUrl": base_url,
            "apiFormat": profile.get("apiFormat", DEFAULT_API_FORMAT),
            "wordAlias": "sonnet",
            "upstreamModel": upstream_model,
            "returnedModel": data.get("model"),
            "responseText": text,
            "latencyMs": latency,
            "checkedAt": now_iso(),
            "target": "selected-profile",
        }
        set_last_test(profile_id, out)
        return out

    err = result.get("error") or ""
    status_code = result.get("status")
    if status_code == 401:
        message = "401 Unauthorized: API Key 无效或被上游拒绝。"
        how_to = "去对应厂商后台重新生成 Key，更新到本工具后再次测试。"
    elif status_code == 404:
        message = "404 Not Found: 模型名或 Messages 端点不存在。"
        how_to = "确认 baseUrl 是否带 /anthropic，或点击\"自动配置\"重新拉模型列表。"
    elif status_code in (400, 422):
        message = f"{status_code} 上游拒绝请求：{err[:200]}"
        how_to = "检查模型名是否拼写正确，或换一个 baseUrl。"
    elif "timeout" in err.lower() or "timed out" in err.lower():
        message = "请求超时，上游未在 60s 内返回。"
        how_to = "确认网络可访问上游；可能是上游限流，稍后再试。"
    elif "connection" in err.lower() or "resolve" in err.lower() or "getaddrinfo" in err.lower():
        message = f"无法连接到上游：{err[:200]}"
        how_to = "确认 Base URL 拼写正确、网络可达，且本地没有代理拦截。"
    else:
        message = f"{status_code or '请求失败'}: {err[:200]}"
        how_to = "查看技术详情中的原始错误信息。"

    out = {
        "status": "failed",
        "profileId": profile_id,
        "profileName": profile.get("name", ""),
        "baseUrl": base_url,
        "apiFormat": profile.get("apiFormat", DEFAULT_API_FORMAT),
        "wordAlias": "sonnet",
        "upstreamModel": upstream_model,
        "httpStatus": status_code,
        "message": message,
        "howToFix": how_to,
        "rawError": err[:500],
        "latencyMs": latency,
        "checkedAt": now_iso(),
        "target": "selected-profile",
    }
    set_last_test(profile_id, out)
    return out


def test_public_entry() -> dict[str, Any]:
    """Hit the public Cloudflare entry. Used only when user clicks the button."""
    health = public_health()
    messages_url = f"{PUBLIC_URL}/v1/messages"
    token = read_dotenv_value("GATEWAY_ACCESS_TOKEN")
    headers = {"anthropic-version": "2023-06-01"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
        headers["x-api-key"] = token
    active = active_profile()
    if not active:
        return {
            "status": "failed",
            "message": "没有 active profile，公网测试无意义。",
            "howToFix": "先点\"应用到 Word 网关\"让某个 profile 生效。",
            "health": health,
        }
    routes = active.get("routes") or {}
    body = {
        "model": "sonnet",
        "max_tokens": 8,
        "messages": [{"role": "user", "content": "ping"}],
    }
    started = time.time()
    result = request_json(messages_url, method="POST", body=body, headers=headers, timeout=60)
    latency = int((time.time() - started) * 1000)
    if result.get("ok"):
        data = result.get("data") or {}
        text = ""
        for block in data.get("content", []):
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text", "")
        return {
            "status": "passed",
            "publicUrl": PUBLIC_URL,
            "health": health,
            "activeProfileId": active.get("id"),
            "activeProfileName": active.get("name"),
            "wordAlias": "sonnet",
            "upstreamModel": data.get("model") or routes.get("sonnet", ""),
            "responseText": text,
            "latencyMs": latency,
            "checkedAt": now_iso(),
            "target": "public-word-entry",
        }
    err = result.get("error") or ""
    return {
        "status": "failed",
        "publicUrl": PUBLIC_URL,
        "health": health,
        "activeProfileId": active.get("id"),
        "activeProfileName": active.get("name"),
        "httpStatus": result.get("status"),
        "message": f"公网入口请求失败：{err[:200]}",
        "howToFix": "检查 Cloudflare Tunnel 是否在运行、本机网关是否健康、active profile 是否已应用。",
        "rawError": err[:500],
        "latencyMs": latency,
        "checkedAt": now_iso(),
        "target": "public-word-entry",
    }


# ---------------------------------------------------------------------------
# Status payload (UI must be fast and not touch public network)
# ---------------------------------------------------------------------------


def status_payload(fast: bool = True) -> dict[str, Any]:
    profiles_data = load_profiles()
    profiles = profiles_data.get("profiles", [])
    active = active_profile()
    active_id = active.get("id") if active else None
    gw_pids = gateway_pids()
    cf_pids = tunnel_pids()

    if fast:
        local = {"ok": bool(gw_pids), "skipped": True}
        public = {"ok": None, "skipped": True, "message": "未测试（点\"测试公网入口\"触发）"}
    else:
        local = local_health()
        public = public_health()

    return {
        "schemaVersion": SCHEMA_VERSION,
        "activeProfileId": active_id,
        "activeProfileName": active.get("name") if active else None,
        "activeProfile": (
            {
                "id": active.get("id"),
                "name": active.get("name"),
                "baseUrl": active.get("baseUrl"),
                "apiFormat": active.get("apiFormat"),
                "routes": active.get("routes", {}),
                "keyPreview": active.get("keyPreview", ""),
                "keySaved": key_saved(active.get("id", "")) if active else False,
            }
            if active
            else None
        ),
        "profiles": [
            {
                **p,
                "apiKeySaved": key_saved(p.get("id", "")),
                "apiKeyMasked": masked_key_for(p.get("id", "")),
                "active": p.get("id") == active_id,
            }
            for p in profiles
        ],
        "presets": preset_summaries(),
        "gateway": {
            "running": bool(gw_pids),
            "pids": gw_pids,
            "localUrl": f"http://127.0.0.1:{LOCAL_PORT}",
            "health": local,
        },
        "tunnel": {
            "running": bool(cf_pids),
            "pids": cf_pids,
            "publicHealth": public,
        },
        "publicUrl": PUBLIC_URL,
        "localUrl": f"http://127.0.0.1:{LOCAL_PORT}",
    }


def print_status() -> None:
    payload = status_payload(fast=True)
    print(f"ACTIVE NOW : {payload['activeProfileName']} ({payload['activeProfileId']})")
    print(f"Gateway    : {'running' if payload['gateway']['running'] else 'stopped'} {payload['gateway']['pids']}")
    print(f"Tunnel     : {'running' if payload['tunnel']['running'] else 'stopped'} {payload['tunnel']['pids']}")
    print(f"Public     : {PUBLIC_URL} (未测试)")
    active = payload.get("activeProfile")
    if active:
        routes = active.get("routes", {})
        print(f"Base URL   : {active.get('baseUrl')}")
        print(f"API key    : {'saved ' + active.get('keyPreview', '') if active.get('keySaved') else 'missing'}")
        print(f"API format : {active.get('apiFormat')}")
        print(f"Word opus  -> {routes.get('opus')}")
        print(f"Word sonnet-> {routes.get('sonnet')}")
        print(f"Word haiku -> {routes.get('haiku')}")


# ---------------------------------------------------------------------------
# CLI command implementations
# ---------------------------------------------------------------------------


def cmd_init(_: argparse.Namespace) -> None:
    ensure_defaults()
    print(json.dumps({"ok": True, "stateDir": str(STATE_DIR)}, ensure_ascii=False, indent=2))


def cmd_profile_list(args: argparse.Namespace) -> None:
    payload = status_payload(fast=True)
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return
    active_id = payload.get("activeProfileId")
    for p in payload.get("profiles", []):
        marker = "*" if p.get("id") == active_id else " "
        key_str = p.get("apiKeyMasked") or "missing key"
        routes = p.get("routes", {})
        print(
            f"{marker} {p.get('id', ''):<24} {key_str:<16} {p.get('name', '')}  "
            f"{p.get('baseUrl', '')}  sonnet->{routes.get('sonnet', '')}"
        )


def cmd_profile_get(args: argparse.Namespace) -> None:
    profile = require_profile(args.id)
    out = dict(profile)
    out["apiKeySaved"] = key_saved(args.id)
    out["apiKeyMasked"] = masked_key_for(args.id)
    print(json.dumps(out, ensure_ascii=False, indent=2))


def _read_json_input(args: argparse.Namespace) -> dict[str, Any]:
    """Read profile JSON from --json file, --stdin, or built-in defaults."""
    raw = ""
    if args.json:
        path = Path(args.json)
        if not path.exists():
            raise SystemExit(f"JSON file not found: {path}")
        raw = path.read_text(encoding="utf-8")
    elif args.stdin:
        raw = sys.stdin.read()
    else:
        raise SystemExit("Provide --json FILE or --stdin")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"Invalid JSON: {exc}")
    if not isinstance(data, dict):
        raise SystemExit("JSON must be an object")
    return data


def cmd_profile_save(args: argparse.Namespace) -> None:
    data = _read_json_input(args)
    if not data.get("name"):
        raise SystemExit("保存失败：name 字段为空。\n怎么修：在 JSON 里加 \"name\" 字段。")
    if not data.get("baseUrl"):
        raise SystemExit("保存失败：baseUrl 字段为空。\n怎么修：在 JSON 里加 \"baseUrl\" 字段。")
    profile = normalize_profile(
        {
            "id": data.get("id"),
            "name": data.get("name"),
            "presetId": data.get("presetId", "custom_gateway"),
            "baseUrl": data.get("baseUrl", "").rstrip("/"),
            "apiFormat": data.get("apiFormat", DEFAULT_API_FORMAT),
            "routes": data.get("routes") or data.get("models") or empty_routes(),
            "notes": data.get("notes", ""),
        }
    )
    saved = upsert_profile(profile)
    refresh_key_preview(saved)
    # Persist the refreshed preview
    data_lock = load_profiles()
    for p in data_lock.get("profiles", []):
        if p.get("id") == saved["id"]:
            p["keyPreview"] = saved["keyPreview"]
            save_profiles(data_lock)
            break
    print(json.dumps({"ok": True, "profile": saved}, ensure_ascii=False, indent=2))


def cmd_profile_auto_configure(args: argparse.Namespace) -> None:
    api_key = sys.stdin.read().strip() if args.stdin else None
    if api_key == "":
        api_key = None
    result = auto_configure_profile(args.id, api_key=api_key)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if not result.get("ok"):
        raise SystemExit(1)


def cmd_profile_test(args: argparse.Namespace) -> None:
    result = test_selected_profile(args.id)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if result.get("status") != "passed":
        raise SystemExit(1)


def cmd_profile_delete(args: argparse.Namespace) -> None:
    profile = require_profile(args.id)
    state = load_state()
    if state.get("activeProfileId") == args.id:
        raise SystemExit(
            f"删除失败：profile '{args.id}' 是当前活动配置。\n"
            f"怎么修：先应用其他配置，再删除此 profile。"
        )
    data = load_profiles()
    before = len(data.get("profiles", []))
    data["profiles"] = [p for p in data.get("profiles", []) if p.get("id") != args.id]
    after = len(data["profiles"])
    if after == before:
        raise SystemExit(f"删除失败：未找到 profile '{args.id}'。")
    save_profiles(data)
    # 清理对应的 secret
    secrets = load_secrets()
    removed_key = secrets.pop(args.id, None)
    if removed_key is not None:
        save_secrets(secrets)
    print(json.dumps({
        "ok": True,
        "deletedId": args.id,
        "deletedName": profile.get("name", ""),
        "secretRemoved": removed_key is not None,
    }, ensure_ascii=False, indent=2))


def cmd_profile_export_manifest(args: argparse.Namespace) -> None:
    """根据指定 profile 生成 Office 插件 manifest.xml。"""
    profile = require_profile(args.id)
    token = read_dotenv_value("GATEWAY_ACCESS_TOKEN")
    if not token:
        token = _secrets.token_urlsafe(32)
        write_dotenv_updates({"GATEWAY_ACCESS_TOKEN": token})

    gateway_url = args.url
    if not gateway_url:
        gateway_url = PUBLIC_URL if PUBLIC_URL != PLACEHOLDER_PUBLIC_URL else f"http://127.0.0.1:{LOCAL_PORT}"
    api_format = profile.get("apiFormat", "anthropic") or "anthropic"

    template_path = ROOT / "word-deepseek-manifest.example.xml"
    if not template_path.exists():
        raise SystemExit(f"Manifest 模板不存在：{template_path}")

    manifest = template_path.read_text(encoding="utf-8")
    new_id = str(uuid.uuid4())
    manifest = re.sub(r"<Id>[^<]*</Id>", f"<Id>{new_id}</Id>", manifest)

    encoded_url = urllib.parse.quote(gateway_url, safe="")
    manifest = re.sub(r"gateway_url=[^&\"]*", f"gateway_url={encoded_url}", manifest)
    manifest = re.sub(r"gateway_token=[^&\"]*", f"gateway_token={token}", manifest)
    manifest = re.sub(r"gateway_api_format=[^&\"]*", f"gateway_api_format={api_format}", manifest)

    output_path = Path(args.output) if args.output else Path.cwd() / f"word-deepseek-manifest-{profile['id']}.xml"
    output_path.write_text(manifest, encoding="utf-8")
    print(json.dumps({
        "ok": True,
        "path": str(output_path.resolve()),
        "gatewayUrl": gateway_url,
        "apiFormat": api_format,
    }, ensure_ascii=False, indent=2))


def cmd_secret_save(args: argparse.Namespace) -> None:
    profile = require_profile(args.id)
    if args.stdin:
        api_key = sys.stdin.read().strip()
    else:
        api_key = getpass.getpass(f"API key for {profile.get('name', args.id)}: ").strip()
    if not api_key:
        raise SystemExit("API key 不能为空")
    set_key(args.id, api_key)
    preview = mask_key(api_key)
    # Persist preview onto the profile
    data = load_profiles()
    for p in data.get("profiles", []):
        if p.get("id") == args.id:
            p["keyPreview"] = preview
            save_profiles(data)
            break
    print(json.dumps({"ok": True, "id": args.id, "apiKeySaved": True, "keyPreview": preview}, ensure_ascii=False, indent=2))


def cmd_secret_status(args: argparse.Namespace) -> None:
    profile = require_profile(args.id)
    print(json.dumps(
        {
            "ok": True,
            "id": args.id,
            "apiKeySaved": key_saved(args.id),
            "keyPreview": masked_key_for(args.id),
        },
        ensure_ascii=False,
        indent=2,
    ))


def cmd_gateway_apply(args: argparse.Namespace) -> None:
    result = apply_profile(args.id)
    out = {
        "ok": True,
        "activeProfileId": result["profile"]["id"],
        "activeProfileName": result["profile"]["name"],
        "gateway": result["gateway"],
        "tunnel": result["tunnel"],
    }
    print(json.dumps(out, ensure_ascii=False, indent=2))


def cmd_gateway_status(args: argparse.Namespace) -> None:
    payload = status_payload(fast=args.fast)
    if args.local:
        payload.pop("tunnel", None)
    print(json.dumps(payload, ensure_ascii=False, indent=2))


def cmd_gateway_test_public(_: argparse.Namespace) -> None:
    result = test_public_entry()
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if result.get("status") != "passed":
        raise SystemExit(1)


def cmd_gateway_start(_: argparse.Namespace) -> None:
    active = active_profile()
    started = {"gateway": None, "tunnel": None}
    if active and key_saved(active["id"]):
        started["gateway"] = restart_gateway(active)
    started["tunnel"] = start_tunnel()
    print(json.dumps({"ok": True, "started": started, "status": status_payload(fast=True)}, ensure_ascii=False, indent=2))


def cmd_fetch_models(args: argparse.Namespace) -> None:
    profile = require_profile(args.id)
    api_key = sys.stdin.read().strip() if args.stdin else get_key(args.id)
    if not api_key:
        raise SystemExit("API key is required. Save a key first or pass --stdin.")
    print(json.dumps(fetch_models(profile.get("baseUrl", ""), api_key), ensure_ascii=False, indent=2))


def cmd_migrate_v1(_: argparse.Namespace) -> None:
    v1_dir = Path(os.environ["USERPROFILE"]) / ".word-switch"
    v1_profiles_path = v1_dir / "profiles.json"
    v1_secrets_path = v1_dir / "secrets.json"
    v1_profiles = read_json(v1_profiles_path, {})
    v1_secrets = read_json(v1_secrets_path, {})
    migrated: list[str] = []

    mapping = {
        "deepseek": {
            "id": "deepseek",
            "name": "DeepSeek 官方",
            "presetId": "deepseek",
            "baseUrl": "https://api.deepseek.com/anthropic",
            "apiFormat": "anthropic",
            "routes": {"opus": "deepseek-v4-pro", "sonnet": "deepseek-v4-flash", "haiku": "deepseek-v4-flash"},
        },
        "mimo": {
            "id": "mimo",
            "name": "MiMo",
            "presetId": "custom_gateway",
            "baseUrl": "https://api.xiaomimimo.com/anthropic",
            "apiFormat": "anthropic",
            "routes": {"opus": "mimo-v2.5-pro", "sonnet": "mimo-v2.5", "haiku": "mimo-v2.5"},
        },
        "kimi": {
            "id": "kimi",
            "name": "Kimi",
            "presetId": "custom_gateway",
            "baseUrl": "https://api.moonshot.cn/anthropic",
            "apiFormat": "anthropic",
            "routes": {"opus": "kimi-k2.6", "sonnet": "kimi-k2.5", "haiku": "kimi-k2.5"},
        },
        "minimax": {
            "id": "minimax",
            "name": "MiniMax",
            "presetId": "custom_gateway",
            "baseUrl": "https://api.minimaxi.com/anthropic",
            "apiFormat": "anthropic",
            "routes": {"opus": "MiniMax-M2.7", "sonnet": "MiniMax-M2.5", "haiku": "MiniMax-M2.5-highspeed"},
        },
    }

    for old_id, template in mapping.items():
        override = v1_profiles.get(old_id, {}) if isinstance(v1_profiles, dict) else {}
        routes = dict(template["routes"])
        if override.get("opusModel"):
            routes["opus"] = override["opusModel"]
        if override.get("sonnetModel"):
            routes["sonnet"] = override["sonnetModel"]
        if override.get("haikuModel"):
            routes["haiku"] = override["haikuModel"]
        profile = normalize_profile(
            {
                "id": template["id"],
                "name": template["name"],
                "presetId": template["presetId"],
                "baseUrl": override.get("baseUrl") or template["baseUrl"],
                "apiFormat": template["apiFormat"],
                "routes": routes,
                "notes": "Migrated from Word AI Switch v1.",
            }
        )
        upsert_profile(profile)
        cipher = v1_secrets.get(old_id) if isinstance(v1_secrets, dict) else None
        if cipher:
            try:
                plain = unprotect_secret(cipher)
                set_key(profile["id"], plain)
                profile["keyPreview"] = mask_key(plain)
                upsert_profile(profile)
                migrated.append(profile["id"])
            except Exception:
                pass

    print(json.dumps({"ok": True, "migratedKeys": migrated, "profilesPath": str(PROFILES_FILE)}, ensure_ascii=False, indent=2))


def cmd_preset_list(_: argparse.Namespace) -> None:
    print(json.dumps({"presets": builtin_presets()}, ensure_ascii=False, indent=2))


# ---------------------------------------------------------------------------
# Embedded HTML UI (kept for `ui` command, but the desktop GUI is the primary UI)
# ---------------------------------------------------------------------------


def html_page() -> str:
    return r"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Word AI Switch v2</title>
  <style>
    body{margin:0;background:#0f172a;color:#e2e8f0;font-family:Segoe UI,Microsoft YaHei,sans-serif}
    .app{display:grid;grid-template-columns:340px 1fr;min-height:100vh}
    aside{background:#111827;border-right:1px solid #263244;padding:22px}
    main{padding:28px;display:flex;flex-direction:column;gap:16px}
    h1{font-size:22px;margin:0 0 6px}.muted{color:#94a3b8;font-size:13px}
    .profile{padding:12px;border:1px solid #334155;border-radius:12px;margin:10px 0;cursor:pointer;background:#182033}
    .profile.active{border-color:#38bdf8;background:#0c2b3f}
    .profile .row{display:flex;gap:8px;align-items:center;margin-top:4px}
    .badge{font-size:11px;padding:2px 7px;border-radius:999px;background:#334155}
    .ok{background:#166534}.warn{background:#92400e}.bad{background:#991b1b}
    .grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}.card{background:#111827;border:1px solid #263244;border-radius:16px;padding:18px}
    label{display:block;font-size:13px;color:#94a3b8;margin:12px 0 5px}
    input,textarea,select{width:100%;box-sizing:border-box;border:1px solid #334155;border-radius:10px;background:#0b1220;color:#e2e8f0;padding:10px;font-size:14px}
    button{border:0;border-radius:10px;background:#2563eb;color:white;padding:10px 14px;margin:10px 8px 0 0;cursor:pointer;font-weight:600}
    button.secondary{background:#475569}button.good{background:#059669}button.danger{background:#b91c1c}button.warn{background:#b45309}
    pre{white-space:pre-wrap;background:#020617;border:1px solid #1e293b;border-radius:12px;padding:14px;max-height:240px;overflow:auto}
    .kv{line-height:1.8}.big{font-size:18px;font-weight:700;color:#7dd3fc}
    .statusbar{position:fixed;bottom:0;left:0;right:0;background:#020617;border-top:1px solid #1e293b;padding:8px 18px;font-size:12px;color:#94a3b8}
  </style>
</head>
<body>
<div class="app">
  <aside>
    <h1>Word AI Switch v2</h1>
    <div class="muted">任意 Anthropic-compatible API profile 管理器</div>
    <button onclick="newProfile()" class="good">新建配置</button>
    <button onclick="refresh()" class="secondary">刷新</button>
    <div id="profiles"></div>
  </aside>
  <main>
    <section class="card">
      <div class="muted">当前实际生效</div>
      <div id="active" class="big">Loading...</div>
      <div id="health" class="kv"></div>
      <div>
        <button onclick="startServices()" class="good">启动/修复 Gateway + Tunnel</button>
        <button onclick="migrateV1()" class="secondary">迁移 v1 配置</button>
        <button onclick="testPublic()" class="warn">测试公网入口</button>
      </div>
    </section>
    <section class="card">
      <h2>配置详情</h2>
      <input id="id" type="hidden" />
      <div class="grid">
        <div><label>名称</label><input id="name" /></div>
        <div><label>预设来源</label><select id="presetId"></select></div>
      </div>
      <label>Base URL</label><input id="baseUrl" placeholder="https://your-relay.example/anthropic" />
      <label>API 格式</label><select id="apiFormat">
        <option value="anthropic">anthropic</option>
        <option value="openai_chat">openai_chat (尚未启用)</option>
        <option value="openai_responses">openai_responses (尚未启用)</option>
        <option value="gemini_native">gemini_native (尚未启用)</option>
      </select>
      <div class="grid">
        <div><label>Word opus -&gt;</label><input id="opus" /></div>
        <div><label>Word sonnet -&gt;</label><input id="sonnet" /></div>
      </div>
      <label>Word haiku -&gt;</label><input id="haiku" />
      <label>API Key（留空不覆盖）</label><input id="apiKey" type="password" />
      <label>Key 状态</label><div id="keyState" class="muted">未保存</div>
      <label>备注</label><textarea id="notes" rows="3"></textarea>
      <div>
        <button onclick="saveProfile()" class="good">保存配置</button>
        <button onclick="saveKey()" class="secondary">保存 Key</button>
        <button onclick="autoConfigure()">自动配置</button>
        <button onclick="testSelected()" class="good">测试选中配置</button>
        <button onclick="applyProfile()" class="danger">应用到 Word 网关</button>
      </div>
    </section>
    <section class="card">
      <div class="muted">最近一次测试 / 日志</div>
      <pre id="log">Ready.</pre>
    </section>
  </main>
</div>
<div class="statusbar" id="statusbar">本地网关：未知 | 公网入口：未测试 | 当前启用：-</div>
<script>
let state=null, selected=null;
const $=id=>document.getElementById(id);
function log(x){ $('log').textContent=typeof x==='string'?x:JSON.stringify(x,null,2); }
async function api(path, opts={}) {
  const res=await fetch(path,{headers:{'content-type':'application/json'},...opts});
  const data=await res.json();
  if(!res.ok) throw data;
  return data;
}
async function refresh(){
  state=await api('/api/status'); render();
}
function render(){
  const presetSel=$('presetId'); presetSel.innerHTML='';
  (state.presets||[]).forEach(p=>{const o=document.createElement('option'); o.value=p.id; o.textContent=p.name; presetSel.appendChild(o);});
  const active=state.activeProfile||{};
  $('active').textContent=(state.activeProfileName||'未应用')+' ('+(state.activeProfileId||'-')+')';
  $('health').innerHTML=
    `Gateway: ${state.gateway.running?'running':'stopped'}<br>`+
    `Tunnel: ${state.tunnel.running?'running':'stopped'}<br>`+
    `Public: ${state.publicUrl} (未测试)<br>`+
    `API 格式: ${active.apiFormat||'-'}<br>`+
    `Word sonnet -> ${active.routes?active.routes.sonnet:'-'}`;
  $('profiles').innerHTML='';
  state.profiles.forEach(p=>{
    const div=document.createElement('div');
    div.className='profile '+(p.active?'active':'');
    div.onclick=()=>selectProfile(p.id);
    const keyBadge=p.apiKeySaved?`<span class="badge ok">Key: ${p.apiKeyMasked}</span>`:`<span class="badge warn">Key 未保存</span>`;
    const activeBadge=p.active?`<span class="badge ok">已启用</span>`:'';
    div.innerHTML=`<b>${p.name}</b><br><span class="muted">${p.id}</span><div class="row">${keyBadge} ${activeBadge}</div><span class="muted">sonnet -> ${p.routes?p.routes.sonnet:'-'}</span>`;
    $('profiles').appendChild(div);
  });
  const statusBar=`本地网关：${state.gateway.running?'运行中':'已停止'} | 公网入口：未测试 | 当前启用：${state.activeProfileName||'-'}`;
  $('statusbar').textContent=statusBar;
  if(!selected && state.profiles[0]) selectProfile(state.activeProfileId||state.profiles[0].id);
}
function selectProfile(id){
  selected=state.profiles.find(p=>p.id===id); if(!selected) return;
  $('id').value=selected.id; $('name').value=selected.name; $('baseUrl').value=selected.baseUrl;
  $('presetId').value=selected.presetId||'custom_gateway';
  $('apiFormat').value=selected.apiFormat||'anthropic';
  $('opus').value=selected.routes?selected.routes.opus:''; $('sonnet').value=selected.routes?selected.routes.sonnet:''; $('haiku').value=selected.routes?selected.routes.haiku:'';
  $('apiKey').value=''; $('notes').value=selected.notes||'';
  $('keyState').textContent=selected.apiKeySaved?`已保存 ${selected.apiKeyMasked}`:'未保存';
  if(selected.lastTest){ log(selected.lastTest); }
}
function payload(){
  return {id:$('id').value||undefined,name:$('name').value,baseUrl:$('baseUrl').value,
    presetId:$('presetId').value,apiFormat:$('apiFormat').value,
    routes:{opus:$('opus').value,sonnet:$('sonnet').value,haiku:$('haiku').value},notes:$('notes').value};
}
function newProfile(){ selected=null; ['id','name','baseUrl','opus','sonnet','haiku','apiKey','notes'].forEach(i=>$(i).value=''); $('name').focus(); }
async function saveProfile(){
  try{
    const r=await fetch('/api/profile',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(payload())});
    const data=await r.json(); if(!r.ok) throw data; log(data); await refresh(); selectProfile(data.profile.id);
  }catch(e){log(e)}
}
async function saveKey(){
  try{
    const id=$('id').value; if(!id) throw {error:'先保存 profile'};
    const key=$('apiKey').value; if(!key) throw {error:'API Key 不能为空'};
    const r=await fetch('/api/key',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id,key})});
    const data=await r.json(); if(!r.ok) throw data; $('apiKey').value=''; log(data); await refresh();
  }catch(e){log(e)}
}
async function autoConfigure(){
  try{
    const id=$('id').value; if(!id) throw {error:'先保存 profile'};
    const body={id}; if($('apiKey').value){ body.key=$('apiKey').value; }
    const r=await fetch('/api/auto-configure',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body)});
    const data=await r.json(); if(!r.ok) throw data; $('apiKey').value=''; log(data); await refresh(); selectProfile(id);
  }catch(e){log(e)}
}
async function applyProfile(){
  try{
    const id=$('id').value; if(!id) throw {error:'先保存 profile'};
    const r=await fetch('/api/use',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id})});
    const data=await r.json(); if(!r.ok) throw data; log(data); await refresh();
  }catch(e){log(e)}
}
async function testSelected(){
  try{
    const id=$('id').value; if(!id) throw {error:'先保存 profile'};
    const r=await fetch('/api/test-selected',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({id})});
    const data=await r.json(); if(!r.ok) throw data; log(data); await refresh(); selectProfile(id);
  }catch(e){log(e)}
}
async function testPublic(){
  try{ log('Testing public...'); const r=await fetch('/api/test-public',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({})}); const data=await r.json(); log(data); }catch(e){log(e)}
}
async function startServices(){ try{log(await api('/api/start',{method:'POST'})); await refresh();}catch(e){log(e)} }
async function migrateV1(){ try{log(await api('/api/migrate-v1',{method:'POST'})); await refresh();}catch(e){log(e)} }
refresh().catch(log);
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    def _json(self, value: Any, status: int = 200) -> None:
        raw = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length", "0"))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def log_message(self, fmt: str, *args: Any) -> None:
        return

    def do_GET(self) -> None:
        if self.path == "/":
            raw = html_page().encode("utf-8")
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
            return
        if self.path == "/api/status":
            self._json(status_payload(fast=True))
            return
        if self.path == "/api/presets":
            self._json({"presets": builtin_presets()})
            return
        self._json({"error": "not found"}, 404)

    def do_POST(self) -> None:
        try:
            body = self._body()
            if self.path == "/api/profile":
                if not body.get("name"):
                    self._json({"ok": False, "error": "保存失败：name 为空。", "howToFix": "在表单里填写名称。"}, 400)
                    return
                if not body.get("baseUrl"):
                    self._json({"ok": False, "error": "保存失败：baseUrl 为空。", "howToFix": "在表单里填写 Base URL。"}, 400)
                    return
                profile = normalize_profile(
                    {
                        "id": body.get("id") or slugify(body.get("name", "profile")),
                        "name": body.get("name", "").strip(),
                        "presetId": body.get("presetId", "custom_gateway"),
                        "baseUrl": body.get("baseUrl", "").strip().rstrip("/"),
                        "apiFormat": body.get("apiFormat", DEFAULT_API_FORMAT),
                        "routes": body.get("routes") or empty_routes(),
                        "notes": body.get("notes", ""),
                    }
                )
                saved = upsert_profile(profile)
                refresh_key_preview(saved)
                data_lock = load_profiles()
                for p in data_lock.get("profiles", []):
                    if p.get("id") == saved["id"]:
                        p["keyPreview"] = saved["keyPreview"]
                        save_profiles(data_lock)
                        break
                self._json({"ok": True, "profile": saved})
                return
            if self.path == "/api/key":
                if not body.get("id") or not body.get("key"):
                    self._json({"ok": False, "error": "id 和 key 都不能为空"}, 400)
                    return
                set_key(body["id"], body["key"])
                preview = mask_key(body["key"])
                data = load_profiles()
                for p in data.get("profiles", []):
                    if p.get("id") == body["id"]:
                        p["keyPreview"] = preview
                        save_profiles(data)
                        break
                self._json({"ok": True, "id": body["id"], "apiKeySaved": True, "keyPreview": preview})
                return
            if self.path == "/api/auto-configure":
                self._json(auto_configure_profile(body["id"], api_key=body.get("key") or None))
                return
            if self.path == "/api/use":
                profile = apply_profile(body["id"])
                self._json({"ok": True, "activeProfileId": profile["id"], "activeProfileName": profile["name"]})
                return
            if self.path == "/api/test-selected":
                self._json(test_selected_profile(body["id"]))
                return
            if self.path == "/api/test-public":
                self._json(test_public_entry())
                return
            if self.path == "/api/start":
                cmd_gateway_start(argparse.Namespace())
                self._json({"ok": True, "status": status_payload(fast=True)})
                return
            if self.path == "/api/migrate-v1":
                self._json(cmd_migrate_v1_result())
                return
            self._json({"error": "not found"}, 404)
        except SystemExit as exc:
            self._json({"ok": False, "error": str(exc)}, 400)
        except Exception as exc:
            self._json({"ok": False, "error": str(exc)}, 500)


def cmd_migrate_v1_result() -> dict[str, Any]:
    v1_dir = Path(os.environ["USERPROFILE"]) / ".word-switch"
    v1_profiles_path = v1_dir / "profiles.json"
    v1_secrets_path = v1_dir / "secrets.json"
    v1_profiles = read_json(v1_profiles_path, {})
    v1_secrets = read_json(v1_secrets_path, {})
    migrated: list[str] = []
    mapping = {
        "deepseek": {"id": "deepseek", "name": "DeepSeek 官方", "presetId": "deepseek",
                     "baseUrl": "https://api.deepseek.com/anthropic", "apiFormat": "anthropic",
                     "routes": {"opus": "deepseek-v4-pro", "sonnet": "deepseek-v4-flash", "haiku": "deepseek-v4-flash"}},
        "mimo": {"id": "mimo", "name": "MiMo", "presetId": "custom_gateway",
                 "baseUrl": "https://api.xiaomimimo.com/anthropic", "apiFormat": "anthropic",
                 "routes": {"opus": "mimo-v2.5-pro", "sonnet": "mimo-v2.5", "haiku": "mimo-v2.5"}},
        "kimi": {"id": "kimi", "name": "Kimi", "presetId": "custom_gateway",
                 "baseUrl": "https://api.moonshot.cn/anthropic", "apiFormat": "anthropic",
                 "routes": {"opus": "kimi-k2.6", "sonnet": "kimi-k2.5", "haiku": "kimi-k2.5"}},
        "minimax": {"id": "minimax", "name": "MiniMax", "presetId": "custom_gateway",
                    "baseUrl": "https://api.minimaxi.com/anthropic", "apiFormat": "anthropic",
                    "routes": {"opus": "MiniMax-M2.7", "sonnet": "MiniMax-M2.5", "haiku": "MiniMax-M2.5-highspeed"}},
    }
    for old_id, template in mapping.items():
        override = v1_profiles.get(old_id, {}) if isinstance(v1_profiles, dict) else {}
        routes = dict(template["routes"])
        if override.get("opusModel"):
            routes["opus"] = override["opusModel"]
        if override.get("sonnetModel"):
            routes["sonnet"] = override["sonnetModel"]
        if override.get("haikuModel"):
            routes["haiku"] = override["haikuModel"]
        profile = normalize_profile(
            {
                "id": template["id"],
                "name": template["name"],
                "presetId": template["presetId"],
                "baseUrl": override.get("baseUrl") or template["baseUrl"],
                "apiFormat": template["apiFormat"],
                "routes": routes,
                "notes": "Migrated from Word AI Switch v1.",
            }
        )
        upsert_profile(profile)
        cipher = v1_secrets.get(old_id) if isinstance(v1_secrets, dict) else None
        if cipher:
            try:
                plain = unprotect_secret(cipher)
                set_key(profile["id"], plain)
                profile["keyPreview"] = mask_key(plain)
                upsert_profile(profile)
                migrated.append(profile["id"])
            except Exception:
                pass
    return {"ok": True, "migratedKeys": migrated, "profilesPath": str(PROFILES_FILE)}


def cmd_ui(args: argparse.Namespace) -> None:
    ensure_defaults()
    port = args.port
    url = f"http://127.0.0.1:{port}"
    print(f"Word AI Switch v2 UI: {url}")
    subprocess.Popen(["cmd.exe", "/c", "start", "", url], shell=False)
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


# ---------------------------------------------------------------------------
# CLI parser (new command groups per design §10, plus legacy aliases)
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Word AI Switch v2 (schema v3)")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init").set_defaults(func=cmd_init)

    # --- profile group ---
    profile = sub.add_parser("profile")
    profile_sub = profile.add_subparsers(dest="profile_command", required=True)

    p_list = profile_sub.add_parser("list")
    p_list.add_argument("--json", action="store_true")
    p_list.set_defaults(func=cmd_profile_list)

    p_get = profile_sub.add_parser("get")
    p_get.add_argument("id")
    p_get.set_defaults(func=cmd_profile_get)

    p_save = profile_sub.add_parser("save")
    p_save.add_argument("--json", help="JSON file with profile fields")
    p_save.add_argument("--stdin", action="store_true", help="Read profile JSON from stdin")
    p_save.set_defaults(func=cmd_profile_save)

    p_auto = profile_sub.add_parser("auto-configure")
    p_auto.add_argument("id")
    p_auto.add_argument("--stdin", action="store_true")
    p_auto.set_defaults(func=cmd_profile_auto_configure)

    p_test = profile_sub.add_parser("test")
    p_test.add_argument("id")
    p_test.set_defaults(func=cmd_profile_test)

    p_delete = profile_sub.add_parser("delete")
    p_delete.add_argument("id")
    p_delete.set_defaults(func=cmd_profile_delete)

    p_export = profile_sub.add_parser("export-manifest")
    p_export.add_argument("id")
    p_export.add_argument("--url", help="Gateway URL（默认：公网入口或本地 http://127.0.0.1:8790）")
    p_export.add_argument("--output", "-o", help="输出 XML 路径（默认：当前目录 word-deepseek-manifest-<id>.xml）")
    p_export.set_defaults(func=cmd_profile_export_manifest)

    # --- secret group ---
    secret = sub.add_parser("secret")
    secret_sub = secret.add_subparsers(dest="secret_command", required=True)

    s_save = secret_sub.add_parser("save")
    s_save.add_argument("id")
    s_save.add_argument("--stdin", action="store_true")
    s_save.set_defaults(func=cmd_secret_save)

    s_status = secret_sub.add_parser("status")
    s_status.add_argument("id")
    s_status.set_defaults(func=cmd_secret_status)

    # --- gateway group ---
    gateway = sub.add_parser("gateway")
    gateway_sub = gateway.add_subparsers(dest="gateway_command", required=True)

    g_apply = gateway_sub.add_parser("apply")
    g_apply.add_argument("id")
    g_apply.set_defaults(func=cmd_gateway_apply)

    g_status = gateway_sub.add_parser("status")
    g_status.add_argument("--local", action="store_true", help="omit tunnel/public info")
    g_status.add_argument("--fast", action="store_true", default=True)
    g_status.add_argument("--full", action="store_true", help="also probe local health endpoint")
    g_status.set_defaults(func=cmd_gateway_status)

    gateway_sub.add_parser("test-public").set_defaults(func=cmd_gateway_test_public)
    gateway_sub.add_parser("start").set_defaults(func=cmd_gateway_start)

    # --- presets ---
    sub.add_parser("preset-list").set_defaults(func=cmd_preset_list)

    # --- legacy aliases (kept so old scripts keep working) ---
    sub.add_parser("list").set_defaults(func=lambda args: cmd_profile_list(argparse.Namespace(json=False)))
    sub.add_parser("status").set_defaults(func=lambda args: print_status())

    status_json = sub.add_parser("status-json")
    status_json.add_argument("--fast", action="store_true", default=True)
    status_json.set_defaults(func=lambda args: print(json.dumps(status_payload(fast=args.fast), ensure_ascii=False, indent=2)))

    add = sub.add_parser("add")
    add.add_argument("--id")
    add.add_argument("--name", required=True)
    add.add_argument("--base-url", required=True)
    add.add_argument("--opus", default="")
    add.add_argument("--sonnet", default="")
    add.add_argument("--haiku", default="")
    add.add_argument("--notes")
    add.set_defaults(func=_legacy_cmd_add)

    use = sub.add_parser("use")
    use.add_argument("id")
    use.set_defaults(func=cmd_gateway_apply)

    test = sub.add_parser("test")
    test.add_argument("id", nargs="?")
    test.add_argument("--public", action="store_true")
    test.set_defaults(func=_legacy_cmd_test)

    fetch = sub.add_parser("fetch-models")
    fetch.add_argument("id")
    fetch.add_argument("--stdin", action="store_true")
    fetch.set_defaults(func=cmd_fetch_models)

    sub.add_parser("start").set_defaults(func=cmd_gateway_start)
    sub.add_parser("migrate-v1").set_defaults(func=cmd_migrate_v1)

    ui = sub.add_parser("ui")
    ui.add_argument("--port", type=int, default=UI_PORT)
    ui.set_defaults(func=cmd_ui)

    return parser


def _legacy_cmd_add(args: argparse.Namespace) -> None:
    """Legacy `add` command. Internally goes through the same normalize/upsert path."""
    profile = normalize_profile(
        {
            "id": args.id or slugify(args.name),
            "name": args.name,
            "presetId": "custom_gateway",
            "baseUrl": args.base_url.rstrip("/"),
            "apiFormat": DEFAULT_API_FORMAT,
            "routes": {"opus": args.opus, "sonnet": args.sonnet, "haiku": args.haiku},
            "notes": args.notes or "",
        }
    )
    saved = upsert_profile(profile)
    print(json.dumps({"ok": True, "profile": saved}, ensure_ascii=False, indent=2))


def _legacy_cmd_test(args: argparse.Namespace) -> None:
    if args.public:
        result = test_public_entry()
    else:
        if not args.id:
            active = active_profile()
            if not active:
                raise SystemExit("No active profile")
            args.id = active["id"]
        result = test_selected_profile(args.id)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if result.get("status") != "passed":
        raise SystemExit(1)


def main(argv: list[str] | None = None) -> int:
    ensure_defaults()
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
