#!/usr/bin/env python3
"""Verify JPEG delivery from another container, without sharing camera devices."""
import json
import time
import rclpy
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import CompressedImage

rclpy.init()
node = rclpy.create_node('j401_jpeg_verifier')
times, sizes = [], []
formats = set()
valid = True


def receive(msg):
    global valid
    times.append(time.monotonic())
    sizes.append(len(msg.data))
    formats.add(msg.format)
    valid = valid and bytes(msg.data[:2]) == b'\xff\xd8' and bytes(msg.data[-2:]) == b'\xff\xd9'


node.create_subscription(CompressedImage, '/camera/gmsl/image_raw/compressed', receive,
                         qos_profile_sensor_data)
end = time.monotonic() + 12
while time.monotonic() < end:
    rclpy.spin_once(node, timeout_sec=0.2)
report = {'count': len(times), 'formats': sorted(formats), 'jpeg_markers_valid': valid,
          'fps': (len(times)-1)/(times[-1]-times[0]) if len(times)>1 else 0,
          'mean_bytes': sum(sizes)/len(sizes) if sizes else 0}
report['passed'] = len(times)>30 and valid
print(json.dumps(report, indent=2))
node.destroy_node()
rclpy.shutdown()
raise SystemExit(0 if report['passed'] else 1)
