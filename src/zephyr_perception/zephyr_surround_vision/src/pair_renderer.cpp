// SPDX-License-Identifier: Apache-2.0
#include "zephyr_surround_vision/pair_renderer.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>
#include <yaml-cpp/yaml.h>
#include <opencv2/imgproc.hpp>
#include <opencv2/features2d.hpp>

namespace zephyr_surround_vision {
namespace {
constexpr double pi=3.14159265358979323846;
void require(bool condition, const std::string &message) {
  if (!condition) throw std::invalid_argument(message);
}
cv::Vec3d unit(cv::Vec3d v) {
  const double n=cv::norm(v);
  require(n>1e-8 && std::isfinite(n), "Degenerate virtual camera axes");
  return v/n;
}
void requireInputs(const PairCalibration &c,const cv::Mat &a,const cv::Mat &b) {
  require(a.size()==c.input_size && b.size()==c.input_size && a.type()==CV_8UC3 && b.type()==CV_8UC3,
    "Expected RGB8 images at the calibrated resolution; resize/crop must update the calibration");
}
// Panorama ray through pixel (col,row) of an equirectangular grid of the given size, in camera A.
cv::Vec3d viewRay(const cv::Matx33d &basis,const RenderOptions &o,double col,double row,cv::Size size) {
  const double lon=((col+.5)/size.width-.5)*o.horizontal_fov_deg*pi/180;
  const double lat=((row+.5)/size.height-.5)*o.vertical_fov_deg*pi/180;
  return basis*cv::Vec3d(std::sin(lon)*std::cos(lat),std::sin(lat),std::cos(lon)*std::cos(lat));
}
// depth_seam sweep: 7x7 ZNCC windows; flat windows and windows outside either view are not matched.
constexpr int kSweepRadius=3;
constexpr float kFlatSigma=.015f, kMaxCost=.4f, kMinMargin=.05f, kFlat=3, kOutside=4;
// Windows must also have gradient across the (near horizontal) epipolar direction: RMS and its share
// of the vertical gradient energy (0.25 = edges at least 27 degrees from horizontal).
constexpr float kMinEpipolarGradient=.01f, kMinEpipolarShare=.25f;
// Seam depth profile: cost aggregated over a grid window following the seam, then a scanline
// optimisation along it. P1 lets the depth follow slanted surfaces, P2 is the price of a depth edge.
constexpr int kProfileX=3, kProfileY=1;
constexpr float kProfileP1=.05f, kProfileP2=.4f;
// Largest local compression of the displayed image in the depth band, and the widest ramp.
constexpr double kMaxCompression=.5, kMaxRampDeg=60;
// Largest change of the band shift, in output pixels per output row.
constexpr double kMaxShear=1;
}

PairCalibration loadCalibration(const std::string &file, const std::string &view) {
  const auto root=YAML::LoadFile(file);
  require(root["schema_version"].as<int>()==1, "Unsupported rig schema");
  require(root["model"].as<std::string>()=="KB4_atan2_full_angle", "Expected full-angle KB4 calibration");
  const auto pair=root["pairs"][view];
  require(pair && pair.IsMap(), "No calibrated pair for view: "+view+" (360/BEV not yet supported)");
  PairCalibration c;
  c.status=root["status"].as<std::string>();
  require(!c.status.empty() && c.status.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")==std::string::npos,
    "Invalid calibration status label");
  c.input_size={root["image_size"][0].as<int>(),root["image_size"][1].as<int>()};
  require(c.input_size.width>0 && c.input_size.height>0, "Invalid calibration dimensions");
  const std::array<std::string,2> names={pair["from_camera"].as<std::string>(),pair["to_camera"].as<std::string>()};
  require(names[0]!=names[1], "Pair cameras must differ");
  for (int i=0;i<2;++i) {
    auto &m=c.cameras[i];const auto n=root["cameras"][names[i]];
    m.name=names[i];m.frame=n["optical_frame"].as<std::string>();m.sensor=n["sensor_name"].as<std::string>();
    require(n["intrinsics"].size()==8,"Expected 8 KB4 coefficients");
    for(int j=0;j<8;++j) {
      m.k[j]=n["intrinsics"][j].as<double>();require(std::isfinite(m.k[j]),"Nonfinite intrinsic");
    }
    require(m.k[0]>0 && m.k[1]>0,"Focal lengths must be positive");
    for(int deg=0;deg<=100;++deg) {
      const double theta=deg*pi/180;double derivative=1;
      for(int k=0;k<4;++k) derivative+=(2*k+3)*m.k[4+k]*std::pow(theta,2*k+2);
      require(derivative>0,"KB4 is not monotone within the renderer's 100 degree ray limit");
    }
  }
  const auto t=pair["T_to_from"];require(t.size()==4,"Expected 4x4 T_to_from");
  for(int row=0;row<4;++row) {
    require(t[row].size()==4,"Expected 4x4 T_to_from");
    for(int col=0;col<4;++col) {
      const double v=t[row][col].as<double>();require(std::isfinite(v),"Nonfinite transform");
      if(row<3 && col<3)c.rotation(row,col)=v;
      else if(row<3)c.translation[row]=v;
      else require(std::abs(v-(col==3?1.:0.))<1e-8,"Invalid homogeneous last row");
    }
  }
  require(cv::norm(cv::Mat(c.rotation*c.rotation.t()-cv::Matx33d::eye()))<1e-5 &&
    std::abs(cv::determinant(cv::Mat(c.rotation))-1)<1e-5,"Rotation must be right-handed and orthonormal");
  return c;
}

cv::Point2d projectKB4(const cv::Vec3d &v,const std::array<double,8> &k) {
  const double r=std::hypot(v[0],v[1]);
  if(r<1e-12) {
    if(v[2]>0)return {k[2],k[3]};
    return {std::numeric_limits<double>::quiet_NaN(),std::numeric_limits<double>::quiet_NaN()};
  }
  const double theta=std::atan2(r,v[2]),t2=theta*theta;
  const double rho=theta*(1+t2*(k[4]+t2*(k[5]+t2*(k[6]+t2*k[7]))));
  return {k[0]*v[0]*rho/r+k[2],k[1]*v[1]*rho/r+k[3]};
}

PairRenderer::PairRenderer(PairCalibration c,RenderOptions o):calibration_(std::move(c)),options_(std::move(o)) {
  require(options_.width>=64 && options_.width<=4096 && options_.height>=64 && options_.height<=2048,"Invalid output dimensions");
  require(options_.horizontal_fov_deg>=30 && options_.horizontal_fov_deg<=220 &&
    options_.vertical_fov_deg>=20 && options_.vertical_fov_deg<=140,"Invalid pair panorama field of view");
  require(std::isfinite(options_.reference_depth_m) && options_.reference_depth_m>=0,"Invalid reference depth");
  require(options_.reference_depth_m==0 || options_.reference_depth_m>cv::norm(calibration_.translation)/2+.05,
    "Reference sphere must enclose both cameras with a margin");
  require(options_.seam_mode=="fixed" || options_.seam_mode=="adaptive" || options_.seam_mode=="parallax" ||
    options_.seam_mode=="primary_a" || options_.seam_mode=="depth_seam",
    "seam_mode must be fixed, adaptive, parallax, primary_a or depth_seam");
  if(options_.seam_mode=="depth_seam") {
    const double baseline=cv::norm(calibration_.translation);
    require(baseline>.05,"depth_seam needs a calibrated baseline");
    require(std::isfinite(options_.min_depth_m) && options_.min_depth_m>baseline/2+.05 && options_.min_depth_m<=20,
      "min_depth_m must enclose both cameras and be at most 20 m");
    require(std::isfinite(options_.depth_core_deg) && std::isfinite(options_.depth_band_deg) && options_.depth_core_deg>=0 &&
      options_.depth_band_deg>0 && options_.depth_core_deg+options_.depth_band_deg<=options_.horizontal_fov_deg/2,
      "Invalid depth seam band");
  }
  require(options_.seam_search_deg>0 && options_.seam_search_deg<=options_.horizontal_fov_deg,"Invalid seam search angle");
  require(std::isfinite(options_.feather_px) && options_.feather_px>=0 && options_.feather_px<=100,"Invalid feather width");
  const auto &R=calibration_.rotation;
  const auto z=unit(cv::Vec3d(0,0,1)+R.t()*cv::Vec3d(0,0,1));
  auto y=cv::Vec3d(0,1,0)+R.t()*cv::Vec3d(0,1,0);y=unit(y-z*y.dot(z));
  const auto x=unit(y.cross(z));y=z.cross(x);
  basis_={x[0],y[0],z[0],x[1],y[1],z[1],x[2],y[2],z[2]};
  const auto axis_a=basis_.t()*cv::Vec3d(0,0,1),axis_b=basis_.t()*R.t()*cv::Vec3d(0,0,1);
  a_left_=std::atan2(axis_a[0],axis_a[2])<std::atan2(axis_b[0],axis_b[2]);
  const auto midpoint=-(R.t()*calibration_.translation)*.5;
  std::array<cv::Mat,2> mx,my;
  for(int i=0;i<2;++i) {
    mx[i]=cv::Mat(options_.height,options_.width,CV_32F,cv::Scalar(-1));my[i]=mx[i].clone();
    masks_[i]=cv::Mat::zeros(options_.height,options_.width,CV_8U);
  }
  for(int row=0;row<options_.height;++row)for(int col=0;col<options_.width;++col) {
    const double lon=((col+.5)/options_.width-.5)*options_.horizontal_fov_deg*pi/180;
    const double lat=((row+.5)/options_.height-.5)*options_.vertical_fov_deg*pi/180;
    const auto direction=basis_*cv::Vec3d(std::sin(lon)*std::cos(lat),std::sin(lat),std::cos(lon)*std::cos(lat));
    const auto va=options_.reference_depth_m==0?direction:direction*options_.reference_depth_m+midpoint;
    const auto vb=options_.reference_depth_m==0?R*va:R*va+calibration_.translation;
    for(int i=0;i<2;++i) {
      const auto v=i==0?va:vb;const auto p=projectKB4(v,calibration_.cameras[i].k);
      const double angle=std::atan2(std::hypot(v[0],v[1]),v[2]);
      if(p.x>=1 && p.y>=1 && p.x<calibration_.input_size.width-2 && p.y<calibration_.input_size.height-2 && angle<100*pi/180) {
        mx[i].at<float>(row,col)=static_cast<float>(p.x);my[i].at<float>(row,col)=static_cast<float>(p.y);
        masks_[i].at<unsigned char>(row,col)=255;
      }
    }
  }
  for(int i=0;i<2;++i)cv::convertMaps(mx[i],my[i],maps1_[i],maps2_[i],CV_16SC2);
  cv::bitwise_or(masks_[0],masks_[1],valid_);
  const cv::Size small(std::min(320,options_.width),std::max(32,options_.height*std::min(320,options_.width)/options_.width));
  cv::resize(masks_[0],small_mask_a_,small,0,0,cv::INTER_NEAREST);
  cv::resize(masks_[1],small_mask_b_,small,0,0,cv::INTER_NEAREST);
  seam_.assign(options_.height,options_.width*.5f);
  seam_risk_=cv::Mat::zeros(small,CV_32F);
  if(options_.seam_mode=="depth_seam") {
    for(int i=0;i<2;++i) {
      depth_.base_x[i]=mx[i].clone();depth_.base_y[i]=my[i].clone();depth_.base_mask[i]=masks_[i].clone();
      depth_.map_x[i]=mx[i];depth_.map_y[i]=my[i];
    }
    buildDepthSweep();
  }
  if(options_.seam_mode=="primary_a") {
    // Keep the principal viewing region from one physical camera. Relocate the
    // source transition toward the side, limited by coverage and the search angle.
    // This does not solve parallax at the relocated transition.
    cv::Mat preferred=masks_[0].clone();
    const int side=std::clamp(int(options_.width*(.5+(a_left_?1.:-1.)*
      options_.seam_search_deg/options_.horizontal_fov_deg/2)),0,options_.width);
    if(a_left_ && side<options_.width)preferred.colRange(side,options_.width).setTo(0);
    if(!a_left_ && side>0)preferred.colRange(0,side).setTo(0);
    if(options_.feather_px>0) {
      cv::distanceTransform(preferred,primary_weight_,cv::DIST_L2,3);
      primary_weight_/=options_.feather_px;
      cv::min(primary_weight_,1.,primary_weight_);
    }else preferred.convertTo(primary_weight_,CV_32F,1./255.);
    for(int y=0;y<options_.height;++y) {
      for(int step=0;step<options_.width;++step) {
        const int x=a_left_?options_.width-1-step:step;
        if(primary_weight_.at<float>(y,x)>=.5f) {seam_[y]=float(x);break;}
      }
    }
  }
}

void PairRenderer::updateParallaxGuard(const cv::Mat &a,const cv::Mat &b) {
  seam_risk_.setTo(0);correspondence_count_=0;parallax_guard_=false;
  if(options_.seam_mode!="parallax")return;
  // Feature ownership, not a geometric warp: never invent pixels or move objects.
  // A cut between the two projections of one feature deletes it or retains it twice.
  const int w=std::min(640,options_.width),h=options_.height*w/options_.width;
  const cv::Size size(w,h);
  std::array<cv::Mat,2> gray,mask,desc;
  std::array<std::vector<cv::KeyPoint>,2> keys;
  const auto detector=cv::ORB::create(800,1.2f,4,31,0,2,cv::ORB::HARRIS_SCORE,31,12);
  const int half=int(w*options_.seam_search_deg/options_.horizontal_fov_deg/2);
  const int margin=std::max(12,w/8);
  for(int i=0;i<2;++i) {
    cv::Mat small;cv::resize(i==0?a:b,small,size,0,0,cv::INTER_AREA);
    cv::cvtColor(small,gray[i],cv::COLOR_RGB2GRAY);
    cv::resize(masks_[i],mask[i],size,0,0,cv::INTER_NEAREST);
    const int lo=std::max(0,w/2-half-margin),hi=std::min(w,w/2+half+margin);
    if(lo)mask[i].colRange(0,lo).setTo(0);
    if(hi<w)mask[i].colRange(hi,w).setTo(0);
    detector->detectAndCompute(gray[i],mask[i],keys[i],desc[i]);
  }
  if(desc[0].rows<2 || desc[1].rows<2)return;
  cv::BFMatcher matcher(cv::NORM_HAMMING);
  std::vector<std::vector<cv::DMatch>> forward,reverse;
  matcher.knnMatch(desc[0],desc[1],forward,2);matcher.knnMatch(desc[1],desc[0],reverse,2);
  std::vector<int> mutual(desc[1].rows,-1);
  for(const auto &m:reverse)if(m.size()==2 && m[0].distance<.72f*m[1].distance)
    mutual[m[0].queryIdx]=m[0].trainIdx;
  cv::Mat risk=cv::Mat::zeros(size,CV_32F);
  const auto &R=calibration_.rotation;const auto &t=calibration_.translation;
  const auto midpoint=-(R.t()*t)*.5;
  auto ray=[&](const cv::Point2f &p,int i) {
    const double lon=((p.x+.5)/w-.5)*options_.horizontal_fov_deg*pi/180;
    const double lat=((p.y+.5)/h-.5)*options_.vertical_fov_deg*pi/180;
    cv::Vec3d v=basis_*cv::Vec3d(std::sin(lon)*std::cos(lat),std::sin(lat),std::cos(lon)*std::cos(lat));
    if(options_.reference_depth_m!=0)v=v*options_.reference_depth_m+midpoint;
    if(i) {v=R*v;if(options_.reference_depth_m!=0)v+=t;}
    return unit(v);
  };
  for(const auto &m:forward) {
    if(m.size()!=2 || m[0].distance>=.72f*m[1].distance || mutual[m[0].trainIdx]!=m[0].queryIdx)continue;
    const auto &ka=keys[0][m[0].queryIdx],&kb=keys[1][m[0].trainIdx];
    const auto pa=ka.pt,pb=kb.pt;
    if(std::abs(pa.x-pb.x)>w*.22 || std::abs(pa.y-pb.y)>h*.06)continue;
    if(cv::norm(t)>1e-6) {
      const auto normal=t.cross(R*ray(pa,0));const double norm=cv::norm(normal);
      if(norm<1e-8 || std::abs(ray(pb,1).dot(normal))/norm>.012)continue;
    }
    ++correspondence_count_;
    const int pad=std::max(5,int(options_.feather_px*w/options_.width/2+3));
    const int radius=std::clamp(int(2.5*std::max(ka.size,kb.size)),8,std::max(8,h/10));
    const int x0=std::max(0,int(std::min(pa.x,pb.x))-pad),x1=std::min(w,int(std::max(pa.x,pb.x))+pad+1);
    const int y0=std::max(0,int(std::min(pa.y,pb.y))-radius),y1=std::min(h,int(std::max(pa.y,pb.y))+radius+1);
    if(x1>x0 && y1>y0)risk(cv::Rect(x0,y0,x1-x0,y1-y0)).setTo(1);
  }
  // A few ambiguous matches must not drive the seam. The old renderer is the fallback.
  if(correspondence_count_<6)return;
  cv::resize(risk,seam_risk_,small_mask_a_.size(),0,0,cv::INTER_AREA);
  cv::GaussianBlur(seam_risk_,seam_risk_,cv::Size(0,0),1.);
  parallax_guard_=true;
}

void PairRenderer::updateSeam(const cv::Mat &a,const cv::Mat &b) {
  updateParallaxGuard(a,b);
  cv::Mat sa,sb,ga,gb;
  cv::resize(a,sa,small_mask_a_.size(),0,0,cv::INTER_AREA);
  cv::resize(b,sb,small_mask_a_.size(),0,0,cv::INTER_AREA);
  cv::cvtColor(sa,ga,cv::COLOR_RGB2GRAY);cv::cvtColor(sb,gb,cv::COLOR_RGB2GRAY);
  if(options_.exposure_compensation) {
    std::vector<float> ratios;
    for(int y=0;y<ga.rows;y+=2)for(int x=0;x<ga.cols;x+=2) {
      const int av=ga.at<unsigned char>(y,x),bv=gb.at<unsigned char>(y,x);
      if(small_mask_a_.at<unsigned char>(y,x) && small_mask_b_.at<unsigned char>(y,x) && av>25 && av<230 && bv>25 && bv<230)
        ratios.push_back(static_cast<float>(av)/bv);
    }
    if(ratios.size()>100) {
      auto mid=ratios.begin()+ratios.size()/2;std::nth_element(ratios.begin(),mid,ratios.end());
      const double target=std::clamp<double>(*mid,.8,1.25);
      gain_=seam_initialized_?.9*gain_+.1*target:target;
    }
  }
  if(options_.seam_mode=="fixed" || options_.seam_mode=="primary_a") {seam_initialized_=true;adaptive_valid_=false;return;}
  if(options_.seam_mode=="depth_seam") {seam_initialized_=true;return;}  // seam chosen by updateDepthSeam
  cv::Mat grad_a,grad_b;
  cv::Sobel(ga,grad_a,CV_32F,1,0,3);cv::Sobel(gb,grad_b,CV_32F,1,0,3);
  const int w=ga.cols,h=ga.rows;
  const int half=std::max(1,int(w*options_.seam_search_deg/options_.horizontal_fov_deg/2));
  const int lo=std::max(1,w/2-half),hi=std::min(w-2,w/2+half);
  cv::Mat cost(h,w,CV_32F,cv::Scalar(1e8f)),parent(h,w,CV_32S,cv::Scalar(-1));
  for(int y=0;y<h;++y)for(int x=lo;x<=hi;++x) {
    if(!small_mask_a_.at<unsigned char>(y,x) || !small_mask_b_.at<unsigned char>(y,x))continue;
    const auto ac=sa.at<cv::Vec3b>(y,x),bc=sb.at<cv::Vec3b>(y,x);
    float value=0;
    for(int ch=0;ch<3;++ch)value+=std::abs(ac[ch]-gain_*bc[ch])/3.f;
    value+=.08f*(std::abs(grad_a.at<float>(y,x))+std::abs(grad_b.at<float>(y,x)));
    value+=.025f*std::abs(x-w/2);
    value+=180.f*seam_risk_.at<float>(y,x);
    if(seam_initialized_)value+=.35f*std::abs(x-seam_[std::min(options_.height-1,y*options_.height/h)]*w/options_.width);
    if(y==0) {cost.at<float>(y,x)=value;continue;}
    float best=1e8f;int from=-1;
    for(int dx=-2;dx<=2;++dx) {
      const int px=x+dx;if(px<lo || px>hi)continue;
      const float candidate=cost.at<float>(y-1,px)+.5f*std::abs(dx);
      if(candidate<best) {best=candidate;from=px;}
    }
    cost.at<float>(y,x)=best+value;parent.at<int>(y,x)=from;
  }
  int end=lo;for(int x=lo+1;x<=hi;++x)if(cost.at<float>(h-1,x)<cost.at<float>(h-1,end))end=x;
  if(cost.at<float>(h-1,end)>=1e7f) {adaptive_valid_=false;return;}
  std::vector<float> path(h);path[h-1]=float(end);
  for(int y=h-1;y>0;--y) {end=parent.at<int>(y,end);if(end<0) {adaptive_valid_=false;return;}path[y-1]=float(end);}
  for(int y=0;y<options_.height;++y) {
    const float pos=float(y)*h/options_.height;const int i=std::min(h-1,int(pos)),j=std::min(h-1,i+1);
    float target=(path[i]*(1-(pos-i))+path[j]*(pos-i)+.5f)*options_.width/w;
    // Limit seam motion across video updates; the first frame may choose any valid path.
    if(seam_initialized_) {
      const int old_x=std::clamp(int(seam_[y]*w/options_.width),0,w-1);
      const int new_x=std::clamp(int(target*w/options_.width),0,w-1);
      const bool escape=parallax_guard_ && seam_risk_.at<float>(i,old_x)>seam_risk_.at<float>(i,new_x)+.25f;
      if(!escape)target=std::clamp(target,seam_[y]-8.f,seam_[y]+8.f);
    }
    seam_[y]=target;
  }
  seam_initialized_=true;adaptive_valid_=true;
}

std::array<cv::Mat,2> PairRenderer::projectInputs(const cv::Mat &a,const cv::Mat &b) const {
  requireInputs(calibration_,a,b);
  std::array<cv::Mat,2> warped;
  cv::remap(a,warped[0],maps1_[0],maps2_[0],cv::INTER_LINEAR);
  cv::remap(b,warped[1],maps1_[1],maps2_[1],cv::INTER_LINEAR);
  return warped;
}

bool PairRenderer::projectAtDepth(const cv::Vec3d &direction,double rho,int camera,cv::Point2d &pixel) const {
  // The point 1/rho metres from the camera midpoint along direction, scaled by rho
  // (KB4 projection is scale invariant), so rho=0 is the direction at infinity.
  const auto &R=calibration_.rotation;const auto &t=calibration_.translation;
  cv::Vec3d v=direction-(R.t()*t)*(.5*rho);
  if(camera)v=R*v+t*rho;
  pixel=projectKB4(v,calibration_.cameras[camera].k);
  const double angle=std::atan2(std::hypot(v[0],v[1]),v[2]);
  return pixel.x>=1 && pixel.y>=1 && pixel.x<calibration_.input_size.width-2 && pixel.y<calibration_.input_size.height-2 &&
    angle<100*pi/180;
}

void PairRenderer::buildDepthSweep() {
  auto &d=depth_;
  const double hfov=options_.horizontal_fov_deg*pi/180;
  d.grid={std::max(64,options_.width*3/8),std::max(32,options_.height*3/8)};
  // Match the downscaled source to the sweep grid so matching neither aliases nor wastes pixels.
  const double focal=(calibration_.cameras[0].k[0]+calibration_.cameras[1].k[0])/2;
  const double scale=std::clamp(d.grid.width/hfov/focal,1./8,1.);
  d.source={std::max(16,int(std::lround(calibration_.input_size.width*scale))),
    std::max(16,int(std::lround(calibration_.input_size.height*scale)))};
  const int half=std::max(1,int(std::ceil(d.grid.width*options_.seam_search_deg/options_.horizontal_fov_deg/2)));
  const int margin=kSweepRadius+3;
  const int x0=std::max(0,d.grid.width/2-half-margin),x1=std::min(d.grid.width,d.grid.width/2+half+margin);
  d.roi={x0,0,x1-x0,d.grid.height};
  // Inverse-depth hypotheses about 1.25 grid pixels of parallax apart; two beyond infinity absorb calibration error.
  const double step=1.25*hfov/d.grid.width/cv::norm(calibration_.translation);
  const int count=int(std::ceil(1/options_.min_depth_m/step))+3;
  for(int k=0;k<count;++k)d.rho.push_back(float((k-2)*step));
  d.map1.resize(count);d.map2.resize(count);d.valid.resize(count);
  const double sx=double(d.source.width)/calibration_.input_size.width,sy=double(d.source.height)/calibration_.input_size.height;
  const auto kernel=cv::getStructuringElement(cv::MORPH_RECT,{2*kSweepRadius+1,2*kSweepRadius+1});
  cv::parallel_for_(cv::Range(0,count),[&](const cv::Range &range) {
    for(int k=range.start;k<range.end;++k) {
      std::array<cv::Mat,2> map;cv::Mat valid(d.roi.size(),CV_8U,cv::Scalar(255));
      for(auto &m:map)m=cv::Mat(d.roi.size(),CV_32FC2,cv::Scalar(-10,-10));
      for(int y=0;y<d.roi.height;++y)for(int x=0;x<d.roi.width;++x) {
        const auto direction=viewRay(basis_,options_,x+d.roi.x,y,d.grid);
        for(int i=0;i<2;++i) {
          cv::Point2d p;
          if(projectAtDepth(direction,d.rho[k],i,p))map[i].at<cv::Vec2f>(y,x)={float((p.x+.5)*sx-.5),float((p.y+.5)*sy-.5)};
          else valid.at<unsigned char>(y,x)=0;
        }
      }
      // The whole matching window must be observed by both cameras.
      cv::erode(valid,d.valid[k],kernel);
      for(int i=0;i<2;++i)cv::convertMaps(map[i],cv::noArray(),d.map1[k][i],d.map2[k][i],CV_16SC2);
    }
  });
  cv::Mat both;cv::bitwise_and(masks_[0],masks_[1],both);cv::resize(both,both,d.grid,0,0,cv::INTER_NEAREST);
  d.both_valid=both(d.roi).clone();
  d.rho_map=cv::Mat(d.grid,CV_32F,cv::Scalar(std::numeric_limits<float>::quiet_NaN()));
  d.seam_rho.assign(options_.height,options_.reference_depth_m==0?0.f:float(1/options_.reference_depth_m));
  d.applied.assign(options_.height,cv::Vec4f::all(std::numeric_limits<float>::quiet_NaN()));
  d.extent.assign(options_.height,cv::Vec2i(options_.width,-1));
}

void PairRenderer::updateDepthSeam(const cv::Mat &a,const cv::Mat &b) {
  requireInputs(calibration_,a,b);
  auto &d=depth_;
  std::array<cv::Mat,2> gray;
  for(int i=0;i<2;++i) {
    cv::Mat small;cv::resize(i==0?a:b,small,d.source,0,0,cv::INTER_AREA);
    cv::cvtColor(small,small,cv::COLOR_RGB2GRAY);small.convertTo(gray[i],CV_32F,1./255);
  }
  // Sphere sweep around the camera midpoint: 1 - ZNCC for every inverse-depth hypothesis.
  const int n=int(d.rho.size()),w=d.roi.width,h=d.roi.height;
  const cv::Size window(2*kSweepRadius+1,2*kSweepRadius+1);
  cv::Mat volume(n,w*h,CV_32F);
  cv::parallel_for_(cv::Range(0,n),[&](const cv::Range &range) {
    cv::Mat ia,ib,ma,mb,saa,sbb,sab;
    for(int k=range.start;k<range.end;++k) {
      cv::remap(gray[0],ia,d.map1[k][0],d.map2[k][0],cv::INTER_LINEAR,cv::BORDER_REPLICATE);
      cv::remap(gray[1],ib,d.map1[k][1],d.map2[k][1],cv::INTER_LINEAR,cv::BORDER_REPLICATE);
      cv::boxFilter(ia,ma,-1,window);cv::boxFilter(ib,mb,-1,window);
      cv::boxFilter(ia.mul(ia),saa,-1,window);cv::boxFilter(ib.mul(ib),sbb,-1,window);cv::boxFilter(ia.mul(ib),sab,-1,window);
      float *out=volume.ptr<float>(k);
      for(int y=0;y<h;++y) {
        const float *pa=ma.ptr<float>(y),*pb=mb.ptr<float>(y),*paa=saa.ptr<float>(y),*pbb=sbb.ptr<float>(y),*pab=sab.ptr<float>(y);
        const auto *valid=d.valid[k].ptr<unsigned char>(y);
        for(int x=0;x<w;++x) {
          float &c=out[y*w+x];
          if(!valid[x]) {c=kOutside;continue;}
          const float va=paa[x]-pa[x]*pa[x],vb=pbb[x]-pb[x]*pb[x];
          c=va<kFlatSigma*kFlatSigma || vb<kFlatSigma*kFlatSigma?kFlat:1-(pab[x]-pa[x]*pb[x])/std::sqrt(va*vb);
        }
      }
    }
  });
  // Horizontal edges match at any depth along the epipolar direction and would lock onto the small vertical
  // parallax instead; they count as flat (a seam across them hides horizontal misalignment anyway).
  const float step=n>1?d.rho[1]-d.rho[0]:0;
  cv::Mat epipolar;
  {
    const double rho_ref=options_.reference_depth_m==0?0:1/options_.reference_depth_m;
    const int reference=step>0?std::clamp(int(std::lround((rho_ref-d.rho[0])/step)),0,n-1):0;
    cv::Mat ia,gx,gy;
    cv::remap(gray[0],ia,d.map1[reference][0],d.map2[reference][0],cv::INTER_LINEAR,cv::BORDER_REPLICATE);
    cv::Sobel(ia,gx,CV_32F,1,0,3,1./8);cv::Sobel(ia,gy,CV_32F,0,1,3,1./8);
    cv::boxFilter(gx.mul(gx),gx,-1,window);cv::boxFilter(gy.mul(gy),gy,-1,window);
    cv::Mat share;cv::scaleAdd(gy,-kMinEpipolarShare,gx,share);
    epipolar=(gx>=kMinEpipolarGradient*kMinEpipolarGradient)&(share>=0);
  }
  // Winner-take-all with sub-step refinement. state: 0 unobserved, 1 flat, 2 ambiguous/occluded, 3 measured.
  const float nan=std::numeric_limits<float>::quiet_NaN();
  cv::Mat rho(h,w,CV_32F,cv::Scalar(nan)),state=cv::Mat::zeros(h,w,CV_8U),residual(h,w,CV_32F,cv::Scalar(1));
  cv::parallel_for_(cv::Range(0,h),[&](const cv::Range &rows) {
    for(int y=rows.start;y<rows.end;++y)for(int x=0;x<w;++x) {
      const int p=y*w+x;int best=-1,observed=0,flat=0;float lowest=kFlat;
      for(int k=0;k<n;++k) {
        const float c=volume.at<float>(k,p);
        if(c==kOutside)continue;
        ++observed;if(c==kFlat) {++flat;continue;}
        if(c<lowest) {lowest=c;best=k;}
      }
      if(!observed)continue;
      if(best<0 || 2*flat>observed || !epipolar.at<unsigned char>(y,x)) {state.at<unsigned char>(y,x)=1;continue;}
      float second=kFlat;
      for(int k=0;k<n;++k)if(std::abs(k-best)>2)second=std::min(second,volume.at<float>(k,p));
      residual.at<float>(y,x)=lowest;
      if(lowest>kMaxCost || second-lowest<kMinMargin) {state.at<unsigned char>(y,x)=2;continue;}
      float value=d.rho[best];
      if(best>0 && best<n-1) {
        const float c0=volume.at<float>(best-1,p),c2=volume.at<float>(best+1,p),curvature=c0-2*lowest+c2;
        if(c0<kFlat && c2<kFlat && curvature>1e-6f)value+=std::clamp(.5f*(c0-c2)/curvature,-.5f,.5f)*step;
      }
      rho.at<float>(y,x)=value;state.at<unsigned char>(y,x)=3;
    }
  });
  // Seam path on the sweep grid: measured, depth-smooth pixels are safe; flat pixels hide misalignment;
  // ambiguous textured pixels (occlusions, repeated texture) are avoided.
  const int cx=d.grid.width/2-d.roi.x;
  const int half=std::max(1,int(d.grid.width*options_.seam_search_deg/options_.horizontal_fov_deg/2));
  const int lo=std::max(2,cx-half),hi=std::min(w-3,cx+half);
  const auto gridSeam=[&](int y) {
    return seam_[std::min(options_.height-1,int((y+.5f)*options_.height/h))]*d.grid.width/options_.width-.5f-d.roi.x;
  };
  cv::Mat cost(h,w,CV_32F,cv::Scalar(1e8f)),parent(h,w,CV_32S,cv::Scalar(-1));
  for(int y=0;y<h;++y)for(int x=lo;x<=hi;++x) {
    if(!d.both_valid.at<unsigned char>(y,x))continue;
    float value=1;
    switch(state.at<unsigned char>(y,x)) {
      case 3: {
        const float l=rho.at<float>(y,x-2),r=rho.at<float>(y,x+2);
        value=2*residual.at<float>(y,x)+1.5f*(std::isnan(l) || std::isnan(r)?.5f:std::min(1.f,std::abs(r-l)));
        break;
      }
      case 1: value=.35f;break;
      case 2: value=1.2f;break;
      default: break;
    }
    value+=.004f*std::abs(x-cx);
    if(d.initialized)value+=.02f*std::abs(x-gridSeam(y));
    if(y==0) {cost.at<float>(y,x)=value;continue;}
    float best=1e8f;int from=-1;
    for(int dx=-2;dx<=2;++dx) {
      const int px=x+dx;if(px<lo || px>hi)continue;
      float candidate=cost.at<float>(y-1,px)+.15f*std::abs(dx);
      const float r0=rho.at<float>(y,x),r1=rho.at<float>(y-1,px);
      if(!std::isnan(r0) && !std::isnan(r1))candidate+=.5f*std::abs(r0-r1);
      if(candidate<best) {best=candidate;from=px;}
    }
    cost.at<float>(y,x)=best+value;parent.at<int>(y,x)=from;
  }
  int end=lo;for(int x=lo+1;x<=hi;++x)if(cost.at<float>(h-1,x)<cost.at<float>(h-1,end))end=x;
  if(cost.at<float>(h-1,end)>=1e7f) {adaptive_valid_=false;return;}
  std::vector<float> path(h);path[h-1]=float(end);
  for(int y=h-1;y>0;--y) {end=parent.at<int>(y,end);if(end<0) {adaptive_valid_=false;return;}path[y-1]=float(end);}
  for(int y=0;y<options_.height;++y) {
    const float pos=float(y)*h/options_.height;const int i=std::min(h-1,int(pos)),j=std::min(h-1,i+1);
    float target=(path[i]*(1-(pos-i))+path[j]*(pos-i)+d.roi.x+.5f)*options_.width/d.grid.width;
    if(d.initialized)target=std::clamp(target,seam_[y]-8.f,seam_[y]+8.f);
    seam_[y]=target;
  }
  // Depth along the seam where it actually is (after the motion limit). Matching cost is averaged over
  // a window following the seam; a scanline optimisation then changes the depth only at edges supported
  // by several rows, so single false matches cannot shear the band.
  const int cells=(2*kProfileX+1)*(2*kProfileY+1);
  std::vector<float> data(size_t(h)*n,0.f),mean(n);std::vector<int> support(h,0);int measured=0;
  for(int y=0;y<h;++y) {
    const int center=int(std::lround(gridSeam(y)));
    std::fill(mean.begin(),mean.end(),0.f);
    for(int yy=std::max(0,y-kProfileY);yy<=std::min(h-1,y+kProfileY);++yy)
      for(int xx=std::max(0,center-kProfileX);xx<=std::min(w-1,center+kProfileX);++xx) {
        if(state.at<unsigned char>(yy,xx)<2)continue;
        ++support[y];
        for(int k=0;k<n;++k)mean[k]+=std::min(volume.at<float>(k,yy*w+xx),1.f);
      }
    if(!support[y])continue;
    for(auto &c:mean)c/=float(support[y]);
    const int best=int(std::min_element(mean.begin(),mean.end())-mean.begin());
    float second=1;for(int k=0;k<n;++k)if(std::abs(k-best)>2)second=std::min(second,mean[k]);
    if(mean[best]<=kMaxCost && second-mean[best]>=kMinMargin)++measured;
    // Rows with few textured pixels in the window weigh less against P1/P2.
    for(int k=0;k<n;++k)data[size_t(y)*n+k]=mean[k]*support[y]/cells;
  }
  d.valid_fraction=double(measured)/h;
  const float rho_ref=options_.reference_depth_m==0?0.f:float(1/options_.reference_depth_m);
  std::vector<float> profile(h,rho_ref);
  if(measured) {
    std::vector<float> acc(data);std::vector<int> from(size_t(h)*n);
    for(int y=1;y<h;++y) {
      const float *prev=&acc[size_t(y-1)*n];float *cur=&acc[size_t(y)*n];int *link=&from[size_t(y)*n];
      const int jump=int(std::min_element(prev,prev+n)-prev);
      for(int k=0;k<n;++k) {
        float c=prev[k];int f=k;
        if(k>0 && prev[k-1]+kProfileP1<c) {c=prev[k-1]+kProfileP1;f=k-1;}
        if(k<n-1 && prev[k+1]+kProfileP1<c) {c=prev[k+1]+kProfileP1;f=k+1;}
        if(prev[jump]+kProfileP2<c) {c=prev[jump]+kProfileP2;f=jump;}
        cur[k]+=c;link[k]=f;
      }
    }
    int k=int(std::min_element(acc.end()-n,acc.end())-(acc.end()-n));
    for(int y=h-1;y>=0;--y) {
      const float *row=&data[size_t(y)*n];float value=d.rho[k];
      if(support[y] && k>0 && k<n-1) {
        const float curvature=row[k-1]-2*row[k]+row[k+1];
        if(curvature>1e-6f)value+=std::clamp(.5f*(row[k-1]-row[k+1])/curvature,-.5f,.5f)*step;
      }
      profile[y]=value;
      if(y>0)k=from[size_t(y)*n+k];
    }
    cv::Mat column(h,1,CV_32F,profile.data());
    cv::GaussianBlur(column,column,cv::Size(1,7),0,1,cv::BORDER_REPLICATE);
  }
  for(int y=0;y<options_.height;++y) {
    const float pos=(y+.5f)*h/options_.height-.5f;
    const int i=std::clamp(int(std::floor(pos)),0,h-1),j=std::min(h-1,i+1);const float f=std::clamp(pos-i,0.f,1.f);
    const float target=profile[i]*(1-f)+profile[j]*f;
    float &current=d.seam_rho[y];
    // Hysteresis plus smoothing so measurement noise does not shimmer the seam band.
    if(!d.initialized)current=target;
    else if(std::abs(target-current)>.015f)current+=.5f*(target-current);
  }
  d.rho_map.setTo(nan);rho.copyTo(d.rho_map(d.roi));
  d.initialized=true;adaptive_valid_=true;
  rebuildDepthBand();
}

void PairRenderer::rebuildDepthBand() {
  // Re-project only the band around the seam at the measured seam depth, easing back to the reference
  // sphere. A near seam compresses the displayed side of each camera: the ramp widens to keep that within
  // kMaxCompression, and the seam depth is limited to what the widest ramp allows.
  auto &d=depth_;
  const int H=options_.height,W=options_.width;
  const double px_per_deg=W/options_.horizontal_fov_deg,px_per_rad=px_per_deg*180/pi;
  const double rho_ref=options_.reference_depth_m==0?0:1/options_.reference_depth_m;
  const double half_baseline=cv::norm(calibration_.translation)/2;
  const double min_ramp=options_.depth_band_deg*px_per_deg;
  const double max_ramp=std::max(min_ramp,std::min(kMaxRampDeg,options_.horizontal_fov_deg/2-options_.depth_core_deg)*px_per_deg);
  // Each camera moves half_baseline*delta radians at the seam; smoothstep peaks at 1.5x its mean slope.
  const auto rampFor=[&](double delta) {return 1.5*half_baseline*std::abs(delta)*px_per_rad/kMaxCompression;};
  const double max_delta=kMaxCompression*max_ramp/px_per_rad/(1.5*half_baseline);
  // Smooth band center; the core covers the seam's deviation from it, so a jagged seam does not shear the band.
  const int reach=std::max(1,H/20);
  cv::Mat seam(H,1,CV_32F,seam_.data()),center,deviation,core;
  cv::GaussianBlur(seam,center,cv::Size(1,2*reach+1),0,reach/3.,cv::BORDER_REPLICATE);
  cv::absdiff(seam,center,deviation);
  cv::dilate(deviation,core,cv::Mat::ones(2*reach+1,1,CV_8U),cv::Point(-1,-1),1,cv::BORDER_REPLICATE);
  cv::GaussianBlur(core,core,cv::Size(1,2*reach+1),0,reach/3.,cv::BORDER_REPLICATE);
  // A row-to-row change of the band shift shears the whole band (horizontal tears), so the shift may change by
  // at most kMaxShear pixels per row. Corrections shrink toward the reference: a short false excursion
  // stays small, and limited rows are only ever partially corrected, never moved past the measured depth:
  // the largest function below the correction and the smallest above it with that slope, each clipped at 0.
  const double limit=kMaxShear/(half_baseline*px_per_rad);
  std::vector<double> lower(H),upper(H);
  for(int y=0;y<H;++y)lower[y]=upper[y]=std::clamp(double(d.seam_rho[y])-rho_ref,-max_delta,max_delta);
  for(int y=1;y<H;++y) {lower[y]=std::min(lower[y],lower[y-1]+limit);upper[y]=std::max(upper[y],upper[y-1]-limit);}
  for(int y=H-2;y>=0;--y) {lower[y]=std::min(lower[y],lower[y+1]+limit);upper[y]=std::max(upper[y],upper[y+1]-limit);}
  std::vector<int> rows;
  std::vector<cv::Vec4f> bands(H);
  for(int y=0;y<H;++y) {
    const double delta=std::max(lower[y],0.)+std::min(upper[y],0.);
    d.seam_rho[y]=float(rho_ref+delta);
    bands[y]={center.at<float>(y),float(options_.depth_core_deg*px_per_deg+options_.feather_px/2+core.at<float>(y)),
      float(std::clamp(rampFor(delta),min_ramp,max_ramp)),d.seam_rho[y]};
    const auto &old=d.applied[y];
    // Static scenes leave the maps alone (NaN marks a row never built).
    if(!(std::abs(old[0]-bands[y][0])<.05f && std::abs(old[1]-bands[y][1])<.05f && std::abs(old[2]-bands[y][2])<.05f &&
      std::abs(old[3]-bands[y][3])<1e-4f))rows.push_back(y);
  }
  if(rows.empty())return;
  const cv::Size size(W,H);
  cv::parallel_for_(cv::Range(0,int(rows.size())),[&](const cv::Range &range) {
    for(int r=range.start;r<range.end;++r) {
      const int y=rows[r];const auto &band=bands[y];
      const cv::Vec2i extent(std::max(0,int(std::floor(band[0]-band[1]-band[2]))-1),
        std::min(W-1,int(std::ceil(band[0]+band[1]+band[2]))+1));
      // Columns of the previous band outside the new one go back to the reference maps.
      const int lo=std::min(extent[0],d.extent[y][0]),hi=std::max(extent[1],d.extent[y][1]);
      for(int x=lo;x<=hi;++x) {
        const double distance=std::abs(x-band[0]);
        double weight=0;
        if(distance<=band[1])weight=1;
        else if(distance<band[1]+band[2]) {const double u=(distance-band[1])/band[2];weight=1-u*u*(3-2*u);}
        const auto direction=weight>0?viewRay(basis_,options_,x,y,size):cv::Vec3d();
        for(int i=0;i<2;++i) {
          float &map_x=d.map_x[i].at<float>(y,x),&map_y=d.map_y[i].at<float>(y,x);
          auto &mask=masks_[i].at<unsigned char>(y,x);
          if(weight==0) {
            map_x=d.base_x[i].at<float>(y,x);map_y=d.base_y[i].at<float>(y,x);mask=d.base_mask[i].at<unsigned char>(y,x);
            continue;
          }
          cv::Point2d p;
          if(projectAtDepth(direction,rho_ref+(band[3]-rho_ref)*weight,i,p)) {
            map_x=float(p.x);map_y=float(p.y);mask=255;
          } else {map_x=-1;map_y=-1;mask=0;}
        }
      }
      for(int i=0;i<2;++i) {
        const cv::Range cols(lo,hi+1);
        cv::Mat map1=maps1_[i].row(y).colRange(cols),map2=maps2_[i].row(y).colRange(cols);
        cv::convertMaps(d.map_x[i].row(y).colRange(cols),d.map_y[i].row(y).colRange(cols),map1,map2,CV_16SC2);
      }
      d.applied[y]=band;d.extent[y]=extent;
    }
  });
  // Results share valid_; replace it rather than writing through earlier results.
  cv::Mat valid;cv::bitwise_or(masks_[0],masks_[1],valid);valid_=valid;
}

RenderResult PairRenderer::render(const cv::Mat &a,const cv::Mat &b,bool update_seam) {
  const bool update=update_seam || !seam_initialized_;
  // depth_seam measures on the raw inputs and re-projects the seam band before warping.
  if(update && options_.seam_mode=="depth_seam")updateDepthSeam(a,b);
  const auto warped=projectInputs(a,b);const auto &wa=warped[0],&wb=warped[1];
  if(update)updateSeam(wa,wb);
  RenderResult out;
  out.image=cv::Mat(options_.height,options_.width,CV_8UC3);
  out.owner=cv::Mat::zeros(options_.height,options_.width,CV_8U);
  out.valid_mask=valid_;out.seam=seam_;out.gain=gain_;out.adaptive_seam=adaptive_valid_;
  out.correspondence_count=correspondence_count_;out.parallax_guard=parallax_guard_;
  if(options_.seam_mode=="depth_seam") {out.seam_inverse_depth=depth_.seam_rho;out.depth_valid_fraction=depth_.valid_fraction;}
  if(parallax_guard_) {
    int conflict=0;
    for(int y=0;y<options_.height;++y) {
      const int x=std::clamp(int(seam_[y]*seam_risk_.cols/options_.width),0,seam_risk_.cols-1);
      if(seam_risk_.at<float>(y*seam_risk_.rows/options_.height,x)>.25f)++conflict;
    }
    out.seam_conflict_fraction=double(conflict)/options_.height;
  }
  cv::parallel_for_(cv::Range(0,options_.height),[&](const cv::Range &range) {
    for(int y=range.start;y<range.end;++y) {
      auto *dst=out.image.ptr<cv::Vec3b>(y);auto *owner=out.owner.ptr<unsigned char>(y);
      const auto *pa=wa.ptr<cv::Vec3b>(y),*pb=wb.ptr<cv::Vec3b>(y);
      const auto *ma=masks_[0].ptr<unsigned char>(y),*mb=masks_[1].ptr<unsigned char>(y);
      for(int x=0;x<options_.width;++x) {
        if(!ma[x] && !mb[x]) {dst[x]={0,0,0};continue;}
        double alpha;
        if(!primary_weight_.empty())alpha=primary_weight_.at<float>(y,x);
        else {
          alpha=options_.feather_px==0?(x<seam_[y]?1.:0.):std::clamp(.5+(seam_[y]-x)/options_.feather_px,0.,1.);
          if(!a_left_)alpha=1-alpha;
        }
        if(!ma[x])alpha=0;else if(!mb[x])alpha=1;
        for(int ch=0;ch<3;++ch)dst[x][ch]=cv::saturate_cast<unsigned char>(alpha*pa[x][ch]+(1-alpha)*gain_*pb[x][ch]);
        owner[x]=alpha>=.5?1:2;
      }
    }
  });
  return out;
}
}  // namespace zephyr_surround_vision
