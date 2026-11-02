#!/usr/bin/env python3
"""Check all four ROS streams concurrently; save evidence without modifying devices."""
import argparse
import json
from pathlib import Path
import time

import rclpy
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import CameraInfo, CompressedImage, Image


def stamp(msg):
    return msg.header.stamp.sec * 1_000_000_000 + msg.header.stamp.nanosec


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--names', nargs=4, default=['front_right', 'front_left', 'back_left', 'back_right'])
    parser.add_argument('--namespace', default='/cameras')
    parser.add_argument('--transport', choices=['raw', 'compressed'], default='raw')
    parser.add_argument('--seconds', type=float, default=20)
    parser.add_argument('--output-dir', required=True)
    args = parser.parse_args()
    if len(set(args.names)) != 4 or args.seconds < 3:
        parser.error('Four distinct names and at least 3 seconds are required')
    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    rclpy.init()
    node = rclpy.create_node('gmsl_surround_verifier')
    records = {name: {'arrivals': [], 'stamps': [], 'info_stamps': [], 'metadata': {},
                      'camera_info': {}, 'invalid_frames': 0, 'wrong_frame_ids': 0}
               for name in args.names}

    def receive_image(msg, name):
        row = records[name]
        row['arrivals'].append(time.monotonic())
        row['stamps'].append(stamp(msg))
        row['wrong_frame_ids'] += msg.header.frame_id != f'{name}_optical_frame'
        row['metadata'] = {'frame_id': msg.header.frame_id, 'bytes': len(msg.data)}
        first = len(row['arrivals']) == 1
        if args.transport == 'raw':
            valid = (msg.width == 1920 and msg.height == 1080 and msg.encoding == 'rgb8'
                     and msg.step == 1920 * 3 and len(msg.data) == 1920 * 1080 * 3)
            row['metadata'].update(width=msg.width, height=msg.height, encoding=msg.encoding)
            if first and valid:
                (out / f'{name}-ros.ppm').write_bytes(b'P6\n1920 1080\n255\n' + bytes(msg.data))
        else:
            valid = (len(msg.data) > 4 and 'jpeg' in msg.format.lower()
                     and bytes(msg.data[:2]) == b'\xff\xd8'
                     and bytes(msg.data[-2:]) == b'\xff\xd9')
            row['metadata']['format'] = msg.format
            if first and valid:
                (out / f'{name}-ros.jpg').write_bytes(bytes(msg.data))
        row['invalid_frames'] += not valid

    def receive_info(msg, name):
        row = records[name]
        row['info_stamps'].append(stamp(msg))
        row['wrong_frame_ids'] += msg.header.frame_id != f'{name}_optical_frame'
        row['camera_info'] = {'frame_id': msg.header.frame_id, 'width': msg.width,
                              'height': msg.height, 'calibrated': bool(msg.k[0] != 0),
                              'distortion_model': msg.distortion_model}

    for name in args.names:
        prefix = f"/{args.namespace.strip('/')}/{name}"
        topic = prefix + '/image_raw' + ('/compressed' if args.transport == 'compressed' else '')
        node.create_subscription(CompressedImage if args.transport == 'compressed' else Image,
                                 topic, lambda msg, n=name: receive_image(msg, n), qos_profile_sensor_data)
        node.create_subscription(CameraInfo, prefix + '/camera_info',
                                 lambda msg, n=name: receive_info(msg, n), qos_profile_sensor_data)
    deadline = time.monotonic() + args.seconds
    try:
        while time.monotonic() < deadline:
            rclpy.spin_once(node, timeout_sec=0.1)
        report = {'transport': args.transport, 'seconds': args.seconds, 'cameras': {}}
        for name, row in records.items():
            arrivals, stamps = row['arrivals'], row['stamps']
            count = len(arrivals)
            fps = (count - 1) / (arrivals[-1] - arrivals[0]) if count > 1 else 0
            gaps = [(b - a) * 1e-9 for a, b in zip(stamps, stamps[1:])]
            matched = len(set(stamps) & set(row['info_stamps']))
            valid_info = row['camera_info'].get('width') == 1920 and row['camera_info'].get('height') == 1080
            passed = (count >= 30 and fps >= 25 and gaps and min(gaps) > 0
                      and matched > 0 and valid_info and row['invalid_frames'] == 0
                      and row['wrong_frame_ids'] == 0)
            report['cameras'][name] = {
                'image_count': count, 'received_fps': fps, 'image': row['metadata'],
                'camera_info_count': len(row['info_stamps']), 'camera_info': row['camera_info'],
                'matched_camera_info_stamps': matched, 'max_stamp_gap_seconds': max(gaps, default=0),
                'invalid_frames': row['invalid_frames'], 'wrong_frame_ids': row['wrong_frame_ids'],
                'passed': bool(passed),
            }
        report['passed'] = all(row['passed'] for row in report['cameras'].values())
        result = json.dumps(report, indent=2)
        (out / f'ros-{args.transport}-report.json').write_text(result + '\n')
        print(result)
        return 0 if report['passed'] else 1
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    raise SystemExit(main())
