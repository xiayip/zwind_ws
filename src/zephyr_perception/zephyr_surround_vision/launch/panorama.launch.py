"""Pair cameras and C++ panorama in one container; optional built-in LAN preview."""
from pathlib import Path
import shutil
import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import ComposableNodeContainer, LoadComposableNodes
from launch_ros.descriptions import ComposableNode


def compose(context):
    value = lambda key: LaunchConfiguration(key).perform(context)
    view = value('view')
    if view not in ('front', 'back'):
        raise RuntimeError('view must be front or back; full 360/BEV require additional calibration')
    start = value('start_cameras').lower()
    if start not in ('true', 'false'):
        raise RuntimeError('start_cameras must be true or false')
    calibration = Path(value('calibration_file')).expanduser().resolve()
    rig = yaml.safe_load(calibration.read_text())
    pair = rig['pairs'][view]
    nodes = []
    if start == 'true':
        available = {}
        for path in Path('/sys/class/video4linux').glob('video*/name'):
            available.setdefault(path.read_text().strip(), []).append('/dev/' + path.parent.name)
        for name in (pair['from_camera'], pair['to_camera']):
            model = rig['cameras'][name]
            devices = available.get(model['sensor_name'], [])
            if len(devices) != 1 or not Path(devices[0]).is_char_device():
                raise RuntimeError(f'{name}: expected one accessible {model["sensor_name"]}, found {devices}')
            nodes.append(ComposableNode(
                package='zephyr_gmsl_camera', plugin='zephyr_gmsl_camera::GmslCameraNode',
                name='gmsl_camera', namespace='/cameras/' + name,
                parameters=[{'video_device': devices[0], 'camera_name': name,
                             'camera_frame_id': model['optical_frame'], 'camera_info_url': '',
                             'sensor_mode': 1, 'image_size': [1920, 1080],
                             'pixel_format': 'YUYV', 'output_encoding': 'rgb8'}],
                extra_arguments=[{'use_intra_process_comms': True}]))
    actions = []
    port = int(value('preview_port'))
    if port and not 1024 <= port <= 65535:
        raise RuntimeError('preview_port must be 0 or 1024..65535')
    preview = ''
    if port:
        root = Path(value('preview_directory')).expanduser().resolve() / view
        root.mkdir(parents=True, exist_ok=True)
        share = Path(get_package_share_directory('zephyr_surround_vision'))
        shutil.copyfile(share / 'web/index.html', root / 'index.html')
        preview = str(root)
        actions.append(ExecuteProcess(
            cmd=['python3', '-m', 'http.server', str(port), '--bind', value('preview_bind'),
                 '--directory', preview], output='log'))
    params = {'view': view, 'calibration_file': str(calibration), 'preview_directory': preview,
              'seam_mode': value('seam_mode'),
              'output_width': int(value('output_width')), 'output_height': int(value('output_height'))}
    for key in ('rate_hz', 'reference_depth_m', 'max_pair_delta_ms', 'horizontal_fov_deg', 'vertical_fov_deg'):
        params[key] = float(value(key))
    nodes.append(ComposableNode(
        package='zephyr_surround_vision', plugin='zephyr_surround_vision::PanoramaNode',
        name=view, namespace=value('output_namespace'), parameters=[params],
        extra_arguments=[{'use_intra_process_comms': True}]))
    target = value('target_container')
    if target:
        actions.append(LoadComposableNodes(target_container=target, composable_node_descriptions=nodes))
    else:
        actions.append(ComposableNodeContainer(
            name=value('container_name') or 'surround_' + view + '_container', namespace='/', package='zephyr_surround_vision',
            executable='surround_container', composable_node_descriptions=nodes,
            additional_env={'ZEPHYR_OPENCV_THREADS': value('opencv_threads')}, output='screen'))
    return actions


def generate_launch_description():
    share = Path(get_package_share_directory('zephyr_surround_vision'))
    defaults = {
        'view': 'front', 'output_namespace': '/surround', 'container_name': '', 'start_cameras': 'true', 'target_container': '', 'opencv_threads': '4',
        'calibration_file': str(share / 'config/rig_20261028.yaml'),
        'seam_mode': 'adaptive', 'reference_depth_m': '3.0', 'rate_hz': '20.0',
        'max_pair_delta_ms': '25.0', 'output_width': '1024', 'output_height': '512',
        'horizontal_fov_deg': '180.0', 'vertical_fov_deg': '90.0',
        'preview_port': '0', 'preview_bind': '0.0.0.0',
        'preview_directory': str(Path.cwd() / 'log/surround_vision/preview'),
    }
    return LaunchDescription([DeclareLaunchArgument(k, default_value=v) for k, v in defaults.items()]
                             + [OpaqueFunction(function=compose)])
