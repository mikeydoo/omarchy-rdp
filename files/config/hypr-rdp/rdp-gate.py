#!/usr/bin/env python3
"""RDP gate: always listen on the public RDP port; one user at a time, newest login wins.

- Every connection is forwarded to hypr-rdp (which only listens on localhost), and a new
  connection cuts any existing one, so the newest RDP client takes over.
- A successful RDP login locks the desk: hypr-rdp's on_session_start hook (after auth,
  so port scanners can't trigger it) runs on-connect.sh.
- The moment the desk session (seat0) gets unlocked, open RDP connections are cut, and if
  the remote session was used since, the desk is asked whether to log it out.
- If the remote session isn't running (logged out), a new connection starts a fresh one.
- Omarchy's `omarchy restart shell` (after updates, font and language changes) stops the
  Omarchy shell in every session but starts it again only in its own. While both sessions
  run, a session left without its shell for SHELL_GRACE seconds gets it back.
- SIGUSR1 cuts the current connection (the plugin's Disconnect button).
- The connected client's address is kept in $XDG_RUNTIME_DIR/rdp-sessions/client for the
  plugin's status.
"""
import asyncio
import os
import signal
import subprocess
import sys

LISTEN = ("0.0.0.0", 3389)
BACKEND = ("127.0.0.1", 3390)  # hypr-rdp's bind in ~/.config/hypr-rdp/config.toml
POLL_SECONDS = 1.0
REMOTE_UNIT = "hyprland-remote.service"
START_TIMEOUT = 25.0
SHELL_GRACE = 15.0
SHELL_CONFIG = os.path.join(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"), "shell")
MARKERS = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "rdp-sessions")
CLIENT_FILE = os.path.join(MARKERS, "client")
HERE = os.path.expanduser("~/.config/hypr-rdp")
ASK = os.path.join(HERE, "ask-close-other.sh")
HYPR_SESSION = os.path.join(HERE, "hypr-session.sh")
LOGINS = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
                      "omarchy-rdp/logins.tsv")  # login history for the plugin
USER = os.environ.get("USER") or subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()

desk_in_use = True  # updated by watch_desk()
open_pipes: set[asyncio.Task] = set()


def log(msg: str) -> None:
    print(msg, flush=True)


async def run(*cmd: str, env: dict | None = None) -> tuple[int, str]:
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL, env=env)
    out, _ = await proc.communicate()
    return proc.returncode, out.decode().strip()


async def check_desk() -> tuple[bool, str, str]:
    """(in_use, description, session id). In use = our seat0 session exists and its Omarchy lock screen
    is off. Asks the desk's Omarchy shell (through omarchy-shell, pointed at the desk's
    display): Omarchy's lock screen doesn't report to logind (no LockedHint)."""
    _, sessions = await run("loginctl", "list-sessions", "--no-legend")
    for line in sessions.splitlines():
        f = line.split()
        if len(f) >= 4 and f[2] == USER and f[3] == "seat0":
            record_desk_login(f[0])
            rc, desk = await run(HYPR_SESSION, "desk")
            if rc != 0 or not desk:
                raise RuntimeError(f"no Hyprland found for desk session {f[0]}")
            env = dict(os.environ, WAYLAND_DISPLAY=desk.split()[1],
                       OMARCHY_PATH=os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))
            _, locked = await run("omarchy-shell", "lock", "isLocked", env=env)
            if locked not in ("true", "false"):
                raise RuntimeError(f"desk lock state unreadable: {locked!r}")
            return locked == "false", f"desk session {f[0]} {'unlocked' if locked == 'false' else 'locked'}", f[0]
    return False, "no desk session", ""


recorded_desk = ""


def record_desk_login(session_id: str) -> None:
    """Add a desk login to the history, once per console session (also across restarts of
    the gate: the entry carries the session's own start time)."""
    global recorded_desk
    if session_id == recorded_desk:
        return
    recorded_desk = session_id
    try:
        with open(f"/run/systemd/sessions/{session_id}") as f:
            usec = next(l.split("=", 1)[1] for l in f if l.startswith("REALTIME="))
        started = int(usec) // 1_000_000
        lines = open(LOGINS).read().splitlines() if os.path.exists(LOGINS) else []
        entry = f"{started}\tdesk\t"
        if entry in lines:
            return
        lines.append(entry)
        os.makedirs(os.path.dirname(LOGINS), exist_ok=True)
        with open(LOGINS + ".tmp", "w") as f:
            f.write("\n".join(lines[-50:]) + "\n")
        os.replace(LOGINS + ".tmp", LOGINS)
    except (OSError, StopIteration, ValueError) as e:
        log(f"couldn't record desk login ({e})")


def cut_all(reason: str) -> None:
    if open_pipes:
        log(f"{reason}: cutting {len(open_pipes)} RDP connection(s)")
        for t in list(open_pipes):
            t.cancel()


async def watch_desk() -> None:
    global desk_in_use
    last = None
    last_error = None
    while True:
        try:
            in_use, desc, _ = await check_desk()
        except Exception as e:  # loginctl/shell hiccup (or the shell still starting): keep the last known state, don't kick
            if str(e) != last_error:
                log(f"desk check failed ({e})")
                last_error = str(e)
            await asyncio.sleep(POLL_SECONDS)
            continue
        last_error = None
        desk_in_use = in_use
        if in_use != last:
            log(desc)
            # Edge, not level: only the moment of unlocking takes over. A remote login made
            # while the desk was unlocked must survive until its hook has locked the desk,
            # and the desk's auto-login at boot (first state seen) cuts nobody.
            if in_use and last is not None:
                cut_all("desk unlocked")
            if in_use:
                desk_unlocked()
            last = in_use
        await asyncio.sleep(POLL_SECONDS)


def desk_unlocked() -> None:
    """Desk is in use: remember it (asked on the next RDP login) and, if the remote session
    was used since the desk was last unlocked, ask on the desk whether to log it out."""
    os.makedirs(MARKERS, exist_ok=True)
    open(os.path.join(MARKERS, "desk-used"), "a").close()
    remote_used = os.path.join(MARKERS, "remote-used")
    if os.path.exists(remote_used):
        os.remove(remote_used)
        log("desk took over: asking whether to log out the remote session")
        subprocess.Popen([ASK, "remote"], start_new_session=True,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def shell_displays() -> set[str]:
    """WAYLAND_DISPLAY of every running Omarchy shell (quickshell -p <omarchy>/shell)."""
    found = set()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                argv = f.read().split(b"\0")
            if not argv or os.path.basename(argv[0]) != b"quickshell" \
                    or SHELL_CONFIG.encode() not in [a.rstrip(b"/") for a in argv]:
                continue
            with open(f"/proc/{pid}/environ", "rb") as f:
                for kv in f.read().split(b"\0"):
                    if kv.startswith(b"WAYLAND_DISPLAY="):
                        found.add(kv.split(b"=", 1)[1].decode())
        except OSError:
            continue
    return found


async def watch_shells() -> None:
    missing_since: dict[str, float] = {}
    loop = asyncio.get_running_loop()
    while True:
        await asyncio.sleep(5)
        sessions = {}
        for which in ("desk", "remote"):
            rc, out = await run(HYPR_SESSION, which)
            if rc == 0 and len(out.split()) >= 2:
                sessions[which] = out.split()[:2]  # signature, wayland socket
        if len(sessions) < 2:
            missing_since.clear()
            continue
        shells = shell_displays()
        for which, (sig, wl) in sessions.items():
            if wl in shells:
                missing_since.pop(which, None)
                continue
            since = missing_since.setdefault(which, loop.time())
            if loop.time() - since >= SHELL_GRACE:
                log(f"{which} session has no Omarchy shell: starting it")
                await run("hyprctl", "dispatch", 'hl.dsp.exec_cmd("omarchy-launch-shell")',
                          env=dict(os.environ, HYPRLAND_INSTANCE_SIGNATURE=sig))
                missing_since[which] = loop.time() + 30  # give it time to come up


async def backend_connect():
    """Connect to hypr-rdp; if the remote session was logged out, start a fresh one first."""
    try:
        return await asyncio.open_connection(*BACKEND)
    except OSError:
        pass
    if (await run("systemctl", "--user", "is-active", REMOTE_UNIT))[1] != "active":
        log("remote session not running: starting a fresh one")
        await run("systemctl", "--user", "start", REMOTE_UNIT)
    deadline = asyncio.get_running_loop().time() + START_TIMEOUT
    while True:
        try:
            return await asyncio.open_connection(*BACKEND)
        except OSError:
            if asyncio.get_running_loop().time() > deadline:
                raise
            await asyncio.sleep(0.5)


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    finally:
        writer.close()


def set_client(peer) -> None:
    os.makedirs(MARKERS, exist_ok=True)
    tmp = CLIENT_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"{peer[0]}\n" if peer else "")
    os.replace(tmp, CLIENT_FILE)


def clear_client() -> None:
    try:
        os.remove(CLIENT_FILE)
    except FileNotFoundError:
        pass


async def handle(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter) -> None:
    peer = client_w.get_extra_info("peername")
    try:
        backend_r, backend_w = await backend_connect()
    except OSError as e:
        log(f"refused {peer}: hypr-rdp not reachable ({e})")
        client_w.close()
        return
    cut_all(f"newest connection {peer} takes over")
    log(f"forwarding {peer}")
    task = asyncio.current_task()
    open_pipes.add(task)
    set_client(peer)
    try:
        await asyncio.gather(pump(client_r, backend_w), pump(backend_r, client_w))
    except (asyncio.CancelledError, ConnectionError):
        pass
    finally:
        open_pipes.discard(task)
        if not open_pipes:
            clear_client()
        for w in (client_w, backend_w):
            w.close()
        log(f"closed {peer}")


async def main() -> None:
    clear_client()
    loop = asyncio.get_running_loop()
    loop.add_signal_handler(signal.SIGUSR1, cut_all, "disconnect requested")
    asyncio.create_task(watch_desk())
    asyncio.create_task(watch_shells())
    server = await asyncio.start_server(handle, *LISTEN, reuse_address=True)
    log(f"listening on {LISTEN[0]}:{LISTEN[1]} -> {BACKEND[0]}:{BACKEND[1]}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
