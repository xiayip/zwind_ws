"""Square tag pose from its corners, resolving the planar flip ambiguity with an "it faces up" prior."""
import cv2
import numpy as np

from zephyr_grasp_perception.geometry import tilt_deg


def tag_object_points(size):
    """Corners in the order OpenCV aruco reports them (top-left, clockwise), tag frame x right, y up."""
    h = size / 2
    return np.array([[-h, h, 0], [h, h, 0], [h, -h, 0], [-h, -h, 0]], np.float32)


def solve_upward_tag(pts, size, K, D, R_bc, max_reprojection_error):
    """Pose of a square tag in the camera frame; of the two IPPE solutions, the one facing up in the base frame.

    A small tag seen from 20 cm gives two solutions mirrored about the line of sight with nearly equal
    reprojection error (on 2026-10-28: 0.58 px for a wrong 89 deg tilt vs 0.77 px for the true 13 deg),
    so the lowest error is not a reliable pick. The strap top faces up, so the smallest tilt wins.
    R_bc: rotation base <- camera. Returns (R_ct, t_ct, reprojection_px, tilt_deg), or None when no
    solution reprojects within max_reprojection_error.
    """
    obj = tag_object_points(size)
    pts = np.asarray(pts, np.float32).reshape(4, 2)
    n, rvecs, tvecs, _ = cv2.solvePnPGeneric(obj, pts, K, D, flags=cv2.SOLVEPNP_IPPE_SQUARE)
    best = None
    for rvec, tvec in zip(rvecs[:n], tvecs[:n]):
        proj, _ = cv2.projectPoints(obj, rvec, tvec, K, D)
        reproj = float(np.linalg.norm(proj.reshape(4, 2) - pts, axis=1).max())
        if reproj > max_reprojection_error:
            continue
        R_ct = cv2.Rodrigues(rvec)[0]
        tilt = tilt_deg(R_bc @ R_ct)
        if best is None or tilt < best[3]:
            best = (R_ct, tvec.ravel(), reproj, tilt)
    return best
