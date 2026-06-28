from __future__ import annotations

import ctypes
import shutil
import subprocess
import sys
from pathlib import Path


CREATE_NO_WINDOW = 0x08000000


def show_error(message: str) -> None:
    ctypes.windll.user32.MessageBoxW(None, message, "Office AI Switch", 0x10)


def show_info(message: str) -> None:
    ctypes.windll.user32.MessageBoxW(None, message, "Office AI Switch", 0x40)


def run_checked(args: list[str], cwd: Path) -> None:
    completed = subprocess.run(
        args,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=CREATE_NO_WINDOW,
    )
    if completed.returncode != 0:
        output = completed.stdout.strip()
        if len(output) > 1800:
            output = output[-1800:]
        raise RuntimeError(f"Command failed:\n{' '.join(args)}\n\n{output}")


def find_system_python() -> list[str] | None:
    py_launcher = shutil.which("py")
    if py_launcher:
        return [py_launcher, "-3"]
    python = shutil.which("python")
    if python:
        return [python]
    return None


def ensure_gateway_venv(root: Path) -> None:
    gateway_dir = root / "gateway_unified"
    venv_python = gateway_dir / ".venv" / "Scripts" / "python.exe"
    if venv_python.exists():
        return

    system_python = find_system_python()
    if not system_python:
        raise RuntimeError(
            "Python 3.11+ was not found.\n\n"
            "Install Python from https://www.python.org/downloads/windows/ "
            "and enable 'Add python.exe to PATH', then start OfficeAISwitch.exe again."
        )

    show_info(
        "First run setup: Office AI Switch will create a local Python virtual environment "
        "and install gateway dependencies.\n\nThis may take a few minutes."
    )
    run_checked([*system_python, "-m", "venv", str(gateway_dir / ".venv")], root)
    run_checked([str(venv_python), "-m", "pip", "install", "--upgrade", "pip"], root)
    run_checked([str(venv_python), "-m", "pip", "install", "-e", str(gateway_dir)], root)


def main() -> int:
    root = Path(sys.executable).resolve().parent
    script = root / "word-switch-v2-gui.ps1"
    if not script.exists():
        show_error(f"Missing GUI script:\n{script}")
        return 1

    try:
        ensure_gateway_venv(root)
    except Exception as exc:
        show_error(f"Gateway setup failed:\n{exc}")
        return 1

    powershell = "powershell.exe"
    args = [
        powershell,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-STA",
        "-File",
        str(script),
    ]

    try:
        subprocess.Popen(args, cwd=str(root), close_fds=True)
    except OSError as exc:
        show_error(f"Failed to launch PowerShell GUI:\n{exc}")
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
