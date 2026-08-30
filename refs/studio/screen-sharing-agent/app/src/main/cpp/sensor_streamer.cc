/*
 * rPlayHub addition, not part of the upstream Android Studio agent (see refs/studio/PROVENANCE.md).
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "sensor_streamer.h"

#include <android/looper.h>
#include <android/sensor.h>

#include "agent.h"
#include "log.h"

namespace screensharing {

namespace {

constexpr int32_t SAMPLING_PERIOD_US = 20000;  // 50 Hz — plenty for a display twin, light on the wire.
constexpr int LOOPER_IDENT = 1;
constexpr int POLL_TIMEOUT_MILLIS = 250;  // How often the loop notices it was asked to stop.

// One packet on the wire. Naturally packed: four 4-byte floats then an 8-aligned int64.
struct SensorPacket {
  float x;
  float y;
  float z;
  float w;
  int64_t timestamp_ns;
};
static_assert(sizeof(SensorPacket) == 24);

}  // namespace

SensorStreamer::SensorStreamer(SocketWriter* writer)
    : writer_(writer) {
}

SensorStreamer::~SensorStreamer() {
  Stop();
}

void SensorStreamer::Start() {
  // The thread stays detached from the JVM: everything here is NDK, no JNI.
  thread_ = std::thread([this]() { Run(); });
}

void SensorStreamer::Stop() {
  stopped_ = true;
  if (thread_.joinable()) {
    thread_.join();
  }
}

void SensorStreamer::Run() {
  ASensorManager* manager = ASensorManager_getInstanceForPackage(ATTRIBUTION_TAG);
  if (manager == nullptr) {
    Log::W("SensorStreamer: no sensor manager; not streaming orientation");
    return;
  }
  // The rotation vector fuses in the magnetometer; without one the game rotation vector still
  // gives a stable gravity-referenced attitude, with yaw relative to startup instead of north —
  // which a device twin does not care about.
  const ASensor* sensor = ASensorManager_getDefaultSensor(manager, ASENSOR_TYPE_ROTATION_VECTOR);
  if (sensor == nullptr) {
    sensor = ASensorManager_getDefaultSensor(manager, ASENSOR_TYPE_GAME_ROTATION_VECTOR);
  }
  if (sensor == nullptr) {
    Log::W("SensorStreamer: no rotation vector sensor; not streaming orientation");
    return;
  }

  ALooper* looper = ALooper_prepare(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS);
  ASensorEventQueue* queue = ASensorManager_createEventQueue(manager, looper, LOOPER_IDENT, nullptr, nullptr);
  if (queue == nullptr) {
    Log::W("SensorStreamer: could not create a sensor event queue");
    return;
  }
  ASensorEventQueue_enableSensor(queue, sensor);
  ASensorEventQueue_setEventRate(queue, sensor, SAMPLING_PERIOD_US);
  Log::I("SensorStreamer: streaming orientation from \"%s\"", ASensor_getName(sensor));

  while (!stopped_ && !Agent::IsShuttingDown()) {
    int ident = ALooper_pollOnce(POLL_TIMEOUT_MILLIS, nullptr, nullptr, nullptr);
    if (ident != LOOPER_IDENT) {
      continue;
    }
    // Drain the queue and send only the newest event — orientation is a "current value", and a
    // slow reader should get fresher data, not a growing backlog.
    ASensorEvent event;
    bool have_event = false;
    ASensorEvent latest;
    while (ASensorEventQueue_getEvents(queue, &event, 1) > 0) {
      latest = event;
      have_event = true;
    }
    if (!have_event) {
      continue;
    }
    SensorPacket packet = {
        .x = latest.data[0],
        .y = latest.data[1],
        .z = latest.data[2],
        .w = latest.data[3],
        .timestamp_ns = latest.timestamp,
    };
    auto res = writer_->Write(&packet, sizeof(packet));
    if (res == SocketWriter::Result::DISCONNECTED || res == SocketWriter::Result::TIMEOUT) {
      // At 1.2 KB/s only a dead or wedged connection gets here. Orientation is an optional
      // garnish on the session, so stop quietly rather than shutting the agent down.
      Log::I("SensorStreamer: orientation channel closed; stopping");
      break;
    }
  }

  ASensorEventQueue_disableSensor(queue, sensor);
  ASensorManager_destroyEventQueue(manager, queue);
}

}  // namespace screensharing
