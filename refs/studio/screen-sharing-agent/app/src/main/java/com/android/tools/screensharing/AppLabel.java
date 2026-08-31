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
package com.android.tools.screensharing;

import android.content.pm.PackageManager;

/**
 * Prints the human-readable label of each package given as an argument, one per line — the name
 * the launcher shows, resolved from the APK's own resources, which nothing in the adb shell can
 * otherwise produce. Run standalone via app_process with the agent jar on the CLASSPATH:
 *
 *   CLASSPATH=/data/local/tmp/.studio/screen-sharing-agent.jar \
 *       app_process / com.android.tools.screensharing.AppLabel com.google.android.youtube
 *
 * A package that cannot be resolved echoes back unchanged, so the caller always gets a line.
 * The system context comes from ActivityThread via reflection, the same way scrcpy gets one in
 * a bare app_process.
 */
public final class AppLabel {
  private AppLabel() {}

  public static void main(String[] args) {
    try {
      android.os.Looper.prepareMainLooper();
    } catch (Throwable ignored) {
      // Already prepared, or not needed on this release.
    }
    PackageManager pm;
    try {
      Class<?> activityThread = Class.forName("android.app.ActivityThread");
      Object thread = activityThread.getMethod("systemMain").invoke(null);
      Object context = activityThread.getMethod("getSystemContext").invoke(thread);
      pm = (PackageManager) context.getClass().getMethod("getPackageManager").invoke(context);
    } catch (Throwable e) {
      for (String pkg : args) {
        System.out.println(pkg);
      }
      return;
    }
    for (String pkg : args) {
      String label;
      try {
        label = String.valueOf(pm.getApplicationInfo(pkg, 0).loadLabel(pm));
      } catch (Throwable e) {
        label = pkg;
      }
      System.out.println(label);
    }
  }
}
