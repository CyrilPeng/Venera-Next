#ifndef RUNNER_HEARTBEAT_MONITOR_H_
#define RUNNER_HEARTBEAT_MONITOR_H_

#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <thread>

// The host serializes Start/Stop/Shutdown. The worker only observes deadlines.
// A new registration replaces the old owner; stale beats/stops are ignored.
class HeartbeatMonitor {
 public:
  explicit HeartbeatMonitor(
      std::function<void()> on_timeout,
      std::chrono::steady_clock::duration timeout = std::chrono::seconds(5));
  ~HeartbeatMonitor();

  HeartbeatMonitor(const HeartbeatMonitor&) = delete;
  HeartbeatMonitor& operator=(const HeartbeatMonitor&) = delete;

  std::int64_t Start();
  void Beat(std::int64_t owner);
  void Stop(std::int64_t owner);
  void Shutdown();

 private:
  void Run();

  const std::function<void()> on_timeout_;
  const std::chrono::steady_clock::duration timeout_;
  std::mutex mutex_;
  std::condition_variable changed_;
  std::thread worker_;
  std::int64_t owner_ = 0;
  bool running_ = false;
  std::chrono::steady_clock::time_point last_;
};

#endif  // RUNNER_HEARTBEAT_MONITOR_H_
