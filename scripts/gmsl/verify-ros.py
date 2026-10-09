#!/usr/bin/env python3
"""Subscribe to real image + CameraInfo messages and emit a compact evidence report."""
import argparse
import json
import time

import rclpy
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import CameraInfo, Image

parser = argparse.ArgumentParser()
parser.add_argument('--seconds', type=float, default=20)
parser.add_argument('--snapshot')
args = parser.parse_args()
rclpy.init()
node = rclpy.create_node('j401_gmsl_verifier')
arrivals, stamps, metadata, infos = [], [], {}, []


def receive_image(msg):
    arrivals.append(time.monotonic())
    stamps.append(msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9)
    metadata.update(width=msg.width, height=msg.height, encoding=msg.encoding,
                    step=msg.step, bytes=len(msg.data), frame_id=msg.header.frame_id)
    if args.snapshot and len(arrivals) == 1:
        # PPM avoids NumPy/cv_bridge ABI dependencies in the development image.
        if msg.encoding != 'rgb8':
            raise RuntimeError('Snapshot expects rgb8')
        with open(args.snapshot, 'wb') as out:
            out.write(f'P6\n{msg.width} {msg.height}\n255\n'.encode())
            for row in range(msg.height):
                out.write(bytes(msg.data[row * msg.step:row * msg.step + msg.width * 3]))


def receive_info(msg):
    infos.append({'width': msg.width, 'height': msg.height,
                  'frame_id': msg.header.frame_id, 'calibrated': bool(msg.k[0] != 0),
                  'stamp': msg.header.stamp.sec + msg.header.stamp.nanosec * 1e-9})


node.create_subscription(Image, '/camera/gmsl/image_raw', receive_image, qos_profile_sensor_data)
node.create_subscription(CameraInfo, '/camera/gmsl/camera_info', receive_info, qos_profile_sensor_data)
end = time.monotonic() + args.seconds
while time.monotonic() < end:
    rclpy.spin_once(node, timeout_sec=0.2)
report = {'image_count': len(arrivals), 'camera_info_count': len(infos), 'image': metadata}
if len(arrivals) > 1:
    report['received_fps'] = (len(arrivals) - 1) / (arrivals[-1] - arrivals[0])
    intervals = [b - a for a, b in zip(stamps, stamps[1:])]
    report['timestamp_fps'] = (len(stamps) - 1) / (stamps[-1] - stamps[0])
    report['max_timestamp_gap_seconds'] = max(intervals)
    report['timestamps_strictly_increasing'] = all(x > 0 for x in intervals)
    report['latest_image_age_seconds'] = node.get_clock().now().nanoseconds * 1e-9 - stamps[-1]
if infos:
    report['camera_info'] = infos[-1]
    image_stamps = set(stamps)
    report['matched_camera_info_stamps'] = sum(i['stamp'] in image_stamps for i in infos)
passed = (len(arrivals) >= 30 and len(infos) >= 1
          and metadata.get('width') == 1920 and metadata.get('height') == 1080
          and report.get('timestamps_strictly_increasing', False)
          and report.get('received_fps', 0) >= 25)
report['passed'] = passed
print(json.dumps(report, indent=2))
node.destroy_node()
rclpy.shutdown()
raise SystemExit(0 if passed else 1)
