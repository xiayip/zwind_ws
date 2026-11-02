"""Pure geometry for turning a strap tag pose into a top-down pinch grasp (no ROS imports)."""
import numpy as np


def quat_to_matrix(x, y, z, w):
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


def matrix_to_quat(R):
    """Rotation matrix -> (x, y, z, w), numerically stable branch selection."""
    trace = np.trace(R)
    if trace > 0:
        s = 2 * np.sqrt(trace + 1)
        q = ((R[2, 1] - R[1, 2]) / s, (R[0, 2] - R[2, 0]) / s, (R[1, 0] - R[0, 1]) / s, s / 4)
    elif R[0, 0] > R[1, 1] and R[0, 0] > R[2, 2]:
        s = 2 * np.sqrt(1 + R[0, 0] - R[1, 1] - R[2, 2])
        q = (s / 4, (R[0, 1] + R[1, 0]) / s, (R[0, 2] + R[2, 0]) / s, (R[2, 1] - R[1, 2]) / s)
    elif R[1, 1] > R[2, 2]:
        s = 2 * np.sqrt(1 + R[1, 1] - R[0, 0] - R[2, 2])
        q = ((R[0, 1] + R[1, 0]) / s, s / 4, (R[1, 2] + R[2, 1]) / s, (R[0, 2] - R[2, 0]) / s)
    else:
        s = 2 * np.sqrt(1 + R[2, 2] - R[0, 0] - R[1, 1])
        q = ((R[0, 2] + R[2, 0]) / s, (R[1, 2] + R[2, 1]) / s, s / 4, (R[1, 0] - R[0, 1]) / s)
    q = np.array(q)
    return q / np.linalg.norm(q)


def top_down_strap_grasp(tag_R, tag_p, grasp_depth, strap_axis=0, reference_closing=None):
    """TCP target for pinching the strap at the tag centre from straight above.

    tag_R, tag_p: tag pose in a z-up base frame; column `strap_axis` of tag_R runs along the strap.
    Only the tag position and the strap heading are used: a small tag on a soft strap gives unreliable
    roll/pitch. The returned frame follows omni_picker_tcp: z = approach (straight down), y = finger
    closing direction (horizontal, across the strap), x = y cross z (along the strap).
    reference_closing: current TCP y axis in the base frame; picks the yaw of the two symmetric
    solutions that needs the smaller wrist rotation.
    """
    strap = np.array(tag_R[:, strap_axis], dtype=float)
    strap[2] = 0
    norm = np.linalg.norm(strap)
    if norm < 1e-3:
        raise ValueError('strap axis is vertical, heading undefined')
    strap /= norm
    z = np.array([0.0, 0.0, -1.0])
    y = np.cross(z, strap)
    if reference_closing is not None and np.dot(y, reference_closing) < 0:
        y = -y
    x = np.cross(y, z)
    return np.column_stack([x, y, z]), np.asarray(tag_p, dtype=float) + np.array([0.0, 0.0, -grasp_depth])


def tilt_deg(tag_R):
    """Angle between the tag normal and the base z axis."""
    return float(np.degrees(np.arccos(np.clip(tag_R[2, 2], -1.0, 1.0))))
