#pragma once
#include "json.hpp"
#include <atomic>
#include <iostream>
#include <mutex>
#include <thread>

// One inference at a time; the input thread remains available for cancellation.
// Request IDs prevent an old cancellation from interrupting a newer dictation.
template<class Operation> void serve_worker(Operation operation) {
    using json = nlohmann::json;
    std::atomic<bool> cancelled{false};
    std::mutex output;
    std::thread task;
    std::string current, line;
    auto send = [&](const json &reply) {
        std::lock_guard<std::mutex> lock(output);
        std::cout << reply.dump() << std::endl;
    };
    send({{"ready", true}});
    while (std::getline(std::cin, line)) {
        try {
            auto request = json::parse(line);
            if (request.contains("cancel")) {
                if (request.at("cancel").get<std::string>() == current) cancelled.store(true);
                continue;
            }
            if (task.joinable()) task.join();
            current = request.at("id").get<std::string>();
            cancelled.store(false);
            task = std::thread([&, request, id = current] {
                try {
                    auto reply = operation(request, cancelled);
                    if (cancelled.load()) reply = {{"error", "Dictation cancelled."}};
                    reply["id"] = id;
                    send(reply);
                } catch (const std::exception &error) {
                    send({{"id", id}, {"error", cancelled.load() ? "Dictation cancelled." : error.what()}});
                }
            });
        } catch (const std::exception &error) { send({{"error", error.what()}}); }
    }
    cancelled.store(true);
    if (task.joinable()) task.join();
}
