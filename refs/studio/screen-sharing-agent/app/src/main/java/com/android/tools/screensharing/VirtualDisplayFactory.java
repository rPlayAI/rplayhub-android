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

import android.app.ActivityOptions;
import android.content.Context;
import android.content.Intent;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.hardware.display.VirtualDisplayConfig;
import android.util.Log;
import java.lang.reflect.Method;

/**
 * Creates standalone virtual displays — a display of its own, not a mirror of one, the way
 * scrcpy's --new-display works. Apps launched onto it ({@code am start --display N}) run there
 * invisibly to the physical screen while the host mirrors it.
 *
 * AgentContext wraps the real system context, so the public DisplayManager API is available;
 * only some of the flag values are hidden. Running as shell grants ADD_TRUSTED_DISPLAY.
 */
public final class VirtualDisplayFactory {
  private static final String TAG = "studio.screen.sharing";

  // VIRTUAL_DISPLAY_FLAG_* values; the interesting ones are @hide, stable by value.
  private static final int FLAG_PUBLIC = 1;
  private static final int FLAG_OWN_CONTENT_ONLY = 1 << 3;
  private static final int FLAG_SUPPORTS_TOUCH = 1 << 6;
  private static final int FLAG_ROTATES_WITH_CONTENT = 1 << 7;
  private static final int FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS = 1 << 9;
  private static final int FLAG_TRUSTED = 1 << 10;
  // Its own power/lock world: without OWN_DISPLAY_GROUP the display joins the DEFAULT group and
  // sleeps when the phone does — every activity on it gets paused the moment the phone's screen
  // turns off. ALWAYS_UNLOCKED keeps the keyguard off it too.
  private static final int FLAG_OWN_DISPLAY_GROUP = 1 << 11;
  private static final int FLAG_ALWAYS_UNLOCKED = 1 << 12;
  private static final int FLAG_OWN_FOCUS = 1 << 14;

  private VirtualDisplayFactory() {}

  /** Keeps the newest standalone display's device powered; see createNewDisplay. */
  private static android.media.ImageReader keepAlive;

  /** Called from native code. Returns null on failure. */
  public static VirtualDisplay createNewDisplay(String name, int width, int height, int dpi) {
    int fullFlags = FLAG_PUBLIC | FLAG_OWN_CONTENT_ONLY | FLAG_SUPPORTS_TOUCH
        | FLAG_ROTATES_WITH_CONTENT | FLAG_SHOULD_SHOW_SYSTEM_DECORATIONS | FLAG_TRUSTED
        | FLAG_OWN_FOCUS;
    // OWN_DISPLAY_GROUP and ALWAYS_UNLOCKED are deliberately NOT requested: with either, the
    // mirror capture of the display comes back solid black (a DisplayManager mirror lives in the
    // default group and cross-group content is withheld), and the SurfaceControl alternative
    // aborts on API 34+. So the display shares the phone's power group, and the agent keeps the
    // phone awake while the display exists instead.
    VirtualDisplay display = create(name, width, height, dpi, fullFlags);
    if (display == null) {
      // Privileged flags vary by release; retry with the tamest still-usable set.
      display = create(name, width, height, dpi,
          FLAG_PUBLIC | FLAG_OWN_CONTENT_ONLY | FLAG_SUPPORTS_TOUCH | FLAG_TRUSTED);
    }
    if (display != null) {
      // A surfaceless virtual display's device stays OFF, DisplayPowerController holds a sleep
      // token for it, and every activity launched onto it is immediately PAUSED — it renders
      // nothing. Nothing else wakes it (not content, not input, not requestDisplayPower), but
      // attaching a surface does. Give it a consumed ImageReader as a keep-alive surface; the
      // streamer captures the layerstack through its own mirror display, unaffected.
      try {
        // Quarter resolution: the surface exists only to keep the display device powered, so
        // there is no reason to have SurfaceFlinger compose a full-size frame nobody reads.
        keepAlive = android.media.ImageReader.newInstance(
            Math.max(width / 4, 1), Math.max(height / 4, 1),
            android.graphics.PixelFormat.RGBA_8888, 2);
        keepAlive.setOnImageAvailableListener(reader -> {
          android.media.Image image = reader.acquireLatestImage();
          if (image != null) {
            image.close();
          }
        }, new android.os.Handler(android.os.Looper.getMainLooper()));
        display.setSurface(keepAlive.getSurface());
        Log.i(TAG, "keep-alive surface attached; the display can power on");
      } catch (Throwable e) {
        Log.w(TAG, "keep-alive surface failed: " + e);
      }
    }
    return display;
  }

  private static VirtualDisplay create(String name, int width, int height, int dpi, int flags) {
    // The owner-uid check compares the calling uid to the package baked into the config. Going
    // through DisplayManagerGlobal with a config we build ourselves — the way scrcpy does — is
    // what makes it use AgentContext's package (com.android.shell, which shell owns) rather than
    // the system context DisplayManager.getSystemService() would capture.
    try {
      VirtualDisplayConfig config = new VirtualDisplayConfig.Builder(name, width, height, dpi)
          .setFlags(flags)
          .build();

      Class<?> globalClass = Class.forName("android.hardware.display.DisplayManagerGlobal");
      Object global = globalClass.getMethod("getInstance").invoke(null);

      Class<?> callbackClass =
          Class.forName("android.hardware.display.VirtualDisplay$Callback");
      // context, projection, config, callback, executor/handler — the signature drifts across
      // releases, so match on name and argument shape rather than a fixed prototype.
      for (Method m : globalClass.getMethods()) {
        if (!m.getName().equals("createVirtualDisplay")) {
          continue;
        }
        Class<?>[] p = m.getParameterTypes();
        if (p.length == 5 && p[2] == VirtualDisplayConfig.class) {
          Object executor = null;   // a handler/executor slot takes null fine
          if (p[4] == java.util.concurrent.Executor.class) {
            executor = (java.util.concurrent.Executor) Runnable::run;
          }
          return (VirtualDisplay) m.invoke(global, AgentContext.INSTANCE, null, config,
                                           /* callback */ null, executor);
        }
      }
      Log.w(TAG, "VirtualDisplayFactory: no matching DisplayManagerGlobal.createVirtualDisplay");
      return null;
    } catch (java.lang.reflect.InvocationTargetException e) {
      Log.w(TAG, "VirtualDisplayFactory: createVirtualDisplay(flags=" + flags + ") rejected: "
          + e.getCause());
      return null;
    } catch (Throwable e) {
      Log.w(TAG, "VirtualDisplayFactory: createVirtualDisplay(flags=" + flags + ") failed: " + e);
      return null;
    }
  }

  /** Called from native code. */
  public static int displayId(VirtualDisplay display) {
    return display.getDisplay().getDisplayId();
  }

  /**
   * Called from native code. Launches a package's main activity onto the given display, so a
   * freshly-created virtual display has something to render — an empty display produces no frames.
   * Running as shell with a trusted display, {@code setLaunchDisplayId} is permitted. Returns 1
   * if the activity was started, 0 otherwise (int, not boolean — the native caller has no boolean
   * helper).
   */
  public static int launchApp(String packageName, int displayId) {
    try {
      Context context = AgentContext.INSTANCE;
      Intent intent = context.getPackageManager().getLaunchIntentForPackage(packageName);
      if (intent == null) {
        Log.w(TAG, "launchApp: no launcher activity for " + packageName);
        return 0;
      }
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
      ActivityOptions options = ActivityOptions.makeBasic();
      options.setLaunchDisplayId(displayId);
      context.startActivity(intent, options.toBundle());
      Log.i(TAG, "launchApp: launched " + packageName + " on display " + displayId);
      return 1;
    } catch (Throwable e) {
      Log.w(TAG, "launchApp: failed to launch " + packageName + " on display " + displayId + ": " + e);
      return 0;
    }
  }
}
