import cv2
import numpy as np
import pytest

from zephyr_grasp_perception.geometry import quat_to_matrix, tilt_deg
from zephyr_grasp_perception.tag_pose import solve_upward_tag, tag_object_points

# Live wrist frame from 2026-10-28 (log/pick_place/tag-20261028/far): 17 mm tag ID 3, ~48 px per side.
K = np.array([[613.8477, 0, 640.2665], [0, 613.6994, 398.2291], [0, 0, 1]])
D = np.array([-1.182321, 0.747649, -0.000117, 0.000413, -0.163106, -1.164762, 0.723837, -0.153886])
R_BC = quat_to_matrix(0.9848140946065517, -0.0010139980118926367, 0.0023979491159876088, -0.17359268622942323)
CORNERS = np.array([[550.0, 94.0], [555.0, 48.0], [605.43, 46.49], [599.0, 91.0]])


def test_live_frame_flip_resolved_to_upward_solution():
    # The lowest-error solution is the flipped one (tilt ~89 deg) on this frame...
    _, rvec, _ = cv2.solvePnP(tag_object_points(0.017), CORNERS.astype(np.float32), K, D,
                              flags=cv2.SOLVEPNP_IPPE_SQUARE)
    assert tilt_deg(R_BC @ cv2.Rodrigues(rvec)[0]) > 80
    # ...and the upward prior picks the true ~13 deg one.
    R_ct, t_ct, reproj, tilt = solve_upward_tag(CORNERS, 0.017, K, D, R_BC, 2.0)
    assert tilt == pytest.approx(13, abs=3)
    assert reproj < 1.0
    assert t_ct[2] == pytest.approx(0.20, abs=0.01)
    np.testing.assert_allclose(R_ct.T @ R_ct, np.eye(3), atol=1e-9)


def test_reprojection_gate():
    assert solve_upward_tag(CORNERS + [[10, 0], [0, 0], [0, 0], [0, 0]], 0.017, K, D, R_BC, 2.0) is None


def test_bad_corner_can_leave_only_the_flipped_solution():
    # A 6 px corner error pushes the true pose past the gate; the survivor is the flip, which the node's
    # max_tilt check has to reject.
    _, _, _, tilt = solve_upward_tag(CORNERS + [[6, 0], [0, 0], [0, 0], [0, 0]], 0.017, K, D, R_BC, 2.0)
    assert tilt > 45
