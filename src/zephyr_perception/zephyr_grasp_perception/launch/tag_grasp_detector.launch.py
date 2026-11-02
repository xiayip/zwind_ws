from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def generate_launch_description():
    params_file = LaunchConfiguration('params_file')
    return LaunchDescription([
        DeclareLaunchArgument(
            'params_file',
            default_value=PathJoinSubstitution(
                [FindPackageShare('zephyr_grasp_perception'), 'config', 'tag_grasp_detector.yaml'])),
        Node(
            package='zephyr_grasp_perception',
            executable='tag_grasp_detector',
            name='tag_grasp_detector',
            parameters=[params_file],
            output='screen'),
    ])
