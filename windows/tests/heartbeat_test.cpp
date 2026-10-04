#include "heartbeat_monitor.h"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <future>
#include <iostream>
#include <thread>

using namespace std::chrono_literals;

namespace {
void Check(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAILED: " << message << '\n';
    std::exit(EXIT_FAILURE);
  }
}

void TestTimeoutAndRestart() {
  std::promise<void> expired;
  HeartbeatMonitor monitor([&] { expired.set_value(); }, 40ms);
  const auto first = monitor.Start();
  Check(expired.get_future().wait_for(3s) == std::future_status::ready,
        "missing heartbeat must expire");
  monitor.Stop(first);
  const auto second = monitor.Start();
  Check(second > first, "restart must allocate a distinct owner");
  monitor.Stop(second);
  monitor.Stop(second);
}

void TestStaleOwner() {
  std::promise<void> expired;
  auto expiration = expired.get_future();
  HeartbeatMonitor monitor([&] { expired.set_value(); }, 100ms);
  const auto old_owner = monitor.Start();
  const auto new_owner = monitor.Start();
  monitor.Stop(old_owner);
  const auto deadline = std::chrono::steady_clock::now() + 3s;
  while (expiration.wait_for(1ms) != std::future_status::ready &&
         std::chrono::steady_clock::now() < deadline) {
    monitor.Beat(old_owner);
  }
  Check(expiration.wait_for(0ms) == std::future_status::ready,
        "old stop or beats must not disable or refresh the new owner");
  monitor.Stop(new_owner);
}

void TestLiveOwnerAndPromptStop() {
  std::atomic<bool> expired{false};
  HeartbeatMonitor monitor([&] { expired = true; }, 1s);
  const auto owner = monitor.Start();
  const auto deadline = std::chrono::steady_clock::now() + 1500ms;
  while (std::chrono::steady_clock::now() < deadline) {
    monitor.Beat(owner);
    std::this_thread::sleep_for(5ms);
  }
  Check(!expired, "current beats must keep the monitor alive");
  auto stopping = std::async(std::launch::async, [&] { monitor.Stop(owner); });
  Check(stopping.wait_for(500ms) == std::future_status::ready,
        "stop must wake the deadline wait without waiting for its timeout");
  stopping.get();
  monitor.Beat(owner);
  Check(!expired, "stopped monitor must remain stopped after a late beat");
}

void TestStopJoinsCallback() {
  std::promise<void> entered;
  std::promise<void> release;
  auto releasing = release.get_future();
  HeartbeatMonitor monitor([&] {
    entered.set_value();
    releasing.wait();
  }, 10ms);
  const auto owner = monitor.Start();
  Check(entered.get_future().wait_for(3s) == std::future_status::ready,
        "timeout callback must start");
  auto stopping = std::async(std::launch::async, [&] { monitor.Stop(owner); });
  Check(stopping.wait_for(20ms) == std::future_status::timeout,
        "stop must wait for actual worker completion");
  release.set_value();
  Check(stopping.wait_for(3s) == std::future_status::ready,
        "stop must complete after the worker returns");
  stopping.get();
}

void TestLateBeatAfterStop() {
  std::atomic<bool> expired{false};
  HeartbeatMonitor monitor([&] { expired = true; }, 100ms);
  const auto owner = monitor.Start();
  monitor.Stop(owner);
  monitor.Beat(owner);
  std::this_thread::sleep_for(200ms);
  Check(!expired, "a late heartbeat must not restart a stopped monitor");
}

void TestDestructorAndIndependentWindows() {
  std::promise<void> expired;
  HeartbeatMonitor second([&] { expired.set_value(); }, 100ms);
  second.Start();
  {
    HeartbeatMonitor first([] { Check(false, "destroyed monitor expired"); });
    const auto owner = first.Start();
    first.Beat(owner);
  }
  Check(expired.get_future().wait_for(3s) == std::future_status::ready,
        "destroying one window must not stop another monitor");
  second.Shutdown();
}
}  // namespace

int main() {
  TestTimeoutAndRestart();
  TestStaleOwner();
  TestLiveOwnerAndPromptStop();
  TestStopJoinsCallback();
  TestLateBeatAfterStop();
  TestDestructorAndIndependentWindows();
  std::cout << "Heartbeat lifecycle tests passed.\n";
  return EXIT_SUCCESS;
}
