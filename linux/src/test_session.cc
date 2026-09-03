#include "session/agent_session.h"
#include <iostream>
#include <string>
#include <thread>
#include <chrono>

int main(int argc, char** argv) {
    // Serial from the command line; without one, adb picks the only device.
    std::string serial = argc > 1 ? argv[1] : "";
    std::cout << "Testing AgentSession against "
              << (serial.empty() ? "the connected device" : serial) << "...\n";
    rplayhub::AgentSession session(serial);
    if (!session.start(1080, 2400)) {
        std::cerr << "Failed to start session\n";
        return 1;
    }

    std::cout << "Waiting for session to reach RUNNING...\n";
    for (int i = 0; i < 40; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        std::cout << "State: " << static_cast<int>(session.getState())
                  << " Msg: " << session.getStatusMessage() << "\n";
        if (session.getState() == rplayhub::SessionState::RUNNING) {
            std::cout << "Session is RUNNING!\n";
            break;
        }
        if (session.getState() == rplayhub::SessionState::FAILED) {
            std::cerr << "Session FAILED: " << session.getStatusMessage() << "\n";
            return 1;
        }
    }

    if (session.getState() != rplayhub::SessionState::RUNNING) {
        std::cerr << "Timed out waiting for session\n";
        return 1;
    }

    // Wait for frames
    std::cout << "Checking for decoded video frames...\n";
    for (int i = 0; i < 20; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        rplayhub::DecodedFrame frame;
        if (session.getDecoder().getLatestFrame(frame)) {
            std::cout << "Received decoded frame #" << frame.frameNumber
                      << " size=" << frame.width << "x" << frame.height
                      << " display=" << frame.displayWidth << "x" << frame.displayHeight
                      << " rot=" << frame.displayOrientation
                      << " rgba_bytes=" << frame.rgba.size() << "\n";
            break;
        }
    }

    // Test a key tap
    std::cout << "Sending BACK key tap...\n";
    session.sendKey(rplayhub::AndroidKey::BACK);

    std::this_thread::sleep_for(std::chrono::seconds(1));
    std::cout << "Stopping session...\n";
    session.stop();
    std::cout << "Test completed successfully!\n";
    return 0;
}
