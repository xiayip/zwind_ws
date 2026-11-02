// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <array>
#include <cstdint>
#include <deque>
#include <optional>
#include <algorithm>

namespace zephyr_surround_vision {
// Bounded latest-pair matcher. Receipt times use a monotonic clock; image stamps
// are used only for pairing, never for computing age across different clocks.
template<class Payload> class PairBuffer {
public:
  struct Item {int64_t stamp, received;Payload payload;};
  bool push(int camera,int64_t stamp,int64_t received,Payload payload) {
    if(last_[camera] && stamp<=*last_[camera])return false;
    last_[camera]=stamp;
    auto &q=queues_[camera];q.push_back({stamp,received,std::move(payload)});
    if(q.size()>8)q.pop_front();
    return true;
  }
  std::optional<std::array<Item,2>> take(int64_t now,int64_t max_age,int64_t tolerance) {
    for(auto &q:queues_)while(!q.empty() && now-q.front().received>max_age)q.pop_front();
    int ai=-1,bi=-1;int64_t newest=INT64_MIN,best_spread=INT64_MAX;
    for(size_t i=0;i<queues_[0].size();++i)for(size_t j=0;j<queues_[1].size();++j) {
      const auto a=queues_[0][i].stamp,b=queues_[1][j].stamp;
      const int64_t spread=a>b?a-b:b-a,stamp=std::min(a,b);
      if(spread<=tolerance && (stamp>newest || (stamp==newest && spread<best_spread))) {
        ai=int(i);bi=int(j);newest=stamp;best_spread=spread;
      }
    }
    if(ai<0)return std::nullopt;
    std::array<Item,2> result={queues_[0][ai],queues_[1][bi]};
    queues_[0].erase(queues_[0].begin(),queues_[0].begin()+ai+1);
    queues_[1].erase(queues_[1].begin(),queues_[1].begin()+bi+1);
    return result;
  }
  void clear() {for(auto &q:queues_)q.clear();last_={};}
  size_t size(int camera)const {return queues_[camera].size();}
private:
  std::array<std::deque<Item>,2> queues_;
  std::array<std::optional<int64_t>,2> last_{};
};
}
