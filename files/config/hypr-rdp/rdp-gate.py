#!/usr/bin/env python3
"""RDP gate: always listen on the public RDP port; one user at a time, newest login wins.

- Every connection is forwarded to hypr-rdp (which only listens on localhost), and a new
  connection cuts any existing one, so the newest RDP client takes over.
- A successful RDP login locks the desk: hypr-rdp's on_session_start hook (after auth,
  so port scanners can't trigger it) runs on-connect.sh.
- The moment the desk session (seat0) gets unlocked, open RDP connections are cut, and if
  the remote session was used since, the desk is asked whether to log it out.
- If the remote session isn't running (logged out), a new connection starts a fresh one.
"""
import asyncio
import os
import subprocess
import sys

LISTEN = ("0.0.0.0", 3389)
BACKEND = ("127.0.0.1", 3390)  # hypr-rdp's bind in ~/.config/hypr-rdp/config.toml
POLL_SECONDS = 1.0
REMOTE_UNIT = "hyprland-remote.service"
START_TIMEOUT = 25.0
MARKERS = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "rdp-sessions")
ASK = os.path.expanduser("~/.config/hypr-rdp/ask-close-other.sh")
USER = os.environ.get("USER") or subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()

desk_in_use = True  # updated by watch_desk()
open_pipes: set[asyncio.Task] = set()


def log(msg: str) -> None:
    print(msg, flush=True)


async def run(*cmd: str) -> str:
    proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    out, _ = await proc.communicate()
    return out.decode().strip()


def desk_dms(session: str) -> tuple[str, str] | None:
    """(pid, shell path) of the desk's DMS quickshell: the qs whose env has our seat0 session id.
    The remote session's DMS has no XDG_SESSION_ID (run-headless-hyprland.sh unsets it)."""
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            with open(f"/proc/{pid}/comm") as f:
                if f.read().strip() != "qs":
                    continue
            with open(f"/proc/{pid}/environ", "rb") as f:
                if f"XDG_SESSION_ID={session}".encode() not in f.read().split(b"\0"):
                    continue
            with open(f"/proc/{pid}/cmdline", "rb") as f:
                args = f.read().decode().split("\0")
        except OSError:
            continue
        if "-p" in args and "/dms-shell/" in args[args.index("-p") + 1]:
            return pid, args[args.index("-p") + 1]
    return None


async def check_desk() -> tuple[bool, str]:
    """(in_use, description). In use = our seat0 session exists and its DMS lock screen is off.
    Asks the desk's DMS, not logind: the remote session's DMS writes the desk session's
    LockedHint (it has no logind session of its own), so LockedHint=no on a remote unlock."""
    for line in (await run("loginctl", "list-sessions", "--no-legend")).splitlines():
        f = line.split()
        if len(f) >= 4 and f[2] == USER and f[3] == "seat0":
            dms = desk_dms(f[0])
            if dms is None:
                raise RuntimeError(f"no DMS found for desk session {f[0]}")
            locked = await run("qs", "-p", dms[1], "ipc", "--pid", dms[0], "call", "lock", "isLocked")
            if locked not in ("true", "false"):
                raise RuntimeError(f"desk DMS lock state unreadable: {locked!r}")
            return locked == "false", f"desk session {f[0]} {'unlocked' if locked == 'false' else 'locked'}"
    return False, "no desk session"


async def watch_desk() -> None:
    global desk_in_use
    last = None
    last_error = None
    while True:
        try:
            in_use, desc = await check_desk()
        except Exception as e:  # loginctl/DMS hiccup (or DMS still starting): keep the last known state, don't kick
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
            # while the desk was unlocked must survive until its hook has locked the desk.
            if in_use and last is not None and open_pipes:
                log(f"desk unlocked: cutting {len(open_pipes)} RDP connection(s)")
                for t in list(open_pipes):
                    t.cancel()
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


async def backend_connect():
    """Connect to hypr-rdp; if the remote session was logged out, start a fresh one first."""
    try:
        return await asyncio.open_connection(*BACKEND)
    except OSError:
        pass
    if (await run("systemctl", "--user", "is-active", REMOTE_UNIT)) != "active":
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


async def handle(client_r: asyncio.StreamReader, client_w: asyncio.StreamWriter) -> None:
    peer = client_w.get_extra_info("peername")
    try:
        backend_r, backend_w = await backend_connect()
    except OSError as e:
        log(f"refused {peer}: hypr-rdp not reachable ({e})")
        client_w.close()
        return
    if open_pipes:
        log(f"newest connection {peer} takes over: cutting {len(open_pipes)} existing")
        for t in list(open_pipes):
            t.cancel()
    log(f"forwarding {peer}")
    task = asyncio.current_task()
    open_pipes.add(task)
    try:
        await asyncio.gather(pump(client_r, backend_w), pump(backend_r, client_w))
    except (asyncio.CancelledError, ConnectionError):
        pass
    finally:
        open_pipes.discard(task)
        for w in (client_w, backend_w):
            w.close()
        log(f"closed {peer}")


async def main() -> None:
    asyncio.create_task(watch_desk())
    server = await asyncio.start_server(handle, *LISTEN, reuse_address=True)
    log(f"listening on {LISTEN[0]}:{LISTEN[1]} -> {BACKEND[0]}:{BACKEND[1]}")
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
