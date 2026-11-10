#!/usr/bin/env bash
# A demo camera for testing and screenshots: an SMPTE test pattern with a live
# clock, H.264 in MPEG-TS on a raw TCP socket. Add it in CamStation as a
# "Stream URL" camera: tcp://<this PC's IP>:9100 (from an Android emulator:
# tcp://10.0.2.2:9100). Needs GStreamer (base, good, ugly, bad plugins).
#   tool/demo_camera.sh [port]
set -euo pipefail
PORT="${1:-9100}"
exec gst-launch-1.0 -q \
  videotestsrc is-live=true pattern=smpte \
  ! video/x-raw,width=1280,height=720,framerate=15/1 \
  ! clockoverlay halignment=left valignment=top font-desc="Sans 28" \
      time-format="Demo camera  %Y-%m-%d %H:%M:%S" \
  ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=15 bitrate=1500 \
  ! video/x-h264,profile="${DEMO_PROFILE:-main}" ! h264parse config-interval=-1 ! mpegtsmux \
  ! tcpserversink host=0.0.0.0 port="$PORT" sync-method=latest-keyframe
