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

#pragma once

#include <atomic>
#include <thread>

#include "common.h"
#include "socket_writer.h"

namespace screensharing {

// Streams the device's physical orientation to a socket, for the host to drive a 3D "device twin".
//
// Source is the rotation vector sensor (sensor fusion of accelerometer + gyroscope +
// magnetometer, falling back to the game rotation vector without the magnetometer), read through
// the NDK ASensor API, which needs no Context and therefore works in this shell-uid app_process.
//
// Wire format, little-endian, 24 bytes per packet:
//   float32 x, y, z, w   — the unit quaternion rotating the device frame into the world frame
//                          (Android's East-North-Up convention)
//   int64   timestamp_ns — the sensor event timestamp, CLOCK_BOOTTIME
class SensorStreamer {
public:
  explicit SensorStreamer(SocketWriter* writer);
  ~SensorStreamer();

  // Starts the streamer's thread.
  void Start();
  // Stops the streamer. Waits for the streamer's thread to terminate.
  void Stop();

private:
  void Run();

  SocketWriter* writer_;
  std::thread thread_;
  std::atomic_bool stopped_ { false };

  DISALLOW_COPY_AND_ASSIGN(SensorStreamer);
};

}  // namespace screensharing
