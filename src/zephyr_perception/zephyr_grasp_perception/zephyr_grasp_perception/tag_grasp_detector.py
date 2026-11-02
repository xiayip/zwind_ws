"""Detect an AprilTag on the box strap in the wrist camera and publish a top-down pinch grasp.

Publishes (only while the tag is seen):
  TF  <camera optical frame> -> <tag_frame_prefix><id>   raw tag pose from PnP
  TF  <base_frame> -> <grasp_frame>                      TCP target, omni_picker_tcp axes
  ~/grasp_pose (geometry_msgs/PoseStamped, base_frame)   same as the grasp TF
  ~/debug_image (sensor_msgs/Image)                      annotated frame, only when subscribed
Read-only on the robot: it never commands the arm or the gripper.
"""
import cv2
import numpy as np
import rclpy
from geometry_msgs.msg import PoseStamped, TransformStamped
from rclpy.duration import Duration
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from rclpy.time import Time
from sensor_msgs.msg import CameraInfo, Image
from tf2_ros import Buffer, TransformBroadcaster, TransformException, TransformListener

from zephyr_grasp_perception.geometry import matrix_to_quat, quat_to_matrix, top_down_strap_grasp
from zephyr_grasp_perception.tag_pose import solve_upward_tag

FINGER_HALF_SPAN = 0.0445  # omni_picker finger links sit at +-44.5 mm on the TCP y axis when open


def image_to_gray(msg):
    buf = np.frombuffer(msg.data, np.uint8).reshape(msg.height, msg.step)
    enc = msg.encoding.lower()
    if enc in ('rgb8', 'bgr8'):
        img = buf[:, :msg.width * 3].reshape(msg.height, msg.width, 3)
        return cv2.cvtColor(img, cv2.COLOR_RGB2GRAY if enc == 'rgb8' else cv2.COLOR_BGR2GRAY), img, enc
    if enc == 'mono8':
        img = buf[:, :msg.width]
        return img, img, enc
    raise ValueError(f'unsupported encoding {msg.encoding}')


def lookup(buffer, target, source, stamp, timeout):
    t = buffer.lookup_transform(target, source, stamp, timeout=timeout).transform
    R = quat_to_matrix(t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w)
    return R, np.array([t.translation.x, t.translation.y, t.translation.z])


class TagGraspDetector(Node):

    def __init__(self):
        super().__init__('tag_grasp_detector')
        self.declare_parameter('image_topic', '/wrist_camera/left_color/image_raw')
        self.declare_parameter('camera_info_topic', '/wrist_camera/left_color/camera_info')
        self.declare_parameter('base_frame', 'base_link')
        self.declare_parameter('tcp_frame', 'omni_picker_tcp')
        self.declare_parameter('grasp_frame', 'strap_grasp')
        self.declare_parameter('tag_frame_prefix', 'strap_tag_')
        self.declare_parameter('tag_ids', [0, 1, 2, 3])
        self.declare_parameter('tag_sizes', [0.014, 0.016, 0.018, 0.020])
        self.declare_parameter('target_id', -1)
        self.declare_parameter('strap_axis', 'x')
        self.declare_parameter('grasp_depth', 0.015)
        self.declare_parameter('max_rate', 5.0)
        self.declare_parameter('max_reprojection_error', 2.0)
        self.declare_parameter('max_tilt', 45.0)
        self.declare_parameter('tf_timeout', 0.1)

        p = lambda name: self.get_parameter(name).value  # noqa: E731
        ids, sizes = p('tag_ids'), p('tag_sizes')
        if len(ids) != len(sizes):
            raise ValueError('tag_ids and tag_sizes must have the same length')
        self.tag_sizes = dict(zip(ids, sizes))
        if p('strap_axis') not in ('x', 'y'):
            raise ValueError("strap_axis must be 'x' or 'y'")
        self.strap_axis = 0 if p('strap_axis') == 'x' else 1
        self.base_frame, self.tcp_frame = p('base_frame'), p('tcp_frame')
        self.grasp_frame, self.tag_prefix = p('grasp_frame'), p('tag_frame_prefix')
        self.target_id, self.grasp_depth = p('target_id'), p('grasp_depth')
        self.min_period = 1.0 / p('max_rate') if p('max_rate') > 0 else 0.0
        self.max_reproj, self.max_tilt = p('max_reprojection_error'), p('max_tilt')
        self.tf_timeout = Duration(seconds=p('tf_timeout'))

        params = cv2.aruco.DetectorParameters()
        params.cornerRefinementMethod = cv2.aruco.CORNER_REFINE_SUBPIX
        self.detector = cv2.aruco.ArucoDetector(
            cv2.aruco.getPredefinedDictionary(cv2.aruco.DICT_APRILTAG_36h11), params)

        self.K = self.D = None
        self.last_stamp = None
        self.tf_buffer = Buffer()
        self.tf_listener = TransformListener(self.tf_buffer, self, spin_thread=True)
        self.tf_broadcaster = TransformBroadcaster(self)
        self.grasp_pub = self.create_publisher(PoseStamped, '~/grasp_pose', 10)
        self.debug_pub = self.create_publisher(Image, '~/debug_image', qos_profile_sensor_data)
        self.create_subscription(CameraInfo, p('camera_info_topic'), self.on_info, qos_profile_sensor_data)
        self.create_subscription(Image, p('image_topic'), self.on_image, qos_profile_sensor_data)
        self.get_logger().info(f'tags {self.tag_sizes} (id: black edge m), grasp_depth {self.grasp_depth} m, '
                               f'base {self.base_frame}, image {p("image_topic")}')

    def on_info(self, msg):
        self.K = np.array(msg.k, dtype=float).reshape(3, 3)
        self.D = np.array(msg.d, dtype=float)

    def on_image(self, msg):
        if self.K is None:
            return
        stamp = Time.from_msg(msg.header.stamp)
        if self.last_stamp is not None and (stamp - self.last_stamp).nanoseconds * 1e-9 < self.min_period:
            return
        self.last_stamp = stamp
        gray, color, enc = image_to_gray(msg)
        corners, ids, _ = self.detector.detectMarkers(gray)
        known = [(int(i), c.reshape(4, 2)) for c, i in zip(corners, [] if ids is None else ids.ravel())
                 if int(i) in self.tag_sizes and (self.target_id < 0 or int(i) == self.target_id)]
        detections, camera, grasp = [], None, None
        if known:
            try:  # base <- camera is needed to tell the two mirrored tag poses apart
                camera = lookup(self.tf_buffer, self.base_frame, msg.header.frame_id, stamp, self.tf_timeout)
            except TransformException as e:
                self.get_logger().warn(f'no TF {self.base_frame} <- {msg.header.frame_id}: {e}',
                                       throttle_duration_sec=2.0)
        for tag_id, pts in known if camera is not None else []:
            pose = solve_upward_tag(pts, self.tag_sizes[tag_id], self.K, self.D, camera[0], self.max_reproj)
            if pose is None:
                self.get_logger().warn(f'tag {tag_id}: no pose within {self.max_reproj} px reprojection error',
                                       throttle_duration_sec=2.0)
            elif pose[3] > self.max_tilt:
                self.get_logger().warn(f'tag {tag_id}: tilt {pose[3]:.0f} deg > {self.max_tilt}, skipped',
                                       throttle_duration_sec=2.0)
            else:
                detections.append((tag_id, pts, *pose))
        if detections:
            tag_id, _, R_ct, t_ct, _, _ = min(detections, key=lambda d: d[3][2])  # nearest tag
            self.send_tf(msg.header, msg.header.frame_id, self.tag_prefix + str(tag_id), R_ct, t_ct)
            grasp = self.publish_grasp(msg.header, *camera, R_ct, t_ct)
        if self.debug_pub.get_subscription_count() > 0:
            self.publish_debug(msg, color, enc, known, detections, grasp)

    def publish_grasp(self, header, R_bc, t_bc, R_ct, t_ct):
        try:
            reference = lookup(self.tf_buffer, self.base_frame, self.tcp_frame, Time.from_msg(header.stamp),
                               self.tf_timeout)[0][:, 1]
        except TransformException:
            reference = None
        R_bt, t_bt = R_bc @ R_ct, R_bc @ t_ct + t_bc
        try:
            R_bg, t_bg = top_down_strap_grasp(R_bt, t_bt, self.grasp_depth, self.strap_axis, reference)
        except ValueError as e:
            self.get_logger().warn(str(e), throttle_duration_sec=2.0)
            return None
        out = PoseStamped()
        out.header.stamp, out.header.frame_id = header.stamp, self.base_frame
        out.pose.position.x, out.pose.position.y, out.pose.position.z = map(float, t_bg)
        q = matrix_to_quat(R_bg)
        out.pose.orientation.x, out.pose.orientation.y, out.pose.orientation.z, out.pose.orientation.w = map(float, q)
        self.grasp_pub.publish(out)
        self.send_tf(out.header, self.base_frame, self.grasp_frame, R_bg, t_bg)
        return R_bc, t_bc, R_bg, t_bg

    def send_tf(self, header, parent, child, R, t):
        msg = TransformStamped()
        msg.header.stamp, msg.header.frame_id, msg.child_frame_id = header.stamp, parent, child
        msg.transform.translation.x, msg.transform.translation.y, msg.transform.translation.z = map(float, t)
        q = matrix_to_quat(R)
        msg.transform.rotation.x, msg.transform.rotation.y, msg.transform.rotation.z, msg.transform.rotation.w = \
            map(float, q)
        self.tf_broadcaster.sendTransform(msg)

    def publish_debug(self, msg, color, enc, tags, detections, grasp):
        img = cv2.cvtColor(color, cv2.COLOR_RGB2BGR if enc == 'rgb8' else cv2.COLOR_GRAY2BGR) \
            if enc != 'bgr8' else color.copy()
        for tag_id, pts in tags:  # orange: seen but rejected (no TF / reprojection / tilt), green below if used
            cv2.polylines(img, [pts.astype(np.int32)], True, (0, 165, 255), 2)
        for tag_id, pts, R_ct, t_ct, reproj, tilt in detections:
            cv2.polylines(img, [pts.astype(np.int32)], True, (0, 255, 0), 2)
            cv2.drawFrameAxes(img, self.K, self.D, cv2.Rodrigues(R_ct)[0], t_ct, self.tag_sizes[tag_id], 2)
            x, y = pts.min(0).astype(int)
            cv2.putText(img, f'id {tag_id} {t_ct[2] * 100:.1f} cm tilt {tilt:.0f} reproj {reproj:.2f}px', (x, y - 8),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2)
        if grasp is not None:
            R_bc, t_bc, R_bg, t_bg = grasp
            # Fingertip positions in the camera frame: grasp centre +- half span along the closing (y) axis.
            pts_b = np.array([t_bg, t_bg + FINGER_HALF_SPAN * R_bg[:, 1], t_bg - FINGER_HALF_SPAN * R_bg[:, 1]])
            pts_c = (pts_b - t_bc) @ R_bc
            uv, _ = cv2.projectPoints(pts_c, np.zeros(3), np.zeros(3), self.K, self.D)
            c, a, b = uv.reshape(3, 2).astype(int)
            cv2.line(img, tuple(a), tuple(b), (0, 0, 255), 2)
            for end in (a, b):
                cv2.circle(img, tuple(end), 6, (0, 0, 255), 2)
            cv2.drawMarker(img, tuple(c), (0, 0, 255), cv2.MARKER_CROSS, 18, 2)
            cv2.putText(img, f'grasp {self.base_frame} [{t_bg[0]:.3f} {t_bg[1]:.3f} {t_bg[2]:.3f}] '
                        f'yaw {np.degrees(np.arctan2(R_bg[1, 0], R_bg[0, 0])):.0f}',
                        (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
        out = Image()
        out.header = msg.header
        out.height, out.width = img.shape[:2]
        out.encoding, out.step = 'bgr8', img.shape[1] * 3
        out.data = img.tobytes()
        self.debug_pub.publish(out)


def main(args=None):
    rclpy.init(args=args)
    node = TagGraspDetector()
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
