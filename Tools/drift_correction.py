"""
drift_correction.py

This is the piece that actually gets you "basically no drift" — not a better
tracking algorithm, but an absolute reference to correct against. Print a few
ArUco markers, measure their real-world positions once with a tape measure,
and every frame this script checks ARKit's pose against what the markers say
the camera pose *must* be, then corrects.

SETUP (do this once per set):
  1. Print 4-8 ArUco markers (DICT_6X6_250, ~20cm square each works well for
     a room-sized space). Tape them to walls/floor - spread out, not
     clustered, and visible from most of your camera positions.
  2. Measure each marker's center position in real-world meters, in a
     consistent coordinate frame (e.g. one corner of the room = origin).
     Put them in marker_map.json:
       { "markers": [ {"id": 0, "position": [0.0, 0.0, 0.0], "size_m": 0.20},
                      {"id": 1, "position": [3.2, 0.0, 1.1], "size_m": 0.20} ] }
  3. Make sure the SAME origin/axes convention is used here as in your
     ARKit session's world alignment (.gravity keeps Y up, but X/Z heading
     is set by wherever the session started - note that down on set).

WHAT THIS DOES NOT DO: fix a marker-less take after the fact. If you didn't
put markers in frame for this shot, this script has nothing to correct
against and ARKit's raw track (still good, just not "zero-drift") is what
you've got. Plan the markers into the shot.

Dependencies: pip install opencv-contrib-python numpy scipy
"""

import json
import sys
import numpy as np
import cv2
from cv2 import aruco
from scipy.spatial.transform import Rotation, Slerp


def load_marker_map(path):
    with open(path) as f:
        data = json.load(f)
    obj_points = {}
    for m in data["markers"]:
        s = m["size_m"] / 2.0
        cx, cy, cz = m["position"]
        # four corners of the marker in world space, same order ArUco returns
        # detected corners in (clockwise from top-left), assuming marker lies
        # flat against a wall facing +X - adjust per-marker if orientation
        # differs on your set.
        obj_points[m["id"]] = np.array([
            [cx - s, cy + s, cz],
            [cx + s, cy + s, cz],
            [cx + s, cy - s, cz],
            [cx - s, cy - s, cz],
        ], dtype=np.float32)
    return obj_points


def solve_marker_pose(frame_bgr, obj_points, camera_matrix, dist_coeffs):
    gray = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2GRAY)
    dictionary = aruco.getPredefinedDictionary(aruco.DICT_6X6_250)
    parameters = aruco.DetectorParameters()
    detector = aruco.ArucoDetector(dictionary, parameters)
    corners, ids, _ = detector.detectMarkers(gray)

    if ids is None or len(ids) == 0:
        return None  # no markers visible this frame - nothing to correct against

    all_obj = []
    all_img = []
    for i, marker_id in enumerate(ids.flatten()):
        if marker_id not in obj_points:
            continue
        all_obj.append(obj_points[marker_id])
        all_img.append(corners[i][0])

    if not all_obj:
        return None

    obj_pts = np.concatenate(all_obj, axis=0)
    img_pts = np.concatenate(all_img, axis=0)

    ok, rvec, tvec = cv2.solvePnP(obj_pts, img_pts, camera_matrix, dist_coeffs,
                                   flags=cv2.SOLVEPNP_ITERATIVE)
    if not ok:
        return None

    R, _ = cv2.Rodrigues(rvec)
    # solvePnP gives world->camera; invert to get camera's world-space pose,
    # which is what we're comparing against ARKit's camera.transform.
    cam_position = -R.T @ tvec
    cam_rotation = Rotation.from_matrix(R.T)
    return cam_position.flatten(), cam_rotation


def complementary_blend(arkit_pos, arkit_rot, marker_pos, marker_rot, trust_markers=0.85):
    """When markers are visible, pull the pose heavily toward the marker
    solution (it's an absolute reference; ARKit's is a drifting integral).
    trust_markers=0.85 keeps a little ARKit smoothing to avoid frame-to-frame
    jitter from marker-detection noise - raise toward 1.0 if your marker
    detection is clean and stable, lower if markers are small/far/noisy."""
    blended_pos = (1 - trust_markers) * arkit_pos + trust_markers * marker_pos
    slerp = Slerp([0, 1], Rotation.concatenate([arkit_rot, marker_rot]))
    blended_rot = slerp([trust_markers])[0]
    return blended_pos, blended_rot


def correct_track(camera_track_json, video_path, marker_map_json, output_json,
                   camera_matrix, dist_coeffs):
    with open(camera_track_json) as f:
        frames = json.load(f)
    obj_points = load_marker_map(marker_map_json)

    cap = cv2.VideoCapture(video_path)
    corrected = []
    last_good_correction = None  # (pos_offset, rot_offset) - holds between marker sightings

    for i, fr in enumerate(frames):
        ok, frame_bgr = cap.read()
        if not ok:
            break

        t = fr["transform"]
        arkit_pos = np.array([t[12], t[13], t[14]])
        arkit_R = np.array([[t[0], t[4], t[8]],
                             [t[1], t[5], t[9]],
                             [t[2], t[6], t[10]]])
        arkit_rot = Rotation.from_matrix(arkit_R)

        marker_result = solve_marker_pose(frame_bgr, obj_points, camera_matrix, dist_coeffs)

        if marker_result is not None:
            marker_pos, marker_rot = marker_result
            blended_pos, blended_rot = complementary_blend(arkit_pos, arkit_rot, marker_pos, marker_rot)
            # Remember the correction (ARKit-relative offset) so frames
            # between marker sightings can still be nudged rather than
            # snapping back to raw, drifting ARKit.
            last_good_correction = (blended_pos - arkit_pos, blended_rot * arkit_rot.inv())
        elif last_good_correction is not None:
            pos_offset, rot_offset = last_good_correction
            blended_pos = arkit_pos + pos_offset
            blended_rot = rot_offset * arkit_rot
        else:
            blended_pos, blended_rot = arkit_pos, arkit_rot  # no marker seen yet this take

        R_out = blended_rot.as_matrix()
        new_transform = [
            R_out[0, 0], R_out[1, 0], R_out[2, 0], 0,
            R_out[0, 1], R_out[1, 1], R_out[2, 1], 0,
            R_out[0, 2], R_out[1, 2], R_out[2, 2], 0,
            blended_pos[0], blended_pos[1], blended_pos[2], 1,
        ]
        fr["transform"] = new_transform
        fr["driftCorrected"] = marker_result is not None
        corrected.append(fr)

    with open(output_json, "w") as f:
        json.dump(corrected, f)

    seen_count = sum(1 for f in corrected if f["driftCorrected"])
    print(f"Corrected {len(corrected)} frames - markers directly visible in {seen_count} of them.")
    if seen_count < len(corrected) * 0.3:
        print("⚠️ Markers were visible in under 30% of frames - consider adding more "
              "markers or repositioning them so more of the shot can see at least one.")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        print("Usage: python drift_correction.py camera_track.json video.mov marker_map.json output.json")
        sys.exit(1)

    # Camera matrix here should come from the SAME intrinsics ARKit reported
    # (camera_track.json's fx/fy/cx/cy) - not a generic default - so the PnP
    # solve is consistent with the pose space you're correcting.
    sample_fx = 1500.0  # placeholder - pull real fx/fy/cx/cy from frame 0 of your track
    camera_matrix = np.array([[sample_fx, 0, 1920], [0, sample_fx, 1080], [0, 0, 1]])
    dist_coeffs = np.zeros(5)  # use undistorted frames here, or your real distortion coeffs

    correct_track(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], camera_matrix, dist_coeffs)
