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

#include <cstring>

#include "agent.h"
#include "log.h"

namespace screensharing {

namespace {

constexpr int32_t SAMPLING_PERIOD_US = 10000;  // 100 Hz for the rotation vector — lower latency for the twin.
constexpr int POLL_TIMEOUT_MILLIS = 250;  // How often the loop notices it was asked to stop.

// One queue per sensor, told apart by the looper ident, so no sensor handle API is needed
// (ASensor_getHandle only exists from API 29).
enum Tag : uint32_t {
  TAG_ROTATION = 1,   // rotation vector quaternion x, y, z, w
  TAG_HINGE = 2,      // hinge angle, degrees, in v[0]
  TAG_GYRO_A = 3,     // gyroscope of the first IMU, rad/s x, y, z
  TAG_GYRO_B = 4,     // gyroscope of the second IMU (a foldable's other half), rad/s x, y, z
};
constexpr int NUM_TAGS = 5;

// Wire format, 28 bytes, little-endian: the sensor timestamp (boot ns), four floats, the tag.
// Assembled by hand: a struct of these would pad to 32 bytes.
constexpr size_t PACKET_SIZE = 28;
void PackSensorPacket(uint8_t* out, int64_t timestamp_ns, const float v[4], uint32_t tag) {
  memcpy(out, &timestamp_ns, 8);
  memcpy(out + 8, v, 16);
  memcpy(out + 24, &tag, 4);
}

const char* ReportingModeName(int mode) {
  switch (mode) {
    case AREPORTING_MODE_CONTINUOUS: return "continuous";
    case AREPORTING_MODE_ON_CHANGE: return "on-change";
    case AREPORTING_MODE_ONE_SHOT: return "one-shot";
    case AREPORTING_MODE_SPECIAL_TRIGGER: return "special";
    default: return "?";
  }
}

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

  // The inventory, once: what a foldable offers (hinge angle, a second IMU) is decided here.
  ASensorList list = nullptr;
  int count = ASensorManager_getSensorList(manager, &list);
  const ASensor* gyros[2] = { nullptr, nullptr };
  int num_gyros = 0;
  for (int i = 0; i < count; ++i) {
    const ASensor* s = list[i];
    Log::I("SensorStreamer: sensor type %d \"%s\" by %s, min delay %d us, %s",
           ASensor_getType(s), ASensor_getName(s), ASensor_getVendor(s), ASensor_getMinDelay(s),
           ReportingModeName(ASensor_getReportingMode(s)));
    // Hardware gyroscopes only: the AOSP "Corrected Gyroscope" is a software copy of one of them.
    if (ASensor_getType(s) == ASENSOR_TYPE_GYROSCOPE && strcmp(ASensor_getVendor(s), "AOSP") != 0 && num_gyros < 2) {
      gyros[num_gyros++] = s;
    }
  }

  // The rotation vector fuses in the magnetometer; without one the game rotation vector still
  // gives a stable gravity-referenced attitude, with yaw relative to startup instead of north —
  // which a device twin does not care about.
  const ASensor* sensors[NUM_TAGS] = { nullptr, nullptr, nullptr, nullptr, nullptr };
  sensors[TAG_ROTATION] = ASensorManager_getDefaultSensor(manager, ASENSOR_TYPE_ROTATION_VECTOR);
  if (sensors[TAG_ROTATION] == nullptr) {
    sensors[TAG_ROTATION] = ASensorManager_getDefaultSensor(manager, ASENSOR_TYPE_GAME_ROTATION_VECTOR);
  }
  if (sensors[TAG_ROTATION] == nullptr) {
    Log::W("SensorStreamer: no rotation vector sensor; not streaming orientation");
    return;
  }
  sensors[TAG_HINGE] = ASensorManager_getDefaultSensor(manager, ASENSOR_TYPE_HINGE_ANGLE);
  if (num_gyros >= 2) {
    sensors[TAG_GYRO_A] = gyros[0];
    sensors[TAG_GYRO_B] = gyros[1];
  }
  Log::I("SensorStreamer: foldable sensors: hinge %s, second gyroscope %s",
         sensors[TAG_HINGE] ? "yes" : "no", sensors[TAG_GYRO_B] ? "yes" : "no");

  ALooper* looper = ALooper_prepare(ALOOPER_PREPARE_ALLOW_NON_CALLBACKS);
  ASensorEventQueue* queues[NUM_TAGS] = { nullptr, nullptr, nullptr, nullptr, nullptr };
  for (int tag = 1; tag < NUM_TAGS; ++tag) {
    if (sensors[tag] == nullptr) continue;
    queues[tag] = ASensorManager_createEventQueue(manager, looper, tag, nullptr, nullptr);
    if (queues[tag] == nullptr) {
      Log::W("SensorStreamer: could not create an event queue for tag %d", tag);
      continue;
    }
    ASensorEventQueue_enableSensor(queues[tag], sensors[tag]);
    // The rotation vector at 100 Hz, the gyroscopes as fast as they go, the hinge as it changes.
    int32_t period = tag == TAG_ROTATION ? SAMPLING_PERIOD_US : ASensor_getMinDelay(sensors[tag]);
    if (period > 0) ASensorEventQueue_setEventRate(queues[tag], sensors[tag], period);
    Log::I("SensorStreamer: streaming tag %d from \"%s\"", tag, ASensor_getName(sensors[tag]));
  }

  while (!stopped_ && !Agent::IsShuttingDown()) {
    int ident = ALooper_pollOnce(POLL_TIMEOUT_MILLIS, nullptr, nullptr, nullptr);
    if (ident <= 0 || ident >= NUM_TAGS || queues[ident] == nullptr) {
      continue;
    }
    // Drain the queue and send only the newest event of this sensor — each is a "current
    // value", and a slow reader should get fresher data, not a growing backlog.
    ASensorEvent event;
    bool have_event = false;
    ASensorEvent latest;
    while (ASensorEventQueue_getEvents(queues[ident], &event, 1) > 0) {
      latest = event;
      have_event = true;
    }
    if (!have_event) {
      continue;
    }
    uint8_t packet[PACKET_SIZE];
    const float v[4] = { latest.data[0], latest.data[1], latest.data[2], latest.data[3] };
    PackSensorPacket(packet, latest.timestamp, v, static_cast<uint32_t>(ident));
    auto res = writer_->Write(packet, sizeof(packet));
    if (res == SocketWriter::Result::DISCONNECTED || res == SocketWriter::Result::TIMEOUT) {
      // Only a dead or wedged connection gets here. The sensors are an optional garnish on the
      // session, so stop quietly rather than shutting the agent down.
      Log::I("SensorStreamer: sensor channel closed; stopping");
      break;
    }
  }

  for (int tag = 1; tag < NUM_TAGS; ++tag) {
    if (queues[tag] == nullptr) continue;
    ASensorEventQueue_disableSensor(queues[tag], sensors[tag]);
    ASensorManager_destroyEventQueue(manager, queues[tag]);
  }
}

}  // namespace screensharing
