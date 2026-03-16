// cipher-mt5-bridge/dll/include/types_internal.h
// Internal type definitions and thread-safe queue

#pragma once

#include <string>
#include <vector>
#include <queue>
#include <mutex>
#include <condition_variable>
#include <optional>
#include <set>
#include <atomic>

namespace cipher {

// ============================================================================
// Parsed command from the gateway
// ============================================================================
struct ParsedCommand {
    int type;                    // BridgeCommandType enum
    std::string request_id;
    std::string params_json;     // Raw JSON of the "data" field
};

// ============================================================================
// Thread-safe queue
// ============================================================================
template<typename T>
class ThreadSafeQueue {
public:
    void push(T item) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.push(std::move(item));
        }
        cv_.notify_one();
    }

    std::optional<T> try_pop() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (queue_.empty()) return std::nullopt;
        T item = std::move(queue_.front());
        queue_.pop();
        return item;
    }

    T wait_pop() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return !queue_.empty(); });
        T item = std::move(queue_.front());
        queue_.pop();
        return item;
    }

    template<typename Rep, typename Period>
    std::optional<T> wait_pop_for(std::chrono::duration<Rep, Period> timeout) {
        std::unique_lock<std::mutex> lock(mutex_);
        if (!cv_.wait_for(lock, timeout, [this] { return !queue_.empty(); }))
            return std::nullopt;
        T item = std::move(queue_.front());
        queue_.pop();
        return item;
    }

    bool empty() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return queue_.empty();
    }

    size_t size() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return queue_.size();
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        std::queue<T> empty;
        std::swap(queue_, empty);
    }

private:
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::queue<T> queue_;
};

// ============================================================================
// Subscription tracker (thread-safe)
// ============================================================================
class SubscriptionTracker {
public:
    void add(const std::vector<std::string>& symbols) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto& s : symbols)
            symbols_.insert(s);
    }

    void remove(const std::vector<std::string>& symbols) {
        std::lock_guard<std::mutex> lock(mutex_);
        for (const auto& s : symbols)
            symbols_.erase(s);
    }

    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        symbols_.clear();
    }

    bool contains(const std::string& symbol) const {
        std::lock_guard<std::mutex> lock(mutex_);
        return symbols_.count(symbol) > 0;
    }

    int count() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return static_cast<int>(symbols_.size());
    }

    std::string get(int index) const {
        std::lock_guard<std::mutex> lock(mutex_);
        if (index < 0 || index >= static_cast<int>(symbols_.size()))
            return "";
        auto it = symbols_.begin();
        std::advance(it, index);
        return *it;
    }

    std::vector<std::string> all() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return std::vector<std::string>(symbols_.begin(), symbols_.end());
    }

private:
    mutable std::mutex mutex_;
    std::set<std::string> symbols_;
};

// ============================================================================
// Log message queue
// ============================================================================
class LogQueue {
public:
    void log(const std::string& msg) {
        messages_.push(msg);
    }

    std::optional<std::string> poll() {
        return messages_.try_pop();
    }

private:
    ThreadSafeQueue<std::string> messages_;
};

} // namespace cipher