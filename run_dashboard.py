"""Start or stop the local Python dashboard from an OS scheduler."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
import venv
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ENV_DIR = ROOT / ".venv"
DATA_DIR = ROOT / ".dashboard_data"
PROCESS_FILE = DATA_DIR / "processes.json"
STOP_REQUESTED = False
CHILDREN = []


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


def write_process_file():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    temporary = PROCESS_FILE.with_suffix(".tmp")
    temporary.write_text(json.dumps({"supervisor": os.getpid(), "children": [p.pid for p in CHILDREN]}), encoding="utf-8")
    temporary.replace(PROCESS_FILE)


def process_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def send_stop(pid, force=False):
    try:
        os.kill(int(pid), signal.SIGKILL if force and os.name != "nt" else signal.SIGTERM)
        return True
    except (OSError, ValueError, TypeError):
        return False


def stop_dashboard():
    try:
        state = json.loads(PROCESS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        print("No scheduled dashboard process was found.")
        return
    children = state.get("children", [])
    if not children:
        print("No dashboard services are recorded as running.")
        return
    for pid in reversed(children):
        send_stop(pid)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline and any(process_alive(pid) for pid in children):
        time.sleep(0.1)
    for pid in reversed(children):
        if process_alive(pid):
            send_stop(pid, force=True)
    try:
        PROCESS_FILE.unlink()
    except FileNotFoundError:
        pass
    print("Dashboard closed.")


def request_stop(_signum, _frame):
    global STOP_REQUESTED
    STOP_REQUESTED = True


def close_children():
    for process in reversed(CHILDREN):
        if process.poll() is None:
            process.terminate()
    for process in reversed(CHILDREN):
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
    try:
        PROCESS_FILE.unlink()
    except FileNotFoundError:
        pass


def start_dashboard(preview=False):
    if sys.version_info < (3, 11):
        raise SystemExit("Python 3.11 or newer is required. Install a current Python release and retry.")
    if preview:
        os.environ["DASHBOARD_TEST_PREVIEW"] = "1"
    python = prepare_environment()
    api_port = os.getenv("API_PORT", "8765")
    app_port = os.getenv("PORT", "8000")
    os.environ["API_PORT"] = api_port
    os.environ["DASHBOARD_API_URL"] = os.getenv("DASHBOARD_API_URL", f"http://127.0.0.1:{api_port}")

    signal.signal(signal.SIGTERM, request_stop)
    if hasattr(signal, "SIGBREAK"):
        signal.signal(signal.SIGBREAK, request_stop)

    backend = subprocess.Popen([str(python), str(ROOT / "server.py")], cwd=ROOT, env=os.environ.copy())
    CHILDREN.append(backend)
    write_process_file()
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not STOP_REQUESTED:
            if backend.poll() is not None:
                raise RuntimeError(f"The Python data service stopped during startup. Check whether port {api_port} is in use.")
            try:
                with socket.create_connection(("127.0.0.1", int(api_port)), timeout=0.25):
                    break
            except OSError:
                time.sleep(0.1)
        else:
            if not STOP_REQUESTED:
                raise RuntimeError(f"The Python data service did not start on port {api_port}.")
            return

        streamlit = subprocess.Popen([str(python), "-m", "streamlit", "run", str(ROOT / "dashboard.py"),
                                      "--server.address", "127.0.0.1", "--server.port", app_port,
                                      "--server.headless", "true"], cwd=ROOT, env=os.environ.copy())
        CHILDREN.append(streamlit)
        write_process_file()
        print(f"Dashboard scheduled process is running at http://127.0.0.1:{app_port}", flush=True)
        while streamlit.poll() is None and not STOP_REQUESTED:
            time.sleep(0.5)
    finally:
        close_children()


def main():
    arguments = set(sys.argv[1:])
    if "--stop" in arguments:
        stop_dashboard()
    else:
        start_dashboard(preview="--preview" in arguments)


if __name__ == "__main__":
    main()
