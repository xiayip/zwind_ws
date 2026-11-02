// SPDX-License-Identifier: Apache-2.0
// Read-only cross-process transport benchmark; no camera/device access.
#include <chrono>
#include <iostream>
#include <array>
#include <thread>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>

int main(int argc,char **argv) {
  const unsigned width=argc>1?std::stoul(argv[1]):1024,height=argc>2?std::stoul(argv[2]):512;
  rclcpp::init(argc,argv);
  auto node=std::make_shared<rclcpp::Node>("panorama_transport_probe");
  using Clock=std::chrono::steady_clock;
  const auto start=Clock::now();std::array<uint64_t,4> counts{};
  std::array<double,4> first{},last{};int64_t last_stamp=-1;int errors=0;
  auto record=[&](int which) {
    const double t=std::chrono::duration<double>(Clock::now()-start).count();
    if(t<2)return;
    if(counts[which]==0)first[which]=t;
    last[which]=t;++counts[which];
  };
  auto qos=rclcpp::SensorDataQoS().keep_last(2);
  auto raw=node->create_subscription<sensor_msgs::msg::Image>("/surround/front/image_raw",qos,
    [&](sensor_msgs::msg::Image::ConstSharedPtr m) {
      const auto stamp=int64_t(m->header.stamp.sec)*1000000000LL+m->header.stamp.nanosec;
      if(stamp<=last_stamp || m->width!=width || m->height!=height || m->encoding!="rgb8")++errors;
      last_stamp=stamp;record(0);
    });
  auto compressed=node->create_subscription<sensor_msgs::msg::CompressedImage>("/surround/front/image_raw/compressed",qos,
    [&](sensor_msgs::msg::CompressedImage::ConstSharedPtr m) {if(m->data.size()<4)++errors;record(1);});
  auto valid=node->create_subscription<sensor_msgs::msg::Image>("/surround/front/valid_mask",qos,
    [&](sensor_msgs::msg::Image::ConstSharedPtr) {record(2);});
  auto owner=node->create_subscription<sensor_msgs::msg::Image>("/surround/front/camera_mask",qos,
    [&](sensor_msgs::msg::Image::ConstSharedPtr) {record(3);});
  while(rclcpp::ok() && Clock::now()-start<std::chrono::seconds(20)) {
    rclcpp::spin_some(node);std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  std::cout<<"{\"duration_s\":20,\"warmup_s\":2,\"consumer\":\"C++ cross-process\",\"fps\":[";
  for(int i=0;i<4;++i) {
    const double fps=counts[i]>1?(counts[i]-1)/(last[i]-first[i]):0;
    std::cout<<(i?",":"")<<fps;if(fps<(i<2?17:1.5))++errors;
  }
  std::cout<<"],\"counts\":[";for(int i=0;i<4;++i)std::cout<<(i?",":"")<<counts[i];
  std::cout<<"],\"errors\":"<<errors<<"}\n";
  rclcpp::shutdown();return errors?1:0;
}
