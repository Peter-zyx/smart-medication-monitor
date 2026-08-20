#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include "../../firmware/esp32/MedBox_LiveTrain_AI/weight_inference.h"

namespace {

struct EventRow {
    int eventId;
    double beforeG;
    double afterG;
};

std::vector<std::string> splitCsv(const std::string& line) {
    std::vector<std::string> fields;
    std::stringstream stream(line);
    std::string field;
    while (std::getline(stream, field, ',')) {
        fields.push_back(field);
    }
    return fields;
}

std::vector<EventRow> readEvents(const char* path) {
    std::ifstream file(path);
    if (!file) {
        throw std::runtime_error(std::string("Could not open events CSV: ") + path);
    }
    std::vector<EventRow> rows;
    std::string line;
    std::getline(file, line);
    while (std::getline(file, line)) {
        const auto fields = splitCsv(line);
        if (fields.size() < 3) {
            continue;
        }
        rows.push_back({std::stoi(fields[0]), std::stod(fields[1]), std::stod(fields[2])});
    }
    return rows;
}

std::map<int, std::vector<medbox_weight_inference::WeightSample>> readSamples(const char* path) {
    std::ifstream file(path);
    if (!file) {
        throw std::runtime_error(std::string("Could not open samples CSV: ") + path);
    }
    std::map<int, std::vector<medbox_weight_inference::WeightSample>> rows;
    std::string line;
    std::getline(file, line);
    while (std::getline(file, line)) {
        const auto fields = splitCsv(line);
        if (fields.size() < 3) {
            continue;
        }
        rows[std::stoi(fields[0])].push_back({
            static_cast<uint32_t>(std::stoul(fields[1])),
            std::stod(fields[2]),
        });
    }
    for (auto& entry : rows) {
        std::sort(entry.second.begin(), entry.second.end(), [](const auto& lhs, const auto& rhs) {
            return lhs.timeMs < rhs.timeMs;
        });
    }
    return rows;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "usage: verify_esp32_weight_runtime events.csv samples.csv\n";
        return 2;
    }

    try {
        const auto events = readEvents(argv[1]);
        const auto samples = readSamples(argv[2]);
        std::cout << std::setprecision(12);
        for (const auto& event : events) {
            const auto found = samples.find(event.eventId);
            if (found == samples.end()) {
                throw std::runtime_error("Missing samples for event " + std::to_string(event.eventId));
            }
            const auto prediction = medbox_weight_inference::classify(
                event.beforeG,
                event.afterG,
                found->second.data(),
                found->second.size(),
                0.848
            );
            std::cout << event.eventId << ',' << prediction.label << ',';
            if (prediction.hasConfidence) {
                std::cout << prediction.confidence;
            } else {
                std::cout << "NA";
            }
            std::cout << ',' << prediction.finalDeltaG << '\n';
        }
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
    return 0;
}
