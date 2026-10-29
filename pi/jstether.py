#!/usr/bin/env python3
"""JohorStudio Tether - Raspberry Pi 5 side.

Sony A7R II (USB, PC Remote) -> Pi 5 -> Mac menu bar app (over WiFi/LAN).

- gphoto2 --capture-tethered downloads every shot into INCOMING.
- Finished JPGs move to PENDING and are sent to the Mac (found via Bonjour).
- After the Mac confirms (SHA-256 checked), the file moves to SENT.
  Only the newest KEEP_SENT files are kept in SENT; older ones are deleted.
- If the Mac is offline, PENDING just waits and is sent when it comes back.
- Optional SSD1306 OLED (I2C 0x3C) shows status.
"""
import hashlib
import json
import logging
import os
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = Path(os.environ.get("JSTETHER_DIR", "/var/lib/jstether"))
INCOMING = BASE / "incoming"
PENDING = BASE / "pending"
SENT = BASE / "sent"
KEEP_SENT = int(os.environ.get("JSTETHER_KEEP", "30"))
MAC_OVERRIDE = os.environ.get("JSTETHER_MAC", "").strip()  # "host:port" to skip Bonjour
SERVICE_TYPE = "_jstether._tcp.local."
JPG_EXT = {".jpg", ".jpeg"}
GPHOTO2 = os.environ.get("JSTETHER_GPHOTO2", "gphoto2")

log = logging.getLogger("jstether")


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.camera = None          # model string or None
        self.macs = {}              # name -> (host, port, seen_ts)
        self.mac_ok = False
        self.mac_name = None
        self.last_file = None
        self.sent_total = 0
        self.error = None
        self.wake = threading.Event()

    def set(self, **kw):
        with self.lock:
            for k, v in kw.items():
                setattr(self, k, v)

    def target(self):
        if MAC_OVERRIDE:
            host, _, port = MAC_OVERRIDE.rpartition(":")
            return ("manual", host, int(port))
        with self.lock:
            if not self.macs:
                return None
            name, (host, port, _) = max(self.macs.items(), key=lambda kv: kv[1][2])
            return (name, host, port)

    def snapshot(self):
        with self.lock:
            return {
                "camera": self.camera,
                "mac_ok": self.mac_ok,
                "mac_name": self.mac_name,
                "last_file": self.last_file,
                "sent_total": self.sent_total,
                "queue": queue_len(),
                "error": self.error,
            }


def queue_len():
    try:
        return sum(1 for p in PENDING.iterdir() if p.is_file())
    except FileNotFoundError:
        return 0


def local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "-"
    finally:
        s.close()


# ---------------------------------------------------------------- camera ----

def detect_camera():
    try:
        out = subprocess.run([GPHOTO2, "--auto-detect"], capture_output=True,
                             text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in out.splitlines():
        if "usb:" in line:
            return line.split("usb:")[0].strip()
    return None


def tether_loop(state):
    """Keep gphoto2 --capture-tethered running while a camera is attached."""
    pattern = str(INCOMING / "%Y%m%d-%H%M%S-%f.%C")
    while True:
        model = detect_camera()
        if not model:
            if state.camera:
                log.info("camera disconnected")
            state.set(camera=None)
            time.sleep(2)
            continue
        log.info("camera found: %s", model)
        state.set(camera=model, error=None)
        release_camera()
        cmd = [GPHOTO2, "--capture-tethered", "--keep", "--force-overwrite",
               "--filename", pattern]
        # gphoto2 writes a temp file in its working directory: never run it from "/"
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, cwd=str(BASE),
                                stderr=subprocess.STDOUT, text=True, bufsize=1)
        for line in proc.stdout:
            line = line.strip()
            if line:
                log.debug("gphoto2: %s", line)
            if "Saving file as" in line:
                state.wake.set()
            elif "*** Error" in line:
                state.set(error=line[:60])
        proc.wait()
        log.warning("gphoto2 exited (%s), retrying", proc.returncode)
        state.set(camera=None)
        # give the camera time to release USB, else "Could not claim the USB device"
        time.sleep(4)


def release_camera():
    """Desktop auto-mounters grab Sony cameras; make sure they let go."""
    for name in ("gvfs-gphoto2-volume-monitor", "gvfsd-gphoto2"):
        subprocess.run(["pkill", "-f", name], capture_output=True)


def collector_loop(state):
    """Move fully-written files from INCOMING to PENDING (JPG only)."""
    sizes = {}
    while True:
        state.wake.wait(0.3)
        state.wake.clear()
        now = time.time()
        for p in list(INCOMING.iterdir()):
            if not p.is_file() or p.name.startswith("."):
                continue
            st = p.stat()
            prev = sizes.get(p)
            sizes[p] = st.st_size
            # done = size unchanged since last check and not touched for 0.4s
            if prev != st.st_size or now - st.st_mtime < 0.4 or st.st_size == 0:
                continue
            sizes.pop(p, None)
            if p.suffix.lower() not in JPG_EXT:
                log.info("ignoring non-JPG %s", p.name)
                p.unlink(missing_ok=True)
                continue
            p.rename(PENDING / p.name)
            log.info("queued %s", p.name)
            state.wake.set()
        sizes = {k: v for k, v in sizes.items() if k.exists()}


# ------------------------------------------------------------------ send ----

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def display_name(stored_name):
    # "20261029-221405-DSC01234.JPG" -> "DSC01234.JPG"
    parts = stored_name.split("-", 2)
    return parts[2] if len(parts) == 3 and parts[0].isdigit() else stored_name


def post(host, port, path, data, headers, timeout):
    url = f"http://{host}:{port}{path}"
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read()


def send_file(path, host, port):
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    q = urllib.parse.urlencode({"name": display_name(path.name)})
    status, body = post(host, port, f"/upload?{q}", data, {
        "Content-Type": "image/jpeg",
        "X-SHA256": digest,
    }, timeout=120)
    if status != 200:
        raise IOError(f"Mac replied {status}: {body[:100]!r}")


def prune_sent():
    files = sorted((p for p in SENT.iterdir() if p.is_file()),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    for old in files[KEEP_SENT:]:
        old.unlink(missing_ok=True)


def sender_loop(state):
    backoff = 1
    while True:
        files = sorted((p for p in PENDING.iterdir() if p.is_file()),
                       key=lambda p: p.name)
        if not files:
            state.wake.wait(0.5)
            continue
        tgt = state.target()
        if not tgt:
            state.set(mac_ok=False)
            time.sleep(1)
            continue
        name, host, port = tgt
        f = files[0]
        try:
            send_file(f, host, port)
        except (OSError, urllib.error.URLError) as e:
            log.warning("send %s to %s failed: %s", f.name, name, e)
            state.set(mac_ok=False, error="Hantar gagal, cuba lagi")
            time.sleep(backoff)
            backoff = min(backoff * 2, 10)
            continue
        backoff = 1
        os.utime(f)  # mtime = sent time, used for "keep newest 30"
        f.rename(SENT / f.name)
        prune_sent()
        with state.lock:
            state.sent_total += 1
            state.last_file = display_name(f.name)
            state.mac_ok = True
            state.mac_name = name
            state.error = None
        log.info("sent %s -> %s", f.name, name)


def heartbeat_loop(state):
    """Tell the Mac app the Pi/camera status every 2 s."""
    host_name = socket.gethostname()
    while True:
        tgt = state.target()
        if tgt:
            name, host, port = tgt
            snap = state.snapshot()
            body = json.dumps({
                "host": host_name,
                "ip": local_ip(),
                "camera": snap["camera"],
                "queue": snap["queue"],
                "sent": snap["sent_total"],
            }).encode()
            try:
                post(host, port, "/status", body,
                     {"Content-Type": "application/json"}, timeout=3)
                state.set(mac_ok=True, mac_name=name)
            except (OSError, urllib.error.URLError):
                state.set(mac_ok=False)
        else:
            state.set(mac_ok=False)
        time.sleep(2)


# ------------------------------------------------------------- discovery ----

def start_discovery(state):
    if MAC_OVERRIDE:
        log.info("using fixed Mac address %s", MAC_OVERRIDE)
        return None
    try:
        from zeroconf import ServiceBrowser, ServiceStateChange, Zeroconf
    except ImportError:
        log.error("python3-zeroconf missing and JSTETHER_MAC not set")
        return None

    zc = Zeroconf()

    def on_change(zeroconf, service_type, name, state_change):
        short = name.replace("." + SERVICE_TYPE, "")
        if state_change is ServiceStateChange.Removed:
            with state.lock:
                state.macs.pop(short, None)
            log.info("Mac gone: %s", short)
            return
        info = zeroconf.get_service_info(service_type, name, timeout=3000)
        if not info:
            return
        addrs = info.parsed_addresses()
        v4 = [a for a in addrs if ":" not in a] or addrs
        if not v4:
            return
        with state.lock:
            state.macs[short] = (v4[0], info.port, time.time())
        log.info("Mac found: %s at %s:%s", short, v4[0], info.port)
        state.wake.set()

    ServiceBrowser(zc, SERVICE_TYPE, handlers=[on_change])
    return zc


# ------------------------------------------------------------------ OLED ----

def oled_loop(state):
    try:
        from luma.core.interface.serial import i2c
        from luma.core.render import canvas
        from luma.oled.device import ssd1306
        device = ssd1306(i2c(port=int(os.environ.get("JSTETHER_I2C_PORT", "1")),
                             address=int(os.environ.get("JSTETHER_OLED_ADDR", "0x3C"), 16)))
    except Exception as e:  # no OLED / library missing: run without it
        log.info("OLED not used: %s", e)
        return
    log.info("OLED ready")
    tick = 0
    while True:
        s = state.snapshot()
        cam = s["camera"] or "TIADA KAMERA"
        cam = cam.replace("Sony ", "")[:18]
        if s["mac_ok"]:
            mac = (s["mac_name"] or "Mac")[:16]
        else:
            mac = "MENCARI MAC" + "." * (tick % 4)
        lines = [
            "JohorStudio Tether",
            f"CAM {cam}",
            f"MAC {mac}",
            f"Q:{s['queue']}  HANTAR:{s['sent_total']}",
            (s["error"] or s["last_file"] or "-")[:21],
            f"IP {local_ip()}",
        ]
        try:
            with canvas(device) as draw:
                for i, text in enumerate(lines):
                    draw.text((0, i * 10 + (1 if i else 0)), text, fill="white")
                draw.line((0, 10, 127, 10), fill="white")
        except OSError as e:
            log.warning("OLED write failed: %s", e)
            time.sleep(5)
        tick += 1
        time.sleep(1)


# ------------------------------------------------------------------ main ----

def main():
    logging.basicConfig(level=os.environ.get("JSTETHER_LOG", "INFO"),
                        format="%(asctime)s %(levelname)s %(message)s")
    for d in (INCOMING, PENDING, SENT):
        d.mkdir(parents=True, exist_ok=True)
    state = State()
    zc = start_discovery(state)  # keep reference alive
    workers = [collector_loop, sender_loop, heartbeat_loop, oled_loop]
    if os.environ.get("JSTETHER_NO_CAMERA") != "1":
        workers.append(tether_loop)
    for fn in workers:
        threading.Thread(target=fn, args=(state,), name=fn.__name__,
                         daemon=True).start()
    log.info("JohorStudio Tether running, data in %s", BASE)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        if zc:
            zc.close()


if __name__ == "__main__":
    main()
