#ifndef SIMPLE_SWITCH_SIMPLE_SWITCH_H_
#define SIMPLE_SWITCH_SIMPLE_SWITCH_H_

#include <bm/bm_sim/queue.h>
#include <bm/bm_sim/queueing.h>
#include <bm/bm_sim/packet.h>
#include <bm/bm_sim/switch.h>
#include <bm/bm_sim/event_logger.h>
#include <bm/bm_sim/simple_pre_lag.h>

#include <memory>
#include <chrono>
#include <thread>
#include <vector>
#include <functional>

#include "my_priority_queues.h"

#define SSWITCH_PRIORITY_QUEUEING_ON

#ifdef SSWITCH_PRIORITY_QUEUEING_ON
#define SSWITCH_PRIORITY_QUEUEING_NB_QUEUES 32
#define SSWITCH_PRIORITY_QUEUEING_SRC "intrinsic_metadata.priority"
#endif

using ts_res = std::chrono::microseconds;
using std::chrono::duration_cast;
using ticks = std::chrono::nanoseconds;

using bm::Switch;
using bm::Queue;
using bm::Packet;
using bm::PHV;
using bm::Parser;
using bm::Deparser;
using bm::Pipeline;
using bm::McSimplePreLAG;
using bm::Field;
using bm::FieldList;
using bm::packet_id_t;
using bm::p4object_id_t;

class SimpleSwitch : public Switch {
 public:
  using mirror_id_t = int;
  using TransmitFn = std::function<void(port_t, packet_id_t, const char *, int)>;

  struct MirroringSessionConfig {
    port_t egress_port;
    bool egress_port_valid;
    unsigned int mgid;
    bool mgid_valid;
  };

  static constexpr port_t default_drop_port = 511;
  static constexpr uint32_t default_nb_queues_per_port = 1;

 private:
  using clock = std::chrono::high_resolution_clock;

  struct EgressThreadMapper {
    explicit EgressThreadMapper(size_t nb_threads)
        : nb_threads(nb_threads) { }

    size_t operator()(size_t egress_port) const {
      return egress_port % nb_threads;
    }

    size_t nb_threads;
  };

 public:
  explicit SimpleSwitch(bool enable_swap = false,
                        port_t drop_port = default_drop_port,
                        uint32_t priority_queues = default_nb_queues_per_port);

  ~SimpleSwitch();

  int receive_(port_t port_num, const char *buffer, int len) override;

  void start_and_return_() override;

  void reset_target_state_() override;

  void swap_notify_() override;

  bool mirroring_add_session(mirror_id_t mirror_id,
                             const MirroringSessionConfig &config);

  bool mirroring_delete_session(mirror_id_t mirror_id);

  bool mirroring_get_session(mirror_id_t mirror_id,
                             MirroringSessionConfig *config) const;

  int set_egress_queue_depth(size_t port, const size_t depth_pkts);
  int set_all_egress_queue_depths(const size_t depth_pkts);

  int set_egress_queue_rate(size_t port, const uint64_t rate_pps);
  int set_all_egress_queue_rates(const uint64_t rate_pps);

#ifdef SSWITCH_PRIORITY_QUEUEING_ON
  void rotate_priority(size_t port_id, size_t queue_id);
  size_t get_highest_pri_qid(size_t port_id) const;
  size_t get_queue_length(size_t port_id, size_t queue_id) const;
  int set_egress_priority_queue_depth(size_t port_id, size_t queue_id, size_t depth_pkts);
  int set_egress_priority_queue_rate(size_t port_id, size_t queue_id, uint64_t rate_pps);
#endif

  uint64_t get_time_elapsed_us() const;
  uint64_t get_time_since_epoch_us() const;

  static packet_id_t get_packet_id() {
    return packet_id - 1;
  }

  void set_transmit_fn(TransmitFn fn);

  port_t get_drop_port() const {
    return drop_port;
  }

  SimpleSwitch(const SimpleSwitch &) = delete;
  SimpleSwitch &operator =(const SimpleSwitch &) = delete;
  SimpleSwitch(SimpleSwitch &&) = delete;
  SimpleSwitch &&operator =(SimpleSwitch &&) = delete;

 private:
  static constexpr size_t nb_egress_threads = 16u;
  static packet_id_t packet_id;

  class MirroringSessions;
  class InputBuffer;

  enum PktInstanceType {
    PKT_INSTANCE_TYPE_NORMAL,
    PKT_INSTANCE_TYPE_INGRESS_CLONE,
    PKT_INSTANCE_TYPE_EGRESS_CLONE,
    PKT_INSTANCE_TYPE_COALESCED,
    PKT_INSTANCE_TYPE_RECIRC,
    PKT_INSTANCE_TYPE_REPLICATION,
    PKT_INSTANCE_TYPE_RESUBMIT,
  };

 private:
  void ingress_thread();
  void egress_thread(size_t worker_id);
  void transmit_thread();

  ts_res get_ts() const;

  void enqueue(port_t egress_port, std::unique_ptr<Packet> &&packet);

  void copy_field_list_and_set_type(
      const std::unique_ptr<Packet> &packet,
      const std::unique_ptr<Packet> &packet_copy,
      PktInstanceType copy_type, p4object_id_t field_list_id);

  void check_queueing_metadata();

  void multicast(Packet *packet, unsigned int mgid);

 private:
  port_t drop_port;
  uint32_t priority_queues;
  std::vector<std::thread> threads_;
  std::unique_ptr<InputBuffer> input_buffer;

#ifdef SSWITCH_PRIORITY_QUEUEING_ON
  MyPriorityQueues<std::unique_ptr<Packet>, EgressThreadMapper> egress_buffers;
#else
  bm::QueueingLogicRL<std::unique_ptr<Packet>, EgressThreadMapper> egress_buffers;
#endif

  Queue<std::unique_ptr<Packet> > output_buffer;
  TransmitFn my_transmit_fn;
  std::shared_ptr<McSimplePreLAG> pre;
  clock::time_point start;
  bool with_queueing_metadata{false};
  std::unique_ptr<MirroringSessions> mirroring_sessions;

};
extern SimpleSwitch *global_simple_switch_ptr;

#endif  // SIMPLE_SWITCH_SIMPLE_SWITCH_H_
