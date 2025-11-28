#include <bm/config.h>

#include <bm/SimpleSwitch.h>
#include <bm/bm_runtime/bm_runtime.h>
#include <bm/bm_sim/options_parse.h>
#include <bm/bm_sim/target_parser.h>

#include "simple_switch.h"

namespace {
SimpleSwitch *simple_switch;
}  // namespace

namespace sswitch_runtime {
shared_ptr<SimpleSwitchIf> get_handler(SimpleSwitch *sw);
}  // namespace sswitch_runtime

int
main(int argc, char* argv[]) {
  bm::TargetParserBasicWithDynModules simple_switch_parser;
  simple_switch_parser.add_flag_option(
      "enable-swap",
      "Enable JSON swapping at runtime");
  simple_switch_parser.add_uint_option(
      "drop-port",
      "Choose drop port number (default is 511)");
  simple_switch_parser.add_uint_option(
      "priority-queues",
      "Number of priority queues (default is 1)");

  bm::OptionsParser parser;
  parser.parse(argc, argv, &simple_switch_parser);

  bool enable_swap_flag = false;
  simple_switch_parser.get_flag_option("enable-swap", &enable_swap_flag);

  uint32_t drop_port = SimpleSwitch::default_drop_port;
  simple_switch_parser.get_uint_option("drop-port", &drop_port);

  uint32_t priority_queues = SimpleSwitch::default_nb_queues_per_port;
  simple_switch_parser.get_uint_option("priority-queues", &priority_queues);

  simple_switch = new SimpleSwitch(enable_swap_flag, drop_port, priority_queues);

  int status = simple_switch->init_from_options_parser(parser);
  if (status != 0) std::exit(status);

  int thrift_port = simple_switch->get_runtime_port();
  bm_runtime::start_server(simple_switch, thrift_port);

  using ::sswitch_runtime::SimpleSwitchIf;
  using ::sswitch_runtime::SimpleSwitchProcessor;
  bm_runtime::add_service<SimpleSwitchIf, SimpleSwitchProcessor>(
      "simple_switch", sswitch_runtime::get_handler(simple_switch));

  simple_switch->start_and_return();
  while (true) std::this_thread::sleep_for(std::chrono::seconds(100));

  return 0;
}
