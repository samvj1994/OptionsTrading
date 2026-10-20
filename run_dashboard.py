"""Prepare the small Python environment and run both local app processes."""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time
import venv
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ENV_DIR = ROOT / ".venv"


def environment_python():
    return ENV_DIR / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def prepare_environment():
    python = environment_python()
    if not python.exists():
        print("Creating the dashboard's local Python environment…", flush=True)
        venv.EnvBuilder(with_pip=True).create(ENV_DIR)
    check = subprocess.run([str(python), "-c", "import streamlit"], cwd=ROOT,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if check.returncode:
        print("Installing the dashboard's Python interface package…", flush=True)
        subprocess.run([str(python), "-m", "pip", "install", "-r", str(ROOT / "requirements.txt")],
                       cwd=ROOT, check=True)
    return python


def main():
    if sys.version_info < (3, 11):
        raise SystemExit("Python 3.11 or newer is required for Streamlit. Install a current Python release and retry.")
    if "--preview" in sys.argv[1:]:
        os.environ["DASHBOARD_TEST_PREVIEW"] = "1"
    python = prepare_environment()
    api_port = os.getenv("API_PORT", "8765")
    app_port = os.getenv("PORT", "8000")
    os.environ["API_PORT"] = api_port
    os.environ["DASHBOARD_API_URL"] = os.getenv("DASHBOARD_API_URL", f"http://127.0.0.1:{api_port}")
    backend = subprocess.Popen([str(python), str(ROOT / "server.py")], cwd=ROOT, env=os.environ.copy())
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if backend.poll() is not None:
                raise RuntimeError("The Python data service stopped during startup. Check whether port " + api_port + " is already in use.")
            try:
                with socket.create_connection(("127.0.0.1", int(api_port)), timeout=0.25):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            raise RuntimeError("The Python data service did not start on port " + api_port + ".")
        subprocess.run([str(python), "-m", "streamlit", "run", str(ROOT / "dashboard.py"),
                        "--server.address", "127.0.0.1", "--server.port", app_port,
                        "--server.headless", "true"], cwd=ROOT, env=os.environ.copy(), check=True)
    finally:
        backend.terminate()
        try:
            backend.wait(timeout=5)
        except subprocess.TimeoutExpired:
            backend.kill()
            backend.wait()


if __name__ == "__main__":
    main()
