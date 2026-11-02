// SPDX-License-Identifier: Apache-2.0
#include "zephyr_surround_vision/pair_renderer.hpp"
#include "zephyr_surround_vision/pair_buffer.hpp"
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <regex>
#include <sstream>
#include <rclcpp/rclcpp.hpp>
#include <rclcpp_components/register_node_macro.hpp>
#include <rcl_interfaces/msg/parameter_descriptor.hpp>
#include <image_transport/image_transport.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <std_msgs/msg/string.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgcodecs.hpp>

namespace zephyr_surround_vision {
namespace {
using Image=sensor_msgs::msg::Image;
int64_t steadyNs() {return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();}
int64_t stampNs(const Image &m) {return int64_t(m.header.stamp.sec)*1000000000LL+m.header.stamp.nanosec;}
std::unique_ptr<Image> message(const cv::Mat &im,const std_msgs::msg::Header &header,const std::string &encoding) {
  auto m=std::make_unique<Image>();m->header=header;m->height=im.rows;m->width=im.cols;
  m->encoding=encoding;m->is_bigendian=false;m->step=im.cols*im.elemSize();
  m->data.resize(size_t(m->step)*m->height);
  for(int row=0;row<im.rows;++row)std::memcpy(m->data.data()+size_t(row)*m->step,im.ptr(row),m->step);
  return m;
}
}

class PanoramaNode: public rclcpp::Node {
public:
  explicit PanoramaNode(const rclcpp::NodeOptions &options):Node("front",options) {
    const auto view=param<std::string>("view","front");
    if(view!="front" && view!="back")throw std::invalid_argument("Only front/back pair panoramas are implemented; full 360 and BEV require additional calibration");
    auto calibration=loadCalibration(param<std::string>("calibration_file",""),view);
    RenderOptions o;
    o.width=param<int>("output_width",1024);o.height=param<int>("output_height",512);
    o.horizontal_fov_deg=param<double>("horizontal_fov_deg",180.);o.vertical_fov_deg=param<double>("vertical_fov_deg",90.);
    o.reference_depth_m=param<double>("reference_depth_m",3.);
    o.seam_mode=param<std::string>("seam_mode","adaptive");o.feather_px=param<double>("feather_px",10.);
    o.seam_search_deg=param<double>("seam_search_deg",70.);
    o.exposure_compensation=param<bool>("exposure_compensation",true);
    render_options_=o;view_=view;
    renderer_=std::make_unique<PairRenderer>(calibration,o);
    const double rate=param<double>("rate_hz",20.),seam_rate=param<double>("seam_update_hz",2.);
    const double spread=param<double>("max_pair_delta_ms",25.),age=param<double>("max_input_age_ms",250.);
    if(!std::isfinite(rate) || rate<=0 || rate>60 || !std::isfinite(seam_rate) || seam_rate<=0 || seam_rate>rate ||
      !std::isfinite(spread) || spread<=0 || spread>100 || !std::isfinite(age) || age<=spread || age>2000)
      throw std::invalid_argument("Invalid rates or pairing/age limits");
    pair_tolerance_=int64_t(spread*1e6);max_age_=int64_t(age*1e6);seam_period_=int64_t(1e9/seam_rate);
    const double mask_rate=param<double>("mask_rate_hz",2.);
    if(!std::isfinite(mask_rate) || mask_rate<=0 || mask_rate>rate)throw std::invalid_argument("mask_rate_hz must be positive and <= rate_hz");
    mask_period_=int64_t(1e9/mask_rate);
    preview_dir_=param<std::string>("preview_directory","");
    if(!preview_dir_.empty())std::filesystem::create_directories(preview_dir_);
    frame_=view+"_panorama_optical_frame";
    auto qos=rmw_qos_profile_sensor_data;qos.depth=2;
    image_pub_=image_transport::create_publisher(this,std::string(get_fully_qualified_name())+"/image_raw",qos);
    valid_pub_=create_publisher<Image>("~/valid_mask",rclcpp::SensorDataQoS().keep_last(1));
    owner_pub_=create_publisher<Image>("~/camera_mask",rclcpp::SensorDataQoS().keep_last(1));
    debug_pub_=create_publisher<Image>("~/debug/image_raw",rclcpp::SensorDataQoS().keep_last(1));
    status_pub_=create_publisher<std_msgs::msg::String>("~/status",rclcpp::QoS(1));
    input_group_=create_callback_group(rclcpp::CallbackGroupType::MutuallyExclusive);
    rclcpp::SubscriptionOptions sub_options;sub_options.callback_group=input_group_;
    for(int i=0;i<2;++i) {
      const auto &c=calibration.cameras[i];
      if(!std::regex_match(c.name,std::regex("[a-zA-Z][a-zA-Z0-9_]*")))throw std::invalid_argument("Invalid camera name");
      const auto topic=param<std::string>(i==0?"input_a":"input_b","/cameras/"+c.name+"/image_raw");
      subscriptions_[i]=create_subscription<Image>(topic,rclcpp::SensorDataQoS().keep_last(3),
        [this,i](Image::ConstSharedPtr m) {onImage(i,std::move(m));},sub_options);
      RCLCPP_INFO(get_logger(),"Input %d: %s (%s)",i,topic.c_str(),c.name.c_str());
    }
    last_status_=steadyNs();
    timer_=create_wall_timer(std::chrono::nanoseconds(int64_t(1e9/rate)),[this] {tick();});
    RCLCPP_INFO(get_logger(),"%s panorama %dx%d %.0fx%.0f deg, CPU LUT renderer, seam=%s; calibration=%s",
      view.c_str(),o.width,o.height,o.horizontal_fov_deg,o.vertical_fov_deg,o.seam_mode.c_str(),calibration.status.c_str());
  }
private:
  template<class T>T param(const std::string &name,T initial) {
    rcl_interfaces::msg::ParameterDescriptor descriptor;descriptor.read_only=true;
    return declare_parameter<T>(name,initial,descriptor);
  }
  void onImage(int i,Image::ConstSharedPtr m) {
    const auto &c=renderer_->calibration();
    const bool valid=m->width==unsigned(c.input_size.width) && m->height==unsigned(c.input_size.height) &&
      (m->encoding=="rgb8" || m->encoding=="bgr8") && m->step>=m->width*3 &&
      m->data.size()>=size_t(m->step)*m->height && m->header.frame_id==c.cameras[i].frame;
    std::lock_guard<std::mutex> lock(mutex_);
    if(!valid) {++invalid_inputs_;return;}
    const auto stamp=stampNs(*m),now=steadyNs();
    if(last_stamp_[i]>stamp && last_stamp_[i]-stamp>1000000000LL) {buffer_.clear();last_stamp_={};}
    if(!buffer_.push(i,stamp,now,std::move(m))) {++out_of_order_;return;}
    last_stamp_[i]=stamp;last_received_[i]=now;
  }
  void tick() {
    const auto start=steadyNs();
    std::optional<std::array<PairBuffer<Image::ConstSharedPtr>::Item,2>> pair;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      pair=buffer_.take(start,max_age_,pair_tolerance_);
    }
    std::string state="waiting_for_matched_frames";
    if(pair) {
      try {
        std::array<cv::Mat,2> rgb;
        for(int i=0;i<2;++i) {
          const auto &m=*(*pair)[i].payload;
          cv::Mat source(m.height,m.width,CV_8UC3,const_cast<unsigned char*>(m.data.data()),m.step);
          if(m.encoding=="bgr8")cv::cvtColor(source,rgb[i],cv::COLOR_BGR2RGB);else rgb[i]=source;
        }
        auto result=renderer_->render(rgb[0],rgb[1],start-last_seam_>=seam_period_);
        if(start-last_seam_>=seam_period_)last_seam_=start;
        auto header=(*pair)[0].stamp>=(*pair)[1].stamp?(*pair)[0].payload->header:(*pair)[1].payload->header;
        header.frame_id=frame_;
        image_pub_.publish(message(result.image,header,"rgb8"));
        if(start-last_masks_>=mask_period_) {
          if(valid_pub_->get_subscription_count())valid_pub_->publish(message(result.valid_mask,header,"mono8"));
          if(owner_pub_->get_subscription_count())owner_pub_->publish(message(result.owner,header,"mono8"));
          last_masks_=start;
        }
        cv::Mat debug;
        const bool preview_due=!preview_dir_.empty() && start-last_preview_>=1000000000LL;
        if(debug_pub_->get_subscription_count() || preview_due) {
          debug=result.image.clone();
          for(int y=0;y<debug.rows-1;++y)cv::line(debug,{int(result.seam[y]),y},{int(result.seam[y+1]),y+1},{255,220,0},2);
          cv::putText(debug,view_+" | "+render_options_.seam_mode+" seam | assumed depth "+std::to_string(render_options_.reference_depth_m).substr(0,4)+"m",
            {12,26},cv::FONT_HERSHEY_SIMPLEX,.6,{255,255,0},1,cv::LINE_AA);
          if(debug_pub_->get_subscription_count())debug_pub_->publish(message(debug,header,"rgb8"));
        }
        if(preview_due) {
          last_preview_=start;
          savePreview(result.image,"panorama.jpg");savePreview(debug,"debug.jpg");
        }
        render_ms_=(steadyNs()-start)/1e6;
        pair_delta_ms_=std::abs((*pair)[0].stamp-(*pair)[1].stamp)/1e6;
        input_age_ms_=(start-std::min((*pair)[0].received,(*pair)[1].received))/1e6;
        pair_stamps_={(*pair)[0].stamp,(*pair)[1].stamp};gain_=result.gain;adaptive_=result.adaptive_seam;
        correspondences_=result.correspondence_count;guard_=result.parallax_guard;conflict_=result.seam_conflict_fraction;
        ++published_;++window_published_;last_output_=start;state="running";
      } catch(const std::exception &e) {
        ++render_errors_;state="render_error";RCLCPP_ERROR_THROTTLE(get_logger(),*get_clock(),5000,"Render failed: %s",e.what());
      }
    } else if(last_output_ && start-last_output_<max_age_)state="running";
    if(start-last_status_>=1000000000LL)publishStatus(start,state);
  }
  void savePreview(const cv::Mat &rgb,const std::string &filename) {
    // Preview is optional and must not interrupt ROS output on disk errors.
    try {
      cv::Mat bgr;cv::cvtColor(rgb,bgr,cv::COLOR_RGB2BGR);
      const auto dest=std::filesystem::path(preview_dir_)/filename;
      const auto tmp=std::filesystem::path(preview_dir_)/("tmp_"+filename);
      if(!cv::imwrite(tmp.string(),bgr,{cv::IMWRITE_JPEG_QUALITY,85}))throw std::runtime_error("JPEG write failed");
      std::filesystem::rename(tmp,dest);
    }catch(const std::exception &e) {RCLCPP_WARN_THROTTLE(get_logger(),*get_clock(),10000,"Preview write failed: %s",e.what());}
  }
  void publishStatus(int64_t now,std::string state) {
    uint64_t invalid,order;std::array<int64_t,2> received;
    {std::lock_guard<std::mutex> lock(mutex_);invalid=invalid_inputs_;order=out_of_order_;received=last_received_;}
    if(!received[0] || !received[1] || now-std::min(received[0],received[1])>max_age_)state="stale_or_missing_input";
    const double fps=window_published_*1e9/(now-last_status_);
    std::ostringstream s;s<<std::fixed<<std::setprecision(3);
    s<<"{\"state\":\""<<state<<"\",\"view\":\""<<view_<<"\",\"backend\":\"cpu\",\"fps\":"<<fps
      <<",\"published\":"<<published_<<",\"render_ms\":"<<render_ms_<<",\"pair_delta_ms\":"<<pair_delta_ms_
      <<",\"oldest_input_age_at_render_ms\":"<<input_age_ms_<<",\"source_stamps_ns\":[\""<<pair_stamps_[0]<<"\",\""<<pair_stamps_[1]<<"\"]"
      <<",\"invalid_inputs\":"<<invalid<<",\"out_of_order\":"<<order<<",\"render_errors\":"<<render_errors_
      <<",\"gain_b\":"<<gain_<<",\"adaptive_seam\":"<<(adaptive_?"true":"false")
      <<",\"seam_mode\":\""<<render_options_.seam_mode<<"\",\"parallax_guard\":"<<(guard_?"true":"false")
      <<",\"correspondence_count\":"<<correspondences_<<",\"seam_conflict_fraction\":"<<conflict_
      <<",\"projection\":\"equirectangular\",\"output_width\":"<<render_options_.width<<",\"output_height\":"<<render_options_.height
      <<",\"horizontal_fov_deg\":"<<render_options_.horizontal_fov_deg
      <<",\"vertical_fov_deg\":"<<render_options_.vertical_fov_deg<<",\"reference_depth_m\":"<<render_options_.reference_depth_m
      <<",\"opencv_threads\":"<<cv::getNumThreads()<<",\"mask_rate_hz\":"<<1e9/mask_period_
      <<",\"hardware_sync_verified\":false,\"metric_bev\":false,\"calibration_status\":\""<<renderer_->calibration().status<<"\"}";
    std_msgs::msg::String msg;msg.data=s.str();status_pub_->publish(msg);
    if(!preview_dir_.empty()) {
      try {
        const auto p=std::filesystem::path(preview_dir_);std::ofstream f(p/"status.json.tmp");f<<msg.data;f.close();
        if(f.fail())throw std::runtime_error("status write failed");
        std::filesystem::rename(p/"status.json.tmp",p/"status.json");
      }catch(const std::exception &e) {RCLCPP_WARN_THROTTLE(get_logger(),*get_clock(),10000,"Status preview failed: %s",e.what());}
    }
    window_published_=0;last_status_=now;
  }
  std::unique_ptr<PairRenderer> renderer_;
  RenderOptions render_options_;
  std::string view_,frame_,preview_dir_;
  std::mutex mutex_;
  PairBuffer<Image::ConstSharedPtr> buffer_;
  std::array<int64_t,2> last_stamp_{},last_received_{},pair_stamps_{};
  std::array<rclcpp::Subscription<Image>::SharedPtr,2> subscriptions_;
  rclcpp::CallbackGroup::SharedPtr input_group_;
  image_transport::Publisher image_pub_;
  rclcpp::Publisher<Image>::SharedPtr valid_pub_,owner_pub_,debug_pub_;
  rclcpp::Publisher<std_msgs::msg::String>::SharedPtr status_pub_;
  rclcpp::TimerBase::SharedPtr timer_;
  int64_t pair_tolerance_=0,max_age_=0,seam_period_=0,last_seam_=0,last_status_=0,last_preview_=0,last_output_=0;
  int64_t mask_period_=0,last_masks_=0;
  uint64_t invalid_inputs_=0,out_of_order_=0,published_=0,window_published_=0,render_errors_=0;
  double render_ms_=0,pair_delta_ms_=0,input_age_ms_=0,gain_=1;
  bool adaptive_=false,guard_=false;
  int correspondences_=0;
  double conflict_=0;
};
}
RCLCPP_COMPONENTS_REGISTER_NODE(zephyr_surround_vision::PanoramaNode)
