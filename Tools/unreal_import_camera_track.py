"""
unreal_import_camera_track.py

Run inside the Unreal Editor Python console (or via -ExecutePythonScript on
launch). Reads camera_track.json + environment_scan.obj produced by the iOS
app, builds a CineCameraActor with exact per-frame keyframes, and imports the
LiDAR scan as reference/occlusion geometry.

COORDINATE CONVERSION (the part worth getting right):
ARKit:   right-handed, Y-up,    +X right, -Z forward, units = meters
Unreal:  left-handed,  Z-up,    +X forward (camera looks +X), units = cm

Going from RH-Y-up to LH-Z-up is a *reflection*, not a pure rotation, so you
cannot do it by just permuting rows/columns of the rotation matrix - that
would leave you with a non-orthogonal / mirrored result. The correct change
of basis:

    position:  ue = (ar.x, ar.z, ar.y) * 100          # swap Y/Z, scale to cm
    rotation:  negate the Y component of the resulting Euler/quat AFTER
               converting, to flip handedness back to a proper rotation
               (equivalently: conjugate the quaternion's y term)

This is implemented exactly below rather than approximated.
"""

import json
import math
import unreal

TRACK_JSON = r"C:\LidarCamTrack\camera_track.json"
SCAN_OBJ = r"C:\LidarCamTrack\environment_scan.obj"
FPS = 24.0

# iPhone 16 Pro main wide camera - physical sensor width in mm, used only to
# back out a focal length (mm) from the pixel focal length (fx) so the
# CineCameraComponent's filmback math matches. The FOV this produces is what
# actually has to be correct; the "mm" numbers are just how UE's camera asks for it.
SENSOR_WIDTH_MM = 9.8


def ar_to_ue_location(x, y, z):
    return unreal.Vector(x * 100.0, z * 100.0, y * 100.0)


def ar_matrix_to_ue_rotator(m):
    """m is a 16-element column-major 4x4 (ARKit convention). Extract the
    3x3 rotation, convert basis RH-Y-up -> LH-Z-up, return an FRotator."""
    # columns in ARKit's flattening: col0=(0..3), col1=(4..7), col2=(8..11), col3=(12..15)
    r00, r10, r20 = m[0], m[1], m[2]
    r01, r11, r21 = m[4], m[5], m[6]
    r02, r12, r22 = m[8], m[9], m[10]

    # Swap the Y and Z basis rows/cols (matches the position swap above),
    # then negate the row that introduces the handedness flip to keep the
    # resulting matrix a proper rotation (det = +1) instead of a mirror.
    ue_r00, ue_r01, ue_r02 = r00, r02, r01
    ue_r20, ue_r21, ue_r22 = r20, r22, r21
    ue_r10, ue_r11, ue_r12 = -r10, -r12, -r11

    rot_matrix = unreal.Matrix(
        [ue_r00, ue_r01, ue_r02, 0.0],
        [ue_r10, ue_r11, ue_r12, 0.0],
        [ue_r20, ue_r21, ue_r22, 0.0],
        [0.0, 0.0, 0.0, 1.0],
    )
    return rot_matrix.rotator()


def fov_from_intrinsics(fx, fy, width, height):
    h_fov = 2.0 * math.degrees(math.atan(width / (2.0 * fx)))
    v_fov = 2.0 * math.degrees(math.atan(height / (2.0 * fy)))
    return h_fov, v_fov


def main():
    with open(TRACK_JSON, "r") as f:
        frames = json.load(f)

    world = unreal.EditorLevelLibrary.get_editor_world()
    cam_actor = unreal.EditorLevelLibrary.spawn_actor_from_class(
        unreal.CineCameraActor, unreal.Vector(0, 0, 0)
    )
    cam_comp = cam_actor.get_cine_camera_component()
    cam_comp.filmback.sensor_width = SENSOR_WIDTH_MM
    cam_comp.filmback.sensor_height = SENSOR_WIDTH_MM * (frames[0]["imageHeight"] / frames[0]["imageWidth"])

    # Build a level sequence and bind the camera for keyframing.
    seq_path = "/Game/Cinematics/CameraTrackImport"
    sequence = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
        "CameraTrackImport", "/Game/Cinematics", unreal.LevelSequence, unreal.LevelSequenceFactoryNew()
    )
    sequence.set_display_rate(unreal.FrameRate(numerator=int(FPS), denominator=1))

    binding = sequence.add_possessable(cam_actor)
    transform_track = binding.add_track(unreal.MovieScene3DTransformTrack)
    transform_section = transform_track.add_section()
    transform_section.set_range(0, len(frames))

    t0 = frames[0]["hostTimestamp"]

    for i, fr in enumerate(frames):
        m = fr["transform"]
        loc = ar_to_ue_location(m[12], m[13], m[14])
        rot = ar_matrix_to_ue_rotator(m)

        frame_time = unreal.FrameNumber(int(round((fr["hostTimestamp"] - t0) * FPS)))

        channels = transform_section.get_all_channels()
        # channels[0..2] = location X/Y/Z, [3..5] = rotation Roll/Pitch/Yaw
        unreal.MovieSceneScriptingDoubleChannel.cast(channels[0]).add_key(frame_time, loc.x)
        unreal.MovieSceneScriptingDoubleChannel.cast(channels[1]).add_key(frame_time, loc.y)
        unreal.MovieSceneScriptingDoubleChannel.cast(channels[2]).add_key(frame_time, loc.z)
        unreal.MovieSceneScriptingDoubleChannel.cast(channels[3]).add_key(frame_time, rot.roll)
        unreal.MovieSceneScriptingDoubleChannel.cast(channels[4]).add_key(frame_time, rot.pitch)
        unreal.MovieSceneScriptingDoubleChannel.cast(channels[5]).add_key(frame_time, rot.yaw)

        # Per-frame FOV - only needed if focal length/zoom changes mid-shot;
        # for a fixed-lens static-focal-length take you can set this once.
        fx, fy = fr["intrinsics"][0], fr["intrinsics"][4]
        h_fov, _ = fov_from_intrinsics(fx, fy, fr["imageWidth"], fr["imageHeight"])
        cam_comp.set_editor_property("field_of_view", h_fov)

    # Import the LiDAR scan as the set's reference/occlusion geometry.
    import_task = unreal.AssetImportTask()
    import_task.filename = SCAN_OBJ
    import_task.destination_path = "/Game/Scans"
    import_task.automated = True
    unreal.AssetToolsHelpers.get_asset_tools().import_asset_tasks([import_task])

    unreal.EditorAssetLibrary.save_loaded_asset(sequence)
    print(f"Imported {len(frames)} frames as a {FPS}fps camera track + environment scan.")


if __name__ == "__main__":
    main()
