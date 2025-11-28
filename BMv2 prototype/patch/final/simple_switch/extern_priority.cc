// extern_priority.cc
#include <bm/bm_sim/extern.h>
#include <bm/bm_sim/logger.h>
#include "simple_switch.h"

using namespace bm;

class PriorityExtern : public ExternType {
 public:
  PriorityExtern() {}
  ~PriorityExtern() override {}

  // init is optional
  void init() override { }

  // Extern methods that will be called from P4
  // Note: use width-compatible C++ types (use unsigned int for port/qid etc)
  void rotate_priority(bit<9> port_id, bit<5> queue_id) {
    // get the switch instance
    if (!global_simple_switch_ptr) {
      BMLOG_ERROR("global_simple_switch_ptr is null in rotate_priority");
      return;
    }
    size_t p = static_cast<size_t>(port_id);
    size_t q = static_cast<size_t>(queue_id);
    global_simple_switch_ptr->rotate_priority(p, q);
  }

  void read_highest_pri(bit<9> port_id, bit<5> *queue_id_out) {
    if (!global_simple_switch_ptr) {
      BMLOG_ERROR("global_simple_switch_ptr is null in read_highest_pri");
      *queue_id_out = 0;
      return;
    }
    size_t p = static_cast<size_t>(port_id);
    size_t q = global_simple_switch_ptr->get_highest_pri_qid(p);
    *queue_id_out = (bit<5>) q;
  }

  void get_queue_length(bit<9> port_id, bit<5> queue_id, bit<19> *qlen_out) {
    if (!global_simple_switch_ptr) {
      BMLOG_ERROR("global_simple_switch_ptr is null in get_queue_length");
      *qlen_out = 0;
      return;
    }
    size_t p = static_cast<size_t>(port_id);
    size_t q = static_cast<size_t>(queue_id);
    size_t len = global_simple_switch_ptr->get_queue_length(p, q);
    *qlen_out = (bit<19>) len;
  }
};

REGISTER_EXTERN(PriorityExtern)
REGISTER_EXTERN_METHOD(PriorityExtern, rotate_priority, rotate_priority, PARAMS(bit<9>, bit<5>))
REGISTER_EXTERN_METHOD(PriorityExtern, read_highest_pri, read_highest_pri, PARAMS(bit<9>, OUT(bit<5>)))
REGISTER_EXTERN_METHOD(PriorityExtern, get_queue_length, get_queue_length, PARAMS(bit<9>, bit<5>, OUT(bit<19>)))
