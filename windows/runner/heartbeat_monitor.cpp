#include "heartbeat_monitor.h"

#include <utility>

HeartbeatMonitor::HeartbeatMonitor(
    std::function<void()> on_timeout,
    std::chrono::steady_clock::duration timeout)
    : on_timeout_(std::move(on_timeout)), timeout_(timeout) {}

HeartbeatMonitor::~HeartbeatMonitor() { Shutdown(); }

std::int64_t HeartbeatMonitor::Start() {
  Shutdown();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    ++owner_;
    last_ = std::chrono::steady_clock::now();
    running_ = true;
  }
  worker_ = std::thread([this] { Run(); });
  return owner_;
}

void HeartbeatMonitor::Beat(std::int64_t owner) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_ || owner != owner_) return;
    last_ = std::chrono::steady_clock::now();
  }
  changed_.notify_all();
}

void HeartbeatMonitor::Stop(std::int64_t owner) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (owner != owner_) return;
    running_ = false;
  }
  changed_.notify_all();
  if (worker_.joinable()) worker_.join();
}

void HeartbeatMonitor::Shutdown() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
  }
  changed_.notify_all();
  if (worker_.joinable()) worker_.join();
}

void HeartbeatMonitor::Run() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (running_) {
    const auto deadline = last_ + timeout_;
    if (changed_.wait_until(lock, deadline, [this, deadline] {
          return !running_ || last_ + timeout_ != deadline;
        })) {
      continue;
    }
    running_ = false;
    lock.unlock();
    on_timeout_();
    return;
  }
}
