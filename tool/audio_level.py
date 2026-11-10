"""Pull PCMA audio from the local go2rtc RTSP re-stream and measure its level (is it silence?)."""
import math, re, socket, sys, time

URL_PATH = sys.argv[1] if len(sys.argv) > 1 else "rtsp_sub"
SECS = float(sys.argv[2]) if len(sys.argv) > 2 else 6
HOST, PORT = "127.0.0.1", 8554
base = f"rtsp://{HOST}:{PORT}/{URL_PATH}"

def alaw_to_linear(a: int) -> int:
    a ^= 0x55
    t = (a & 0x0F) << 4
    seg = (a & 0x70) >> 4
    if seg == 0:
        t += 8
    elif seg == 1:
        t += 0x108
    else:
        t += 0x108
        t <<= seg - 1
    return t if a & 0x80 else -t

s = socket.create_connection((HOST, PORT), timeout=10)
buf = b""
def request(method, url, cseq, extra=""):
    global buf
    s.sendall(f"{method} {url} RTSP/1.0\r\nCSeq: {cseq}\r\nUser-Agent: camstation-probe\r\n{extra}\r\n".encode())
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

head, sdp = request("DESCRIBE", base + "?audio", 1, "Accept: application/sdp\r\n")
if " 200 " not in head.splitlines()[0]:
    sys.exit("DESCRIBE failed: " + head.splitlines()[0])
audio = sdp.split("m=audio", 1)[1] if "m=audio" in sdp else ""
rtpmap = re.search(r"a=rtpmap:\d+ ([^\r\n]+)", audio)
control = re.search(r"a=control:([^\r\n]+)", audio)
print("audio track:", rtpmap.group(1) if rtpmap else "?", "| control:", control.group(1) if control else "?")
ctl = control.group(1).strip()
setup_url = ctl if ctl.startswith("rtsp://") else base + "/" + ctl
head, _ = request("SETUP", setup_url, 2, "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n")
session = re.search(r"Session:\s*([^;\r\n]+)", head).group(1)
request("PLAY", base + "?audio", 3, f"Session: {session}\r\nRange: npt=0.000-\r\n")

samples = []
codes = {}
t0 = time.time()
s.settimeout(3)
while time.time() - t0 < SECS:
    while len(buf) < 4:
        buf += s.recv(65536)
    if buf[0] != 0x24:  # '$'
        # skip any RTSP text responses
        idx = buf.find(b"$")
        buf = buf[idx:] if idx >= 0 else b""
        continue
    ch, ln = buf[1], int.from_bytes(buf[2:4], "big")
    while len(buf) < 4 + ln:
        buf += s.recv(65536)
    pkt, buf = buf[4:4 + ln], buf[4 + ln:]
    if ch != 0 or len(pkt) < 12:
        continue
    cc = pkt[0] & 0x0F
    off = 12 + 4 * cc
    if pkt[0] & 0x10:  # header extension
        off += 4 + 4 * int.from_bytes(pkt[off + 2:off + 4], "big")
    for b in pkt[off:]:
        codes[b] = codes.get(b, 0) + 1
        samples.append(alaw_to_linear(b))
s.close()

n = len(samples)
if not n:
    sys.exit("no audio samples received")
rms = math.sqrt(sum(x * x for x in samples) / n)
peak = max(abs(x) for x in samples)
dbfs = 20 * math.log10(rms / 32768) if rms > 0 else float("-inf")
pk_dbfs = 20 * math.log10(peak / 32768) if peak > 0 else float("-inf")
# per-0.5s RMS to show variation
win = 4000
lv = []
for i in range(0, n - win + 1, win):
    w = samples[i:i + win]
    r = math.sqrt(sum(x * x for x in w) / win)
    lv.append(round(20 * math.log10(r / 32768), 1) if r > 0 else -99)
top = sorted(codes.items(), key=lambda kv: -kv[1])[:3]
print(f"samples: {n} ({n/8000:.1f}s @8kHz) | distinct A-law codes: {len(codes)} | most common: {[(hex(k), v) for k, v in top]}")
print(f"RMS {dbfs:.1f} dBFS | peak {pk_dbfs:.1f} dBFS")
print("level per 0.5s (dBFS):", lv)
verdict = ("SILENT (constant/near-zero codes: mic disabled or muted)" if len(codes) <= 3 or dbfs < -75
           else "REAL AUDIO (varying signal: live microphone)")
print("verdict:", verdict)
