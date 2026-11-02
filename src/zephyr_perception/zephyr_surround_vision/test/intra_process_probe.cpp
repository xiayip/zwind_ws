// SPDX-License-Identifier: Apache-2.0
#include <chrono>
#include <sstream>
#include <rclcpp/rclcpp.hpp>
#include <rclcpp_components/register_node_macro.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <std_msgs/msg/string.hpp>
namespace zephyr_surround_vision {
class IntraProcessProbe: public rclcpp::Node {
public:
  explicit IntraProcessProbe(const rclcpp::NodeOptions &o):Node("panorama_intra_probe",o) {
    start_=std::chrono::steady_clock::now();
    pub_=create_publisher<std_msgs::msg::String>("/surround/intra_probe_result",10);
    sub_=create_subscription<sensor_msgs::msg::Image>("/surround/front/image_raw",rclcpp::SensorDataQoS().keep_last(2),
      [this](sensor_msgs::msg::Image::ConstSharedPtr m) {
        const auto stamp=int64_t(m->header.stamp.sec)*1000000000LL+m->header.stamp.nanosec;
        if(stamp<=last_stamp_)++errors_;last_stamp_=stamp;
        const double t=std::chrono::duration<double>(std::chrono::steady_clock::now()-start_).count();
        if(t<2 || t>20)return;
        if(!count_)first_=t;last_=t;++count_;
      });
    timer_=create_wall_timer(std::chrono::seconds(1),[this] {
      if(std::chrono::steady_clock::now()-start_<std::chrono::seconds(20))return;
      std::ostringstream s;s<<"{\"consumer\":\"C++ intra-process\",\"frames\":"<<count_
        <<",\"fps\":"<<(count_>1?(count_-1)/(last_-first_):0)<<",\"stamp_errors\":"<<errors_<<"}";
      std_msgs::msg::String msg;msg.data=s.str();pub_->publish(msg);
    });
  }
private:
  std::chrono::steady_clock::time_point start_;
  double first_=0,last_=0;uint64_t count_=0,errors_=0;int64_t last_stamp_=-1;
  rclcpp::Subscription<sensor_msgs::msg::Image>::SharedPtr sub_;
  rclcpp::Publisher<std_msgs::msg::String>::SharedPtr pub_;
  rclcpp::TimerBase::SharedPtr timer_;
};
}
RCLCPP_COMPONENTS_REGISTER_NODE(zephyr_surround_vision::IntraProcessProbe)
