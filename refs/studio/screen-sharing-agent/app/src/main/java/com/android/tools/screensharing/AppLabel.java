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
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.util.Base64;
import java.io.ByteArrayOutputStream;

/**
 * Prints, for each package given as an argument, one line: the human-readable label the launcher
 * shows, a TAB, and the launcher icon as a base64 PNG (empty when there is none) — both resolved
 * from the APK's own resources via PackageManager, which nothing in the adb shell can otherwise
 * produce, and which (unlike unzipping ic_launcher) handles obfuscated and adaptive icons. Run
 * standalone via app_process with the agent jar on the CLASSPATH:
 *
 *   CLASSPATH=/data/local/tmp/.studio/screen-sharing-agent.jar \
 *       app_process / com.android.tools.screensharing.AppLabel com.google.android.youtube
 *
 * A package that cannot be resolved echoes its name back with an empty icon, so the caller always
 * gets a line. The system context comes from ActivityThread via reflection, the same way scrcpy
 * gets one in a bare app_process.
 */
public final class AppLabel {
  private AppLabel() {}

  // The list row is small; a 96px icon is crisp on retina without bloating the piped output.
  private static final int ICON_PX = 96;

  private static String iconPng(PackageManager pm, String pkg) {
    try {
      Drawable d = pm.getApplicationIcon(pkg);
      int w = ICON_PX, h = ICON_PX;
      Bitmap bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888);
      Canvas canvas = new Canvas(bmp);
      d.setBounds(0, 0, w, h);
      d.draw(canvas);   // composites an adaptive icon's layers, unlike a raw resource unzip
      ByteArrayOutputStream out = new ByteArrayOutputStream();
      bmp.compress(Bitmap.CompressFormat.PNG, 100, out);
      bmp.recycle();
      return Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP);
    } catch (Throwable e) {
      return "";
    }
  }

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
        System.out.println(pkg + "\t");
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
      // label <TAB> base64-png; a newline never appears in either field.
      System.out.println(label + "\t" + iconPng(pm, pkg));
    }
  }
}
