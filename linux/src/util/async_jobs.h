#pragma once

// A small worker pool for adb round trips so the UI thread never blocks on the
// device. `run()` queues work for a worker; its completion is queued back and
// executed by whoever calls `pump()` (the UI thread, once per frame).

#include <condition_variable>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace rplayhub {

class AsyncJobs {
public:
    explicit AsyncJobs(int threads = 2) {
        for (int i = 0; i < threads; ++i) {
            workers_.emplace_back([this] { workerLoop(); });
        }
    }

    ~AsyncJobs() { shutdown(); }

    AsyncJobs(const AsyncJobs&) = delete;
    AsyncJobs& operator=(const AsyncJobs&) = delete;

    // `work` runs on a worker thread; `done` (optional) runs on the pump() thread afterwards.
    void run(std::function<void()> work, std::function<void()> done = {}) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) return;
            jobs_.push_back({std::move(work), std::move(done)});
        }
        cv_.notify_one();
    }

    // Typed variant: `work` produces a T on a worker, `done(T)` receives it on the pump() thread.
    template <typename T>
    void run(std::function<T()> work, std::function<void(T)> done) {
        auto slot = std::make_shared<T>();
        run([work = std::move(work), slot] { *slot = work(); },
            [done = std::move(done), slot] { done(std::move(*slot)); });
    }

    // Drain completions. Call from the UI thread every frame.
    void pump() {
        std::deque<std::function<void()>> ready;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            ready.swap(completions_);
        }
        for (auto& fn : ready) {
            if (fn) fn();
        }
    }

    void shutdown() {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (stopping_) return;
            stopping_ = true;
            jobs_.clear();
        }
        cv_.notify_all();
        for (auto& t : workers_) {
            if (t.joinable()) t.join();
        }
        workers_.clear();
        std::lock_guard<std::mutex> lock(mutex_);
        completions_.clear();
    }

    bool idle() {
        std::lock_guard<std::mutex> lock(mutex_);
        return jobs_.empty() && running_ == 0;
    }

private:
    struct Job {
        std::function<void()> work;
        std::function<void()> done;
    };

    void workerLoop() {
        while (true) {
            Job job;
            {
                std::unique_lock<std::mutex> lock(mutex_);
                cv_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
                if (stopping_) return;
                job = std::move(jobs_.front());
                jobs_.pop_front();
                ++running_;
            }
            if (job.work) job.work();
            {
                std::lock_guard<std::mutex> lock(mutex_);
                --running_;
                if (!stopping_ && job.done) completions_.push_back(std::move(job.done));
            }
        }
    }

    std::mutex mutex_;
    std::condition_variable cv_;
    std::deque<Job> jobs_;
    std::deque<std::function<void()>> completions_;
    std::vector<std::thread> workers_;
    int running_ = 0;
    bool stopping_ = false;
};

} // namespace rplayhub
