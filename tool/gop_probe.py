"""Measure H.264/H.265 keyframe timing from a go2rtc loopback RTSP stream.

Reports: time from PLAY to the first keyframe (what a new viewer waits for),
and the interval between keyframes (GOP). Usage:
    python3 -I tool/gop_probe.py rtsp_main 20 [port]
"""
import re, socket, sys, time

path = sys.argv[1]
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 20
port = int(sys.argv[3]) if len(sys.argv) > 3 else 8554
base = f"rtsp://127.0.0.1:{port}/{path}"
s = socket.create_connection(("127.0.0.1", port), timeout=10)
buf = b""

def req(method, url, cseq, extra=""):
    global buf
    s.sendall(f"{method} {url} RTSP/1.0\r\nCSeq: {cseq}\r\n{extra}\r\n".encode())
    while b"\r\n\r\n" not in buf:
        buf += s.recv(65536)
    head, buf = buf.split(b"\r\n\r\n", 1)
    head = head.decode("latin-1")
    m = re.search(r"Content-Length:\s*(\d+)", head, re.I)
    body = b""
    if m:
        n = int(m.group(1))
        while len(buf) < n:
            buf += s.recv(65536)
        body, buf = buf[:n], buf[n:]
    return head, body.decode("latin-1")

t_start = time.time()
_, sdp = req("DESCRIBE", base + "?video", 1, "Accept: application/sdp\r\n")
video = sdp.split("m=video", 1)[1]
codec = re.search(r"a=rtpmap:\d+ ([A-Za-z0-9]+)", video).group(1).upper()
ctl = re.search(r"a=control:([^\r\n]+)", video).group(1).strip()
url = ctl if ctl.startswith("rtsp://") else base + "/" + ctl
head, _ = req("SETUP", url, 2, "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n")
sess = re.search(r"Session:\s*([^;\r\n]+)", head).group(1)
req("PLAY", base + "?video", 3, f"Session: {sess}\r\n")
t_play = time.time()

def is_key(payload: bytes) -> bool:
    if not payload:
        return False
    if codec == "H264":
        t = payload[0] & 0x1F
        if t == 28 and len(payload) > 1:            # FU-A
            return (payload[1] & 0x80) and (payload[1] & 0x1F) == 5
        if t == 24:                                  # STAP-A: SPS/PPS before IDR
            return False
        return t == 5
    # H265
    t = (payload[0] >> 1) & 0x3F
    if t == 49 and len(payload) > 2:                 # FU
        return (payload[2] & 0x80) and 16 <= (payload[2] & 0x3F) <= 21
    return 16 <= t <= 21

keys, frames, bytes_ = [], 0, 0
s.settimeout(3)
while time.time() - t_play < secs:
    while len(buf) < 4:
        buf += s.recv(65536)
    if buf[0] != 0x24:
        i = buf.find(b"$"); buf = buf[i:] if i >= 0 else b""; continue
    ch, ln = buf[1], int.from_bytes(buf[2:4], "big")
    while len(buf) < 4 + ln:
        buf += s.recv(65536)
    pkt, buf = buf[4:4 + ln], buf[4 + ln:]
    if ch != 0 or len(pkt) < 13:
        continue
    bytes_ += len(pkt)
    off = 12 + 4 * (pkt[0] & 0x0F)
    if pkt[1] & 0x80:
        frames += 1                                   # RTP marker = end of frame
    if is_key(pkt[off:]):
        now = time.time() - t_play
        if not keys or now - keys[-1] > 0.2:
            keys.append(now)
s.close()

print(f"{path}: codec {codec}, {frames / secs:.1f} fps, {bytes_ * 8 / secs / 1e6:.2f} Mbit/s")
print(f"  connect→PLAY {t_play - t_start:.2f}s; first keyframe after PLAY: "
      f"{keys[0]:.2f}s" if keys else "  NO KEYFRAME seen")
if len(keys) > 1:
    gaps = [round(b - a, 2) for a, b in zip(keys, keys[1:])]
    print(f"  keyframe gaps (s): {gaps}  → GOP ≈ {sum(gaps) / len(gaps):.1f}s")
