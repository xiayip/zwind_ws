// SPDX-License-Identifier: Apache-2.0
#include "zephyr_surround_vision/pair_renderer.hpp"
#include "zephyr_surround_vision/pair_buffer.hpp"
#include <cmath>
#include <gtest/gtest.h>
#include <opencv2/imgproc.hpp>
using namespace zephyr_surround_vision;

TEST(Projection, EquidistantRayBehindNinetyDegrees) {
  std::array<double,8> k={200,210,320,240,0,0,0,0};
  const double theta=95.*std::acos(-1.)/180.;
  const auto p=projectKB4({std::sin(theta),0,std::cos(theta)},k);
  EXPECT_NEAR(p.x,320+200*theta,1e-9);EXPECT_NEAR(p.y,240,1e-9);
  const auto center=projectKB4({0,0,3},k);EXPECT_DOUBLE_EQ(center.x,320);EXPECT_DOUBLE_EQ(center.y,240);
  EXPECT_TRUE(std::isnan(projectKB4({0,0,-1},k).x));
}
TEST(Projection, RealRigOrientationAndValidity) {
  RenderOptions o;o.width=320;o.height=160;
  PairRenderer front(loadCalibration(RIG_FILE,"front"),o),back(loadCalibration(RIG_FILE,"back"),o);
  EXPECT_TRUE(front.aOnLeft());EXPECT_FALSE(back.aOnLeft());
  EXPECT_GT(cv::countNonZero(front.validMask()),320*160*.97);
  EXPECT_NEAR(cv::determinant(cv::Mat(front.virtualBasisInA())),1.,1e-10);
  EXPECT_LT(cv::norm(cv::Mat(front.virtualBasisInA().t()*front.virtualBasisInA()-cv::Matx33d::eye())),1e-10);
  EXPECT_THROW(loadCalibration(RIG_FILE,"360"),std::invalid_argument);
}
TEST(Render, UnknownMaskAndInputValidation) {
  auto c=loadCalibration(RIG_FILE,"front");RenderOptions o;o.width=320;o.height=160;o.vertical_fov_deg=140;
  o.seam_mode="fixed";o.exposure_compensation=false;
  PairRenderer renderer(c,o);
  const auto result=renderer.render(cv::Mat(c.input_size,CV_8UC3,cv::Scalar(255,0,0)),
    cv::Mat(c.input_size,CV_8UC3,cv::Scalar(0,0,255)),true);
  int unknown=0;
  for(int y=0;y<o.height;++y)for(int x=0;x<o.width;++x) {
    const auto valid=result.valid_mask.at<unsigned char>(y,x),owner=result.owner.at<unsigned char>(y,x);
    if(!valid) {++unknown;EXPECT_EQ(owner,0);EXPECT_EQ(result.image.at<cv::Vec3b>(y,x),cv::Vec3b(0,0,0));}
    else EXPECT_TRUE(owner==1 || owner==2);
  }
  EXPECT_GT(unknown,0);
  EXPECT_THROW(renderer.render(cv::Mat(20,20,CV_8UC3),cv::Mat(20,20,CV_8UC3),false),std::invalid_argument);
}
TEST(Render, AdaptiveSeamAvoidsDisagreementAndLimitsMotion) {
  PairCalibration c;c.input_size={400,300};c.rotation=cv::Matx33d::eye();c.translation={0,0,0};
  for(auto &camera:c.cameras)camera.k={180,180,200,150,0,0,0,0};
  RenderOptions o;o.width=320;o.height=160;o.horizontal_fov_deg=120;o.vertical_fov_deg=70;o.reference_depth_m=0;
  PairRenderer renderer(c,o);
  cv::Mat a(c.input_size,CV_8UC3,cv::Scalar(100,100,100)),b=a.clone();
  cv::rectangle(b,{180,0,40,300},{240,240,240},cv::FILLED);
  auto first=renderer.render(a,b,true);EXPECT_TRUE(first.adaptive_seam);
  EXPECT_GT(std::abs(first.seam[80]-o.width*.5),12);
  cv::Mat changed=a.clone();cv::rectangle(changed,{120,0,120,300},{240,240,240},cv::FILLED);
  auto second=renderer.render(a,changed,true);
  for(size_t i=0;i<first.seam.size();++i)EXPECT_LE(std::abs(second.seam[i]-first.seam[i]),8.001);
}
TEST(Pairing, NewestAcceptablePairIsNeverReused) {
  PairBuffer<int> b;
  b.push(0,100,1000,1);b.push(1,103,1001,2);b.push(0,133,1002,3);b.push(1,136,1003,4);
  auto pair=b.take(1010,100,5);ASSERT_TRUE(pair);EXPECT_EQ((*pair)[0].payload,3);EXPECT_EQ((*pair)[1].payload,4);
  EXPECT_FALSE(b.take(1011,100,5));
}

TEST(Render, ParallaxGuardFallsBackOnTexturelessInput) {
  auto c=loadCalibration(RIG_FILE,"front");RenderOptions o;o.width=320;o.height=160;
  o.seam_mode="adaptive";PairRenderer original(c,o);
  o.seam_mode="parallax";PairRenderer guarded(c,o);
  cv::Mat a(c.input_size,CV_8UC3,cv::Scalar(90,90,90)),b(c.input_size,CV_8UC3,cv::Scalar(95,95,95));
  const auto before=original.render(a,b,true),after=guarded.render(a,b,true);
  EXPECT_FALSE(after.parallax_guard);EXPECT_EQ(after.correspondence_count,0);
  EXPECT_EQ(cv::norm(before.image,after.image,cv::NORM_INF),0);
}

TEST(Render, PrimaryCameraOwnsCentralViewForBothPairOrientations) {
  for(const auto view:{"front","back"}) {
    auto c=loadCalibration(RIG_FILE,view);RenderOptions o;o.width=320;o.height=160;
    o.seam_mode="primary_a";o.exposure_compensation=false;
    PairRenderer renderer(c,o);
    cv::Mat a(c.input_size,CV_8UC3,cv::Scalar(200,0,0)),b(c.input_size,CV_8UC3,cv::Scalar(0,0,200));
    const auto result=renderer.render(a,b,true);
    EXPECT_FALSE(result.adaptive_seam);EXPECT_FALSE(result.parallax_guard);
    // A near target across the center must never be cut between the two source views.
    for(int y=0;y<o.height;++y)for(int x=144;x<176;++x)
      EXPECT_EQ(result.image.at<cv::Vec3b>(y,x),cv::Vec3b(200,0,0));
    EXPECT_GT(cv::countNonZero(result.owner==2),0);
    EXPECT_EQ(cv::countNonZero((result.owner>0)!=(result.valid_mask>0)),0);
  }
}

TEST(Render, ParallaxGuardPreservesSourcePixelsAndReportsConflicts) {
  PairCalibration c;c.input_size={640,480};c.rotation=cv::Matx33d::eye();c.translation={0,0,0};
  for(auto &camera:c.cameras)camera.k={300,300,320,240,0,0,0,0};
  RenderOptions o;o.width=640;o.height=320;o.horizontal_fov_deg=100;o.vertical_fov_deg=60;
  o.reference_depth_m=0;o.seam_mode="parallax";o.feather_px=0;o.exposure_compensation=false;
  cv::Mat a(c.input_size,CV_8UC3,cv::Scalar(100,100,100)),b=a.clone();
  cv::Mat target(200,150,CV_8UC3);cv::RNG rng(12345);rng.fill(target,cv::RNG::UNIFORM,0,255);
  cv::GaussianBlur(target,target,{3,3},.5);
  target.copyTo(a(cv::Rect(270,140,150,200)));target.copyTo(b(cv::Rect(220,140,150,200)));
  PairRenderer renderer(c,o);const auto result=renderer.render(a,b,true);const auto inputs=renderer.projectInputs(a,b);
  EXPECT_GE(result.correspondence_count,6);EXPECT_TRUE(result.parallax_guard);
  EXPECT_LT(result.seam_conflict_fraction,.15);
  // Every displayed pixel still comes from exactly one calibrated source; no local bending/inpainting.
  for(int y=0;y<o.height;++y)for(int x=0;x<o.width;++x) {
    const int owner=result.owner.at<unsigned char>(y,x);
    if(owner)EXPECT_EQ(result.image.at<cv::Vec3b>(y,x),inputs[owner-1].at<cv::Vec3b>(y,x));
  }
  // A new textureless pair must discard old correspondence protection.
  a.setTo(cv::Scalar(100,100,100));b.setTo(cv::Scalar(100,100,100));
  const auto empty=renderer.render(a,b,true);EXPECT_FALSE(empty.parallax_guard);EXPECT_EQ(empty.correspondence_count,0);
}
TEST(Pairing, RejectsStaleMismatchAndOutOfOrderAndBoundsMemory) {
  PairBuffer<int> b;b.push(0,100,1000,1);b.push(1,110,1001,2);
  EXPECT_FALSE(b.take(1002,100,5));EXPECT_FALSE(b.push(0,99,1003,3));
  EXPECT_FALSE(b.take(1200,100,20));
  for(int i=0;i<100;++i)b.push(0,200+i,1200+i,i);
  EXPECT_LE(b.size(0),8U);b.clear();EXPECT_TRUE(b.push(0,1,1400,1));
}

namespace {
cv::Matx33d yaw(double degrees) {
  const double r=degrees*std::acos(-1.)/180;
  return {std::cos(r),0,std::sin(r),0,1,0,-std::sin(r),0,std::cos(r)};
}
// Two equidistant fisheyes 0.4 m apart and diverging by +-30 degrees, like the real pairs.
PairCalibration syntheticRig() {
  PairCalibration c;c.input_size={640,480};
  for(auto &camera:c.cameras)camera.k={200,200,320,240,0,0,0,0};
  c.rotation=yaw(30).t()*yaw(-30);c.translation=yaw(30).t()*cv::Vec3d(-.4,0,0);
  return c;
}
// A textured sphere of the given radius around the camera midpoint, seen from a camera at x.
cv::Mat sphereView(const cv::Mat &texture,double radius,double yaw_deg,double x) {
  const double pi=std::acos(-1.);const cv::Vec3d center(-x,0,0);
  cv::Mat mx(480,640,CV_32F),my(480,640,CV_32F);
  for(int row=0;row<480;++row)for(int col=0;col<640;++col) {
    const double u=(col-320)/200.,v=(row-240)/200.,theta=std::hypot(u,v);
    cv::Vec3d ray=theta<1e-9?cv::Vec3d(0,0,1):cv::Vec3d(std::sin(theta)*u/theta,std::sin(theta)*v/theta,std::cos(theta));
    ray=yaw(yaw_deg)*ray;
    const double b=ray.dot(center),s=b+std::sqrt(b*b-center.dot(center)+radius*radius);
    const cv::Vec3d p=(ray*s-center)/radius;
    mx.at<float>(row,col)=float((std::atan2(p[0],p[2])/pi*.5+.5)*texture.cols-.5);
    my.at<float>(row,col)=float((std::asin(p[1])/pi+.5)*texture.rows-.5);
  }
  cv::Mat view;cv::remap(texture,view,mx,my,cv::INTER_LINEAR,cv::BORDER_REFLECT);
  return view;
}
}

TEST(Render, DepthSeamMeasuresNearSurfaceAndAlignsTheSeam) {
  const auto c=syntheticRig();const double radius=1.2;
  cv::Mat texture(360,720,CV_8U);cv::RNG rng(7);rng.fill(texture,cv::RNG::UNIFORM,0,255);
  cv::GaussianBlur(texture,texture,{0,0},2);cv::normalize(texture,texture,0,255,cv::NORM_MINMAX);
  cv::cvtColor(texture,texture,cv::COLOR_GRAY2RGB);
  const auto a=sphereView(texture,radius,-30,-.2),b=sphereView(texture,radius,30,.2);
  RenderOptions o;o.width=512;o.height=256;o.exposure_compensation=false;
  o.seam_mode="fixed";PairRenderer fixed(c,o);
  o.seam_mode="depth_seam";PairRenderer depth(c,o);
  ASSERT_TRUE(depth.aOnLeft());
  const auto plain=fixed.render(a,b,true),measured=depth.render(a,b,true);
  ASSERT_TRUE(measured.adaptive_seam);ASSERT_EQ(int(measured.seam_inverse_depth.size()),o.height);
  EXPECT_GT(measured.depth_valid_fraction,.8);
  for(int y=o.height/8;y<o.height*7/8;++y)EXPECT_NEAR(measured.seam_inverse_depth[y],1/radius,.04)<<y;
  // Both projections agree where the seam blends them; on the 3 m reference sphere they do not.
  const auto seamError=[&](PairRenderer &renderer,const RenderResult &result) {
    const auto inputs=renderer.projectInputs(a,b);double sum=0;int count=0;
    for(int y=o.height/8;y<o.height*7/8;++y)for(int dx=-3;dx<=3;++dx) {
      const int x=int(result.seam[y])+dx;
      sum+=cv::norm(cv::Vec3d(inputs[0].at<cv::Vec3b>(y,x))-cv::Vec3d(inputs[1].at<cv::Vec3b>(y,x)));++count;
    }
    return sum/count;
  };
  EXPECT_LT(seamError(depth,measured),.25*seamError(fixed,plain));
  EXPECT_EQ(cv::countNonZero((measured.owner>0)!=(measured.valid_mask>0)),0);
}

TEST(Render, DepthSeamFallsBackSmoothlyOnFlatInputAndValidatesOptions) {
  const auto c=syntheticRig();
  cv::Mat texture(360,720,CV_8U);cv::RNG rng(11);rng.fill(texture,cv::RNG::UNIFORM,0,255);
  cv::GaussianBlur(texture,texture,{0,0},2);cv::normalize(texture,texture,0,255,cv::NORM_MINMAX);
  cv::cvtColor(texture,texture,cv::COLOR_GRAY2RGB);
  RenderOptions o;o.width=512;o.height=256;o.seam_mode="depth_seam";
  PairRenderer renderer(c,o);
  const auto near=renderer.render(sphereView(texture,.8,-30,-.2),sphereView(texture,.8,30,.2),true);
  const cv::Mat flat(c.input_size,CV_8UC3,cv::Scalar(90,90,90));
  const auto after=renderer.render(flat,flat,true);
  EXPECT_EQ(after.depth_valid_fraction,0);
  // Without measurements the seam depth eases toward the reference sphere and the seam moves boundedly.
  for(int y=0;y<o.height;++y) {
    EXPECT_LT(after.seam_inverse_depth[y],near.seam_inverse_depth[y]);EXPECT_GT(after.seam_inverse_depth[y],1.f/3);
    EXPECT_LE(std::abs(after.seam[y]-near.seam[y]),8.001);
  }
  auto bad=o;bad.min_depth_m=.1;EXPECT_THROW(PairRenderer(c,bad),std::invalid_argument);
  bad=o;bad.depth_band_deg=0;EXPECT_THROW(PairRenderer(c,bad),std::invalid_argument);
  auto coincident=c;coincident.translation={0,0,0};EXPECT_THROW(PairRenderer(coincident,o),std::invalid_argument);
}
