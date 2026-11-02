// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <array>
#include <string>
#include <vector>
#include <opencv2/core.hpp>

namespace zephyr_surround_vision {
struct CameraModel {
  std::string name, frame, sensor;
  std::array<double, 8> k{};
};
struct PairCalibration {
  std::array<CameraModel, 2> cameras;
  cv::Size input_size;
  cv::Matx33d rotation;
  cv::Vec3d translation;
  std::string status;
};
PairCalibration loadCalibration(const std::string &file, const std::string &view);
cv::Point2d projectKB4(const cv::Vec3d &ray, const std::array<double, 8> &k);

struct RenderOptions {
  int width=1024, height=512;
  double horizontal_fov_deg=180, vertical_fov_deg=90;
  double reference_depth_m=3.0;  // 0 = infinity; otherwise an assumed sphere, not measured depth.
  std::string seam_mode="adaptive";
  double seam_search_deg=70, feather_px=10;
  bool exposure_compensation=true;
  // depth_seam only: nearest swept depth, and per side of the seam the width held
  // at the measured seam depth followed by the minimum ramp back to reference_depth_m.
  // The ramp widens for near seams so the displayed image is compressed at most 1.5x.
  double min_depth_m=0.4, depth_core_deg=4, depth_band_deg=20;
};
struct RenderResult {
  cv::Mat image, valid_mask, owner;
  std::vector<float> seam;
  double gain=1;
  bool adaptive_seam=false;
  int correspondence_count=0;
  bool parallax_guard=false;
  double seam_conflict_fraction=0;
  std::vector<float> seam_inverse_depth;  // depth_seam: per output row, 1/m from the camera midpoint.
  double depth_valid_fraction=0;          // depth_seam: seam rows with a measured (not interpolated) depth.
};

// Geometry/LUT construction is separate from ROS acquisition and scheduling.
// A future 360 or ground renderer can reuse the same bounded input pipeline.
class PairRenderer {
public:
  PairRenderer(PairCalibration calibration, RenderOptions options);
  RenderResult render(const cv::Mat &a, const cv::Mat &b, bool update_seam);
  std::array<cv::Mat,2> projectInputs(const cv::Mat &a, const cv::Mat &b) const;
  const PairCalibration &calibration() const {return calibration_;}
  const cv::Matx33d &virtualBasisInA() const {return basis_;}
  const cv::Mat &validMask() const {return valid_;}
  bool aOnLeft() const {return a_left_;}
  // depth_seam diagnostics: last inverse depth (1/m) on the sweep grid, NaN where unmeasured.
  const cv::Mat &depthMap() const {return depth_.rho_map;}
private:
  // Plane-sweep state for depth_seam; empty for the other modes.
  struct DepthSweep {
    cv::Size grid, source;
    cv::Rect roi;  // swept columns on the grid
    std::vector<float> rho;
    std::vector<std::array<cv::Mat, 2>> map1, map2;
    std::vector<cv::Mat> valid;
    cv::Mat both_valid, rho_map;
    std::array<cv::Mat, 2> base_x, base_y, base_mask, map_x, map_y;
    std::vector<float> seam_rho;
    // Per output row band geometry in pixels: as applied to the maps, and the columns it covers.
    std::vector<cv::Vec4f> applied;  // center, core half width, ramp, inverse depth
    std::vector<cv::Vec2i> extent;
    bool initialized=false;
    double valid_fraction=0;
  };
  void updateSeam(const cv::Mat &a, const cv::Mat &b);
  void updateParallaxGuard(const cv::Mat &a, const cv::Mat &b);
  void buildDepthSweep();
  void updateDepthSeam(const cv::Mat &a, const cv::Mat &b);
  void rebuildDepthBand();
  bool projectAtDepth(const cv::Vec3d &direction, double rho, int camera, cv::Point2d &pixel) const;
  PairCalibration calibration_;
  RenderOptions options_;
  cv::Matx33d basis_;
  std::array<cv::Mat, 2> maps1_, maps2_, masks_;
  cv::Mat valid_, small_mask_a_, small_mask_b_;
  cv::Mat seam_risk_, primary_weight_;
  std::vector<float> seam_;
  double gain_=1;
  bool a_left_=true, seam_initialized_=false, adaptive_valid_=false;
  int correspondence_count_=0;
  bool parallax_guard_=false;
  DepthSweep depth_;
};
}  // namespace zephyr_surround_vision
