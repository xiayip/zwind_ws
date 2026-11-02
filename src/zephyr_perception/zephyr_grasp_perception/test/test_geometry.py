import numpy as np
import pytest

from zephyr_grasp_perception.geometry import matrix_to_quat, quat_to_matrix, tilt_deg, top_down_strap_grasp


def rot_z(deg):
    a = np.radians(deg)
    return np.array([[np.cos(a), -np.sin(a), 0], [np.sin(a), np.cos(a), 0], [0, 0, 1]])


def rot_x(deg):
    a = np.radians(deg)
    return np.array([[1, 0, 0], [0, np.cos(a), -np.sin(a)], [0, np.sin(a), np.cos(a)]])


def test_flat_strap_along_y():
    tag_R = rot_z(90)  # tag x (strap) along base y, normal up
    R, p = top_down_strap_grasp(tag_R, [0.0, 0.3, 0.02], 0.015)
    np.testing.assert_allclose(R[:, 2], [0, 0, -1])
    np.testing.assert_allclose(abs(R[:, 1] @ [1, 0, 0]), 1, atol=1e-9)  # fingers close across the strap
    np.testing.assert_allclose(p, [0.0, 0.3, 0.005])
    np.testing.assert_allclose(np.linalg.det(R), 1)
    np.testing.assert_allclose(R.T @ R, np.eye(3), atol=1e-12)


def test_reference_closing_picks_smaller_wrist_rotation():
    tag_R = rot_z(90)
    for ref in ([1, 0, 0], [-1, 0, 0]):
        R, _ = top_down_strap_grasp(tag_R, [0, 0, 0], 0, reference_closing=np.array(ref, float))
        assert R[:, 1] @ ref > 0.99


def test_sloped_and_tilted_strap_keeps_vertical_approach():
    rot_y = np.array([[np.cos(.23), 0, np.sin(.23)], [0, 1, 0], [-np.sin(.23), 0, np.cos(.23)]])
    tag_R = rot_z(76) @ rot_y @ rot_x(-14)  # strap rising ~13 deg and leaning sideways, as on the test box
    R, _ = top_down_strap_grasp(tag_R, [0, 0, 0], 0)
    np.testing.assert_allclose(R[:, 2], [0, 0, -1])
    heading = np.degrees(np.arctan2(R[1, 0], R[0, 0])) % 180
    assert abs(heading - 76) < 1e-6
    assert R[2, 1] == pytest.approx(0)


def test_strap_axis_y():
    tag_R = rot_z(90)  # tag y along base -x
    R, _ = top_down_strap_grasp(tag_R, [0, 0, 0], 0, strap_axis=1)
    np.testing.assert_allclose(abs(R[:, 0] @ [1, 0, 0]), 1, atol=1e-9)


def test_vertical_strap_rejected():
    with pytest.raises(ValueError):
        top_down_strap_grasp(np.array([[0, 0, 1], [0, 1, 0], [-1, 0, 0]]), [0, 0, 0], 0)  # tag x = -z


def test_quaternion_round_trip_and_tilt():
    rng = np.random.default_rng(0)
    for q in rng.normal(size=(50, 4)):
        q /= np.linalg.norm(q)
        R = quat_to_matrix(*q)
        q2 = matrix_to_quat(R)
        np.testing.assert_allclose(quat_to_matrix(*q2), R, atol=1e-9)
    assert tilt_deg(rot_x(30)) == pytest.approx(30)
