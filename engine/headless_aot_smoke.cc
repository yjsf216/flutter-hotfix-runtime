// Host-only verification harness: no window, display, device or simulator.
// Dart reports raw UTF-8 "PASS" or "FAIL:<reason>" on hotfix/runtime-smoke.
// Success also requires a real software surface callback from an AOT Engine.
// This protocol verifies the fixture's assertions and frame delivery; it does
// not independently establish patch semantics or identify a rendered widget.
#include "embedder.h"

#include <dlfcn.h>

#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <mutex>
#include <queue>
#include <stdexcept>
#include <string>
#include <thread>

using Clock = std::chrono::steady_clock;
constexpr size_t kWidth = 320;
constexpr size_t kHeight = 240;
constexpr size_t kMaxQueuedTasks = 100000;
constexpr char kChannel[] = "hotfix/runtime-smoke";

// The event loop supplies the normal deadline. Native initialization, RunTask,
// or shutdown can itself hang; the watchdog enforces a hard failure deadline.
class Watchdog {
 public:
  explicit Watchdog(int seconds) : thread_([this, seconds] {
    std::unique_lock<std::mutex> lock(mutex_);
    if (!changed_.wait_for(lock, std::chrono::seconds(seconds + 5),
                           [this] { return done_; })) {
      std::fputs("FAIL: Engine exceeded hard timeout; graceful shutdown unavailable\n", stderr);
      std::_Exit(124);
    }
  }) {}
  ~Watchdog() {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      done_ = true;
    }
    changed_.notify_one();
    thread_.join();
  }

 private:
  std::mutex mutex_;
  std::condition_variable changed_;
  bool done_ = false;
  std::thread thread_;
};

struct Library {
  explicit Library(const char* path) : handle(dlopen(path, RTLD_NOW | RTLD_LOCAL)) {
    if (!handle) throw std::runtime_error(std::string("dlopen: ") + dlerror());
  }
  ~Library() { dlclose(handle); }
  void* handle;
};

void Require(FlutterEngineResult result, const char* operation) {
  if (result != kSuccess) {
    throw std::runtime_error(std::string(operation) + " returned " +
                             std::to_string(result));
  }
}

struct Task {
  uint64_t target;
  uint64_t sequence;
  FlutterTask task;
  bool operator<(const Task& other) const {
    return target == other.target ? sequence > other.sequence : target > other.target;
  }
};

struct Runner {
  FlutterEngineProcTable api{};
  FlutterEngine engine = nullptr;
  FlutterEngineAOTData aot = nullptr;
  const std::thread::id platform_thread = std::this_thread::get_id();
  std::mutex mutex;
  std::condition_variable changed;
  std::priority_queue<Task> tasks;
  uint64_t sequence = 0;
  uint64_t frames = 0;
  uint64_t last_hash = 0;
  bool dart_pass = false;
  std::string error;

  ~Runner() { Shutdown(); }

  void Shutdown() {
    if (engine) {
      const auto result = api.Shutdown(engine);
      if (result != kSuccess) {
        // Callback/VM lifetime is now uncertain. Do not free their context,
        // collect mapped AOT code or unload the Engine under live threads.
        std::fprintf(stderr, "FAIL: Shutdown returned %d\n", result);
        std::_Exit(1);
      }
      engine = nullptr;
      std::lock_guard<std::mutex> lock(mutex);
      tasks = {};
    }
    if (aot) {
      const auto result = api.CollectAOTData(aot);
      aot = nullptr;
      if (result != kSuccess) {
        std::fprintf(stderr, "FAIL: CollectAOTData returned %d\n", result);
        std::_Exit(1);
      }
    }
  }

  void Fail(const std::string& reason) {
    {
      std::lock_guard<std::mutex> lock(mutex);
      if (error.empty()) error = reason;
    }
    changed.notify_one();
  }

  static bool RunsHere(void* data) {
    return static_cast<Runner*>(data)->platform_thread == std::this_thread::get_id();
  }

  static void PostTask(FlutterTask task, uint64_t target, void* data) {
    auto& runner = *static_cast<Runner*>(data);
    {
      std::lock_guard<std::mutex> lock(runner.mutex);
      if (runner.tasks.size() >= kMaxQueuedTasks) {
        runner.error = "platform task queue limit exceeded";
      } else {
        runner.tasks.push({target, runner.sequence++, task});
      }
    }
    runner.changed.notify_one();
  }

  static bool Present(void* data, const void* pixels, size_t row_bytes, size_t height) {
    auto& runner = *static_cast<Runner*>(data);
    if (!pixels || row_bytes < kWidth * 4 || height != kHeight) {
      runner.Fail("invalid software surface geometry");
      return false;
    }
    // FNV-1a is a diagnostic frame fingerprint, not a security digest. Ignore
    // row padding and consume the Engine-owned pixels only within the callback.
    uint64_t hash = UINT64_C(14695981039346656037);
    const auto* bytes = static_cast<const uint8_t*>(pixels);
    for (size_t row = 0; row < height; ++row) {
      for (size_t column = 0; column < kWidth * 4; ++column) {
        hash = (hash ^ bytes[row * row_bytes + column]) * UINT64_C(1099511628211);
      }
    }
    uint64_t frame;
    {
      std::lock_guard<std::mutex> lock(runner.mutex);
      frame = ++runner.frames;
      runner.last_hash = hash;
    }
    std::fprintf(stdout, "FRAME %llu %zux%zu fnv64=%016llx\n",
                 static_cast<unsigned long long>(frame), kWidth, height,
                 static_cast<unsigned long long>(hash));
    std::fflush(stdout);
    runner.changed.notify_one();
    return true;
  }

  static void Message(const FlutterPlatformMessage* message, void* data) {
    auto& runner = *static_cast<Runner*>(data);
    // A response consumes the incoming message/handle: copy needed data first.
    const bool report = message->channel && std::strcmp(message->channel, kChannel) == 0;
    const bool valid = message->message_size <= 4096 &&
                       (message->message_size == 0 || message->message != nullptr);
    const std::string payload = report && valid && message->message_size != 0
        ? std::string(reinterpret_cast<const char*>(message->message), message->message_size)
        : std::string();
    if (message->response_handle) {
      const auto response = runner.api.SendPlatformMessageResponse(
          runner.engine, message->response_handle, nullptr, 0);
      if (response != kSuccess) {
        runner.Fail("SendPlatformMessageResponse failed");
        return;
      }
    }
    if (!report) return;
    if (!valid || payload != "PASS") {
      runner.Fail(valid ? "Dart result: " + payload : "invalid Dart result message");
      return;
    }
    {
      std::lock_guard<std::mutex> lock(runner.mutex);
      runner.dart_pass = true;
    }
    runner.changed.notify_one();
  }

  void Pump(Clock::time_point deadline) {
    std::unique_lock<std::mutex> lock(mutex);
    while (true) {
      if (!error.empty()) throw std::runtime_error(error);
      if (dart_pass && frames > 0) return;
      const auto now = Clock::now();
      if (now >= deadline) throw std::runtime_error("timeout waiting for Dart PASS and software frame");
      auto delay = std::chrono::duration_cast<std::chrono::nanoseconds>(deadline - now);
      if (!tasks.empty()) {
        const uint64_t engine_now = api.GetCurrentTime();
        if (tasks.top().target <= engine_now) {
          const FlutterTask task = tasks.top().task;
          tasks.pop();
          lock.unlock();
          Require(api.RunTask(engine, &task), "RunTask");
          lock.lock();
          continue;
        }
        const uint64_t until_task = tasks.top().target - engine_now;
        if (until_task < static_cast<uint64_t>(delay.count())) {
          delay = std::chrono::nanoseconds(until_task);
        }
      }
      changed.wait_for(lock, delay);
    }
  }
};

int main(int argc, char** argv) {
  if (argc < 6) {
    std::fputs("usage: headless_aot_smoke ENGINE_LIBRARY AOT_ELF ASSETS ICU TIMEOUT_SECONDS [DART_ARGS...]\n", stderr);
    return 2;
  }
  int seconds = 0;
  const char* end = argv[5] + std::strlen(argv[5]);
  const auto parsed = std::from_chars(argv[5], end, seconds);
  if (parsed.ec != std::errc() || parsed.ptr != end || seconds < 1 || seconds > 300) {
    std::fputs("FAIL: timeout must be 1..300 seconds\n", stderr);
    return 2;
  }
  const auto deadline = Clock::now() + std::chrono::seconds(seconds);
  Watchdog watchdog(seconds);
  try {
    Library library(argv[1]);
    auto get_procs = reinterpret_cast<FlutterEngineResult (*)(FlutterEngineProcTable*)>(
        dlsym(library.handle, "FlutterEngineGetProcAddresses"));
    if (!get_procs) throw std::runtime_error("missing FlutterEngineGetProcAddresses");
    Runner runner;
    runner.api.struct_size = sizeof(runner.api);
    Require(get_procs(&runner.api), "GetProcAddresses");
    if (!runner.api.RunsAOTCompiledDartCode || !runner.api.CreateAOTData ||
        !runner.api.CollectAOTData || !runner.api.Initialize || !runner.api.RunInitialized ||
        !runner.api.Shutdown || !runner.api.RunTask || !runner.api.GetCurrentTime ||
        !runner.api.SendWindowMetricsEvent || !runner.api.SendPlatformMessageResponse) {
      throw std::runtime_error("incomplete Flutter Engine proc table");
    }
    if (!runner.api.RunsAOTCompiledDartCode()) {
      throw std::runtime_error("Engine does not run AOT-compiled Dart code");
    }
    const std::string elf = std::filesystem::absolute(argv[2]).string();
    const std::string assets = std::filesystem::absolute(argv[3]).string();
    const std::string icu = std::filesystem::absolute(argv[4]).string();
    if (!std::filesystem::is_regular_file(elf) || !std::filesystem::is_directory(assets) ||
        !std::filesystem::is_regular_file(icu)) {
      throw std::runtime_error("AOT ELF, assets directory and ICU file must exist");
    }
    FlutterEngineAOTDataSource source{};
    source.type = kFlutterEngineAOTDataSourceTypeElfPath;
    source.elf_path = elf.c_str();
    Require(runner.api.CreateAOTData(&source, &runner.aot), "CreateAOTData");
    FlutterTaskRunnerDescription platform{};
    platform.struct_size = sizeof(platform);
    platform.user_data = &runner;
    platform.runs_task_on_current_thread_callback = Runner::RunsHere;
    platform.post_task_callback = Runner::PostTask;
    platform.identifier = 1;
    FlutterCustomTaskRunners task_runners{};
    task_runners.struct_size = sizeof(task_runners);
    task_runners.platform_task_runner = &platform;
    FlutterRendererConfig renderer{};
    renderer.type = kSoftware;
    renderer.software.struct_size = sizeof(renderer.software);
    renderer.software.surface_present_callback = Runner::Present;
    FlutterProjectArgs project{};
    project.struct_size = sizeof(project);
    project.assets_path = assets.c_str();
    project.icu_data_path = icu.c_str();
    project.platform_message_callback = Runner::Message;
    project.custom_task_runners = &task_runners;
    project.shutdown_dart_vm_when_done = true;
    project.aot_data = runner.aot;
    project.dart_entrypoint_argc = argc - 6;
    project.dart_entrypoint_argv = argv + 6;
    Require(runner.api.Initialize(FLUTTER_ENGINE_VERSION, &renderer, &project,
                                  &runner, &runner.engine), "Initialize");
    Require(runner.api.RunInitialized(runner.engine), "RunInitialized");
    FlutterWindowMetricsEvent metrics{};
    metrics.struct_size = sizeof(metrics);
    metrics.width = kWidth;
    metrics.height = kHeight;
    metrics.pixel_ratio = 1.0;
    Require(runner.api.SendWindowMetricsEvent(runner.engine, &metrics), "SendWindowMetricsEvent");
    runner.Pump(deadline);
    runner.Shutdown();
    std::printf("PASS: actual AOT Engine, Dart PASS, software_frames=%llu last_fnv64=%016llx\n",
                static_cast<unsigned long long>(runner.frames),
                static_cast<unsigned long long>(runner.last_hash));
    return 0;
  } catch (const std::exception& error) {
    std::fprintf(stderr, "FAIL: %s\n", error.what());
    return 1;
  }
}
