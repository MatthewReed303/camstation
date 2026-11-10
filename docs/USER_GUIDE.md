# CamStation user guide

## Adding a camera

<img src="screenshots/add-camera.webp" width="220" align="right" alt="Add camera">

1. Tap **Add camera**. CamStation scans your network straight away.
2. Tap your camera in the list. If it isn't there:
   - **Camera on a different network?** Enter its network (e.g. `192.168.1.0/24`) or address,
     then **Scan network** again.
   - Or tap **Enter details manually** and type the camera's IP address.
3. Enter the username and password (leave the password empty if the camera has none).
4. Tap **Test**. CamStation tries each way of connecting and shows what each one gives you:
   video, sound and two-way talk. The best one is selected.
5. Give the camera a name and tap **Save**.

Networks of cameras you have added are always included in later scans.

<br clear="right">

## Watching

<img src="screenshots/live-view.webp" width="220" align="right" alt="Live view">

- Tap a camera to open it. **✕** takes you back to the list.
- **HD / SD:** the full-quality stream, or a lighter one (good on mobile data or older phones).
- **Volume:** mute, or set the volume. Camera sound is boosted (see *Boost camera sound* in
  Settings); turn it down if a camera sounds distorted.
- **Snapshot:** saves a picture. On Android it goes to the app's folder; on desktop, to
  Downloads/CamStation.
- **Full screen:** double-tap the video or use the full-screen button. The controls float over
  the picture; tap the video to show or hide them and the **✕**. They hide by themselves after
  a few seconds.
- **Rotate** (phones): tap to turn the picture sideways (or back). Long-press to follow the
  phone again (auto-rotate).
- **Pinch** to zoom in. Tap **Reset zoom** to go back.
- **Swipe** left or right to move to the next camera.
- **Talk:** press and hold the **microphone** to speak through the camera's speaker; it turns
  red while the camera hears you, and the camera's own sound pauses so it doesn't echo. This
  needs a camera with two-way audio; the first time, Android asks for microphone access.
- **Phone asleep?** When you come back, the video reconnects by itself.

<img src="screenshots/full-screen.webp" width="220" alt="Full screen">

<br clear="right">

## When a camera opens

<img src="screenshots/per-camera-defaults.webp" width="220" align="right" alt="Per-camera defaults">

Each camera remembers how you last watched it: HD/SD, sound, volume, orientation and full
screen. To fix them instead, open the camera's **⋮ → Edit → When this camera opens**:

- **Stream:** Last used, HD or SD.
- **Sound:** Last used, On or Muted.
- **Full screen:** Last used, On or Off.
- **Orientation:** Last used, Auto, Landscape or Portrait.

<br clear="right">

## Grid

<img src="screenshots/grid.webp" width="220" align="right" alt="Grid">

- Tap the grid icon on the camera list.
- **Layout:** *Auto* fits the tiles to your screen (one column on a phone held upright), or
  choose 1–4 columns. Only cameras on screen play, to save data and battery.
- **Tap a tile** to open the camera. Each tile shows a status dot (live, connecting, offline,
  paused) with **sound** and **pause** buttons. A paused tile shows its last image.
- **Long-press** a tile for more: open, pause/play, listen, or hide it from the grid.
- **Offline?** Tap **Retry** on the tile.
- **Arrange:** drag cameras into order and switch off the ones you don't want in the grid.
- **⋮ → Pause all / Play all.**

<br clear="right">

## Camera settings

Open a camera and tap the settings icon, or use **⋮ → Camera settings** on the list.
What you can change depends on the camera:

- **Clock:** set the camera's time from your device.
- **Video, per stream:** codec, resolution, frame rate, bitrate, CBR/VBR, keyframe interval,
  and audio on/off. A shorter keyframe interval makes video start faster.
- **Image:** flip/mirror, or brightness, contrast, saturation and sharpness.
- **Pan / tilt / zoom:** hold a direction to move.
- **Password:** changes it on the camera, and in CamStation too.
- **Restart camera.**

<br clear="right">

## App settings

<img src="screenshots/settings.webp" width="220" align="right" alt="Settings">

- **Theme:** System, Light or Dark, and an accent colour.
- **Default stream:** what cameras open with before you have watched them.
- **Player:** Auto picks the best player for each camera. Choose WebRTC or RTSP only if
  asked to while troubleshooting.
- **Boost camera sound:** makes camera audio much louder (on by default), for hearing a
  machine, an alarm or a voice from across the room. Turn it off for cameras that are already
  loud.
- **Keep screen on:** *While watching* (the default), *Always* while the app is open, or
  *Off*.
- **Show stream details:** shows the player and codecs on the video.

<br clear="right">

## Troubleshooting

| Problem | Try |
|---|---|
| Camera not found when scanning | Enter its network under *Camera on a different network?*, or add it by IP address |
| "Wrong username or password" | Check the camera's login. Some cameras lock you out for a few minutes after several wrong tries |
| Video but no sound | In **Camera settings → Video**, turn **Audio** on for the stream |
| Slow to start | Lower the keyframe interval in Camera settings (1–2 s) |
| HD won't play on an older phone | The HD stream is probably 4K. Use **SD**, or set the HD stream to 1080P in **Camera settings → Video** |
| Talk says the camera is busy | Close other apps or devices that are talking to the camera, then try again |
| Anything else | **Settings → Media engine and diagnostics → Copy**, then include the log when you report the problem |
