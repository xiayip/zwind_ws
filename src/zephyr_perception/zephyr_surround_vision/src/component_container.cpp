// SPDX-License-Identifier: Apache-2.0
#include <cstdlib>
#include <iostream>
#include <opencv2/core.hpp>
#include <rclcpp/rclcpp.hpp>
#include <rclcpp_components/component_manager.hpp>

int main(int argc,char **argv) {
  try {
    // Set the process-wide TBB/OpenCV limit before any camera or renderer starts.
    // Calling setNumThreads from an already loaded component would race other
    // components' OpenCV work, so it belongs at container initialization only.
    const char *setting=std::getenv("ZEPHYR_OPENCV_THREADS");
    const int threads=setting?std::stoi(setting):4;
    if(threads<1 || threads>32)throw std::invalid_argument("ZEPHYR_OPENCV_THREADS must be 1..32");
    cv::setNumThreads(threads);
    rclcpp::init(argc,argv);
    auto executor=std::make_shared<rclcpp::executors::MultiThreadedExecutor>(rclcpp::ExecutorOptions(),4);
    auto manager=std::make_shared<rclcpp_components::ComponentManager>(executor,"surround_container");
    executor->add_node(manager);
    RCLCPP_INFO(manager->get_logger(),"OpenCV workers=%d, ROS executor threads=4",cv::getNumThreads());
    executor->spin();executor->remove_node(manager);manager.reset();rclcpp::shutdown();return 0;
  }catch(const std::exception &e) {std::cerr<<e.what()<<'\n';return 1;}
}
