# LidarCamTrack

An iOS LiDAR/ARKit camera-tracking app for VFX: records true 4K/24fps video
while tracking camera pose, corrects drift against printed physical markers,
and exports a camera track + environment scan straight into Unreal.

## What's here

```
Sources/                       the iOS app
  LidarCamTrackApp.swift         SwiftUI entry point
  ContentView.swift               record screen, status, export location
  CaptureCoordinator.swift        starts/stops AR tracking + 4K video together
  ARTrackerSession.swift          ARKit + LiDAR mesh, per-frame pose export
  MultiCamCaptureSession.swift    the real 4K/24 capture + pose resampling
project.yml                    XcodeGen spec - this IS the Xcode project, as text
.github/workflows/build_ipa.yml  builds the .ipa on GitHub's macOS runners
Tools/
  drift_correction.py            ArUco marker correction pass (post-shoot)
  marker_map.example.json        template for your real marker measurements
  unreal_import_camera_track.py  imports the corrected track into Unreal
```

You never need Xcode installed anywhere. `project.yml` fully describes the
app; GitHub's macOS runner turns it into a real Xcode project and builds it
on every push.

## Build it from your Windows PC

**1. One-time setup**
- Install [Git for Windows](https://git-scm.com/download/win)
- Create a free GitHub account if you don't have one
- Create a new **empty** repo on github.com, e.g. `LidarCamTrack`

**2. Push this folder to GitHub**

Open PowerShell or Git Bash in this folder and run:
```
git init
git add .
git commit -m "Initial app"
git branch -M main
git remote add origin https://github.com/<your-username>/LidarCamTrack.git
git push -u origin main
```

**3. Let it build**

Pushing to `main` triggers the workflow automatically. On github.com, go to
your repo → **Actions** tab → you'll see "Build IPA" running (takes a few
minutes on first run). When it finishes with a green check, click into the
run → scroll to **Artifacts** → download `LidarCamTrack-unsigned` (a zip
containing the `.ipa`).

If it fails instead: click the red ✗ run → open the failing step → the error
is almost always either a typo in `project.yml` or a Swift compile error in
one of the `Sources/` files — the log will point at the exact line.

**4. Install Sideloadly on Windows**
- Download from [sideloadly.app](https://sideloadly.app) (Windows build is right there on the page)
- Install **Apple Devices** / iTunes from the Microsoft Store (or apple.com) so Windows has the drivers to see your iPhone over USB — Sideloadly needs this even though you're not using iTunes itself
- Plug in your iPhone 16 Pro, trust the computer when prompted

**5. Sideload**
- Open Sideloadly, drag the unzipped `.ipa` into it
- Enter your Apple ID (a free one is fine — no paid developer account needed)
- Click **Start**
- On the iPhone: **Settings → General → VPN & Device Management** → tap your Apple ID → **Trust**

**6. Known limit of the free-Apple-ID path**
The app stops opening after **7 days** and needs re-sideloading (just repeat
step 5 — no need to rebuild). A $99/year Apple Developer account extends that
to a year; that's an Apple platform rule, nothing in this project changes it.

## Using it on your shoot

1. Print 4–8 ArUco markers (`DICT_6X6_250`, ~20cm squares), tape them around
   the set spread out so most camera positions can see at least one.
2. Measure each marker's real-world center position once; fill in
   `Tools/marker_map.example.json` (rename to `marker_map.json`).
3. Open the app, hit **Start Recording**, shoot, hit **Stop & Export**.
4. In Files app → On My iPhone → LidarCamTrack → pull the `Take_...` folder
   off onto your PC (AirDrop, cable, or iCloud Drive all work).
5. On your PC: `pip install opencv-contrib-python numpy scipy`, then:
   ```
   python Tools/drift_correction.py camera_track.json video_4k24.mov marker_map.json corrected_camera_track.json
   ```
   (edit the placeholder `sample_fx` near the bottom of that script to the
   real fx from your own `camera_track.json` first — it's marked clearly.)
6. In Unreal Editor's Python console, point the paths at the top of
   `Tools/unreal_import_camera_track.py` at your corrected track + scan, and run it.

## The honest limit, one more time

Drift correction only works on frames where a marker is actually visible.
No markers in frame for a stretch of the shot = ordinary ARKit tracking for
that stretch, which is good but not driftless. Plan marker placement around
your blocking, not as an afterthought.
