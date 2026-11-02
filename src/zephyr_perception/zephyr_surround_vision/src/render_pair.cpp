// SPDX-License-Identifier: Apache-2.0
#include "zephyr_surround_vision/pair_renderer.hpp"
#include <filesystem>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <opencv2/imgcodecs.hpp>
#include <opencv2/imgproc.hpp>
int main(int argc,char **argv) {
  if(argc<6 || argc>11) {
    std::cerr<<"Usage: render_pair RIG.yaml front|back A.png B.png OUTPUT_DIR [fixed|adaptive|parallax|primary_a|depth_seam]"
      " [sphere_depth_m;0=infinity] [benchmark_frames;1..300] [depth_core_deg] [depth_band_deg]\n";return 2;
  }
  try {
    using namespace zephyr_surround_vision;
    cv::setNumThreads(4);
    auto c=loadCalibration(argv[1],argv[2]);RenderOptions o;
    if(argc>6)o.seam_mode=argv[6];
    if(argc>7)o.reference_depth_m=std::stod(argv[7]);
    if(argc>9)o.depth_core_deg=std::stod(argv[9]);
    if(argc>10)o.depth_band_deg=std::stod(argv[10]);
    const auto construct=cv::getTickCount();
    PairRenderer renderer(c,o);
    const double construct_ms=(cv::getTickCount()-construct)*1000./cv::getTickFrequency();
    cv::Mat a,b;
    cv::cvtColor(cv::imread(argv[3]),a,cv::COLOR_BGR2RGB);cv::cvtColor(cv::imread(argv[4]),b,cv::COLOR_BGR2RGB);
    const int frames=argc>8?std::stoi(argv[8]):1;
    if(frames<1 || frames>300)throw std::invalid_argument("benchmark_frames must be 1..300");
    RenderResult result;std::vector<double> times;double total=0,update_total=0;int updates=0;
    // Emulate the default 20 Hz image / 2 Hz seam cadence, without ROS transport or JPEG costs.
    for(int i=0;i<frames;++i) {
      const auto begin=cv::getTickCount();result=renderer.render(a,b,i%10==0);
      const double ms=(cv::getTickCount()-begin)*1000./cv::getTickFrequency();times.push_back(ms);total+=ms;
      if(i%10==0) {update_total+=ms;++updates;}
    }
    const double render_ms=times.front();std::sort(times.begin(),times.end());
    const std::filesystem::path out(argv[5]);std::filesystem::create_directories(out);
    const auto warped=renderer.projectInputs(a,b);
    for(int i=0;i<2;++i) {cv::Mat tmp;cv::cvtColor(warped[i],tmp,cv::COLOR_RGB2BGR);
      cv::imwrite((out/(i==0?"projected_a.jpg":"projected_b.jpg")).string(),tmp);}
    cv::Mat bgr;cv::cvtColor(result.image,bgr,cv::COLOR_RGB2BGR);
    cv::imwrite((out/"panorama.jpg").string(),bgr,{cv::IMWRITE_JPEG_QUALITY,94});
    for(int y=0;y<bgr.rows-1;++y)cv::line(bgr,{int(result.seam[y]),y},{int(result.seam[y+1]),y+1},{0,220,255},2);
    cv::imwrite((out/"debug.jpg").string(),bgr,{cv::IMWRITE_JPEG_QUALITY,94});
    cv::imwrite((out/"valid_mask.png").string(),result.valid_mask);cv::imwrite((out/"camera_mask.png").string(),result.owner);
    {
      std::ofstream csv(out/"seam.csv");csv<<"row,seam_px,inverse_depth\n";
      for(size_t y=0;y<result.seam.size();++y)
        csv<<y<<','<<result.seam[y]<<','<<(result.seam_inverse_depth.empty()?std::nan(""):result.seam_inverse_depth[y])<<'\n';
    }
    double depth_min=0,depth_median=0,depth_max=0;
    if(!result.seam_inverse_depth.empty()) {
      // Inverse depth -> metres; 0 (or beyond infinity) reports as 0 = infinity.
      auto rho=result.seam_inverse_depth;std::sort(rho.begin(),rho.end());
      const auto metres=[](float r) {return r>1e-3f?1./r:0.;};
      depth_min=metres(rho.back());depth_median=metres(rho[rho.size()/2]);depth_max=metres(rho.front());
      cv::Mat depth=renderer.depthMap(),visual(depth.size(),CV_8UC3,cv::Scalar(0,0,0));
      for(int y=0;y<depth.rows;++y)for(int x=0;x<depth.cols;++x) {
        const float r=depth.at<float>(y,x);
        if(!std::isnan(r))visual.at<cv::Vec3b>(y,x)=cv::Vec3b(0,0,cv::saturate_cast<unsigned char>(r*100));
      }
      cv::Mat colored;cv::applyColorMap(visual,colored,cv::COLORMAP_TURBO);
      for(int y=0;y<depth.rows;++y)for(int x=0;x<depth.cols;++x)if(std::isnan(depth.at<float>(y,x)))colored.at<cv::Vec3b>(y,x)={0,0,0};
      cv::resize(colored,colored,result.image.size(),0,0,cv::INTER_NEAREST);
      for(int y=0;y<colored.rows-1;++y)cv::line(colored,{int(result.seam[y]),y},{int(result.seam[y+1]),y+1},{255,255,255},1);
      cv::imwrite((out/"depth.png").string(),colored);
    }
    const auto minmax=std::minmax_element(result.seam.begin(),result.seam.end());
    std::cout<<"{\"adaptive_seam\":"<<(result.adaptive_seam?"true":"false")<<",\"seam_min_px\":"<<*minmax.first
      <<",\"render_ms\":"<<render_ms<<",\"construct_ms\":"<<construct_ms<<",\"correspondence_count\":"<<result.correspondence_count
      <<",\"benchmark_frames\":"<<frames<<",\"benchmark_mean_ms\":"<<total/frames
      <<",\"benchmark_p95_ms\":"<<times[std::min(frames-1,int(frames*.95))]
      <<",\"benchmark_update_mean_ms\":"<<update_total/updates
      <<",\"benchmark_other_mean_ms\":"<<(frames>updates?(total-update_total)/(frames-updates):0.)
      <<",\"benchmark_seam_every_n_frames\":10"
      <<",\"parallax_guard\":"<<(result.parallax_guard?"true":"false")
      <<",\"seam_conflict_fraction\":"<<result.seam_conflict_fraction
      <<",\"depth_valid_fraction\":"<<result.depth_valid_fraction
      <<",\"seam_depth_min_m\":"<<depth_min<<",\"seam_depth_median_m\":"<<depth_median<<",\"seam_depth_max_m\":"<<depth_max
      <<",\"seam_max_px\":"<<*minmax.second<<",\"gain_b\":"<<result.gain<<"}\n";
    return 0;
  } catch(const std::exception &e) {std::cerr<<e.what()<<'\n';return 1;}
}
