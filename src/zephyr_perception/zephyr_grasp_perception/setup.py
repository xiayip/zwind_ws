from glob import glob

from setuptools import find_packages, setup

package_name = 'zephyr_grasp_perception'

setup(
    name=package_name,
    version='0.1.0',
    packages=find_packages(exclude=['test']),
    data_files=[
        ('share/ament_index/resource_index/packages', ['resource/' + package_name]),
        ('share/' + package_name, ['package.xml']),
        ('share/' + package_name + '/config', glob('config/*.yaml')),
        ('share/' + package_name + '/launch', glob('launch/*.launch.py')),
    ],
    zip_safe=True,
    maintainer='Zephyr Robotics',
    maintainer_email='yipeng.xia@hotmail.com',
    description='Wrist-camera grasp perception: AprilTag on a soft strap handle to a top-down grasp pose',
    entry_points={
        'console_scripts': [
            'tag_grasp_detector = zephyr_grasp_perception.tag_grasp_detector:main',
        ],
    },
)
