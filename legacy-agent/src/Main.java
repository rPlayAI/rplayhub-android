package ai.rplay.legacy;

import android.graphics.Rect;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.IBinder;
import android.os.SystemClock;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;

import java.io.BufferedReader;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;

/**
 * rPlayHub's legacy agent — mirroring and control for Android 5.0 to 7.1 (API 21-25).
 *
 * Android Studio's screen-sharing agent, which rPlayHub uses everywhere else, is built minSdk 26
 * and cannot go lower: its capture path needs AMediaCodec_createInputSurface, and the NDK does not
 * expose that before Oreo. Java has had MediaCodec.createInputSurface() since long before, which
 * is exactly why scrcpy supports API 21+, so the old devices get a small Java agent instead. Many
 * embedded boards — car boxes, dashcams, signage — are still on Android 5, and they are precisely
 * what people reach for scrcpy to drive.
 *
 * It runs through app_process as the shell user, which is what grants INJECT_EVENTS and access to
 * the hidden SurfaceControl API. API 22 predates the hidden-API restrictions, so plain reflection
 * is enough.
 *
 * Transport is the adb exec stream and nothing else — no reverse tunnel, no second socket:
 *   stdout  raw Annex-B H.264, exactly what the host's existing decoder already parses.
 *   stdin   one command per line:
 *             t &lt;x&gt; &lt;y&gt; &lt;0|1|2&gt;   touch: 0 up, 1 down, 2 move
 *             k &lt;keycode&gt;          key down then up
 *             q                    quit
 */
public final class Main {

    /** Set once the encoder has produced anything; ends the first-frame kick below. */

    private static volatile boolean gotOutput = false;

    private static final String MIME = "video/avc";

    private static Method injectInputEvent;
    private static Object inputManager;

    public static void main(String[] args) {
        try {
            int width = 720, height = 1280, bitRate = 4_000_000;
            if (args.length >= 2) {
                width = even(Integer.parseInt(args[0]));
                height = even(Integer.parseInt(args[1]));
            }
            if (args.length >= 3) bitRate = Integer.parseInt(args[2]);

            prepareInput();
            // An anonymous Runnable, not a method reference: compiling against an old
            // bootclasspath has no LambdaMetafactory to desugar one against.
            new Thread(new Runnable() {
                @Override public void run() { readCommands(); }
            }, "rplayhub-input").start();
            stream(width, height, bitRate);
        } catch (Throwable t) {
            System.err.println("legacy-agent: " + t);
            t.printStackTrace();
            System.exit(1);
        }
        // MediaCodec keeps non-daemon threads alive; leaving main() is not enough to exit.
        System.exit(0);
    }

    private static int even(int v) { return v & ~1; }   // encoders reject odd dimensions

    // ---------------------------------------------------------------- video

    private static void stream(int width, int height, int bitRate) throws Exception {
        MediaFormat format = MediaFormat.createVideoFormat(MIME, width, height);
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, 30);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2);
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);

        MediaCodec codec = MediaCodec.createEncoderByType(MIME);
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
        Surface surface = codec.createInputSurface();

        Class<?> sc = Class.forName("android.view.SurfaceControl");
        Method createDisplay = sc.getMethod("createDisplay", String.class, boolean.class);
        IBinder display = (IBinder) createDisplay.invoke(null, "rplayhub-legacy", false);
        if (display == null) throw new IllegalStateException("SurfaceControl.createDisplay returned null");

        Method open = sc.getMethod("openTransaction");
        Method close = sc.getMethod("closeTransaction");
        Method setSurface = sc.getMethod("setDisplaySurface", IBinder.class, Surface.class);
        Method setProjection = sc.getMethod("setDisplayProjection", IBinder.class,
                int.class, Rect.class, Rect.class);
        Method setLayerStack = sc.getMethod("setDisplayLayerStack", IBinder.class, int.class);

        open.invoke(null);
        try {
            setSurface.invoke(null, display, surface);
            // Mirror layer stack 0 (the real screen) into our encoder surface, scaled to fit.
            setProjection.invoke(null, display, 0,
                    new Rect(0, 0, width, height), new Rect(0, 0, width, height));
            setLayerStack.invoke(null, display, 0);
        } finally {
            close.invoke(null);
        }

        codec.start();
        System.err.println("legacy-agent: streaming " + width + "x" + height + " @ " + bitRate);

        // Some boards never compose a still screen into a NEW mirror display: nothing changes
        // on screen, so nothing is drawn into the encoder's surface, the encoder has nothing to
        // encode, and the host waits on nothing until something on the device happens to move
        // (tens of seconds on a car unit showing a pairing page). A display transaction that
        // actually changes state makes SurfaceFlinger compose that display, so until the first
        // buffer is out, re-apply the projection with the destination two pixels shorter and
        // then true again — each one a real change, the last one always the real geometry.
        final Rect source = new Rect(0, 0, width, height);
        Thread kick = new Thread(new Runnable() {
            @Override public void run() {
                try {
                    int n = 0;
                    while (!gotOutput && n < 40) {
                        Thread.sleep(300);
                        Rect dest = new Rect(0, 0, width, (n++ % 2 == 0) ? height - 2 : height);
                        open.invoke(null);
                        try { setProjection.invoke(null, display, 0, source, dest); }
                        finally { close.invoke(null); }
                    }
                    open.invoke(null);
                    try { setProjection.invoke(null, display, 0, source, new Rect(0, 0, width, height)); }
                    finally { close.invoke(null); }
                } catch (Throwable ignored) { }
            }
        }, "kick");
        kick.setDaemon(true);
        kick.start();

        OutputStream out = new FileOutputStream(FileDescriptor.out);
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        try {
            while (!Thread.currentThread().isInterrupted()) {
                int index = codec.dequeueOutputBuffer(info, 500_000);
                if (index >= 0) {
                    if (info.size > 0) {
                        gotOutput = true;
                        ByteBuffer buffer = codec.getOutputBuffer(index);
                        buffer.position(info.offset);
                        byte[] chunk = new byte[info.size];
                        buffer.get(chunk, 0, info.size);
                        out.write(chunk);
                        out.flush();          // the host wants frames now, not when a buffer fills
                    }
                    codec.releaseOutputBuffer(index, false);
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break;
                }
            }
        } finally {
            try { codec.stop(); codec.release(); } catch (Throwable ignored) { }
            try { sc.getMethod("destroyDisplay", IBinder.class).invoke(null, display); }
            catch (Throwable ignored) { }
        }
    }

    // ---------------------------------------------------------------- input

    /** InputManager.getInstance().injectInputEvent(event, WAIT_FOR_RESULT=0). Shell holds INJECT_EVENTS. */
    private static void prepareInput() {
        try {
            Class<?> im = Class.forName("android.hardware.input.InputManager");
            inputManager = im.getMethod("getInstance").invoke(null);
            injectInputEvent = im.getMethod("injectInputEvent", InputEvent.class, int.class);
        } catch (Throwable t) {
            System.err.println("legacy-agent: input injection unavailable: " + t);
        }
    }

    private static void inject(InputEvent event) {
        if (injectInputEvent == null || inputManager == null) return;
        try {
            injectInputEvent.invoke(inputManager, event, 0);
        } catch (Throwable t) {
            System.err.println("legacy-agent: inject failed: " + t);
        }
    }

    private static long touchDownAt = 0;

    private static void touch(int x, int y, int phase) {
        int action;
        long now = SystemClock.uptimeMillis();
        switch (phase) {
            case 1:  action = MotionEvent.ACTION_DOWN; touchDownAt = now; break;
            case 2:  action = MotionEvent.ACTION_MOVE; break;
            default: action = MotionEvent.ACTION_UP;   break;
        }
        if (touchDownAt == 0) touchDownAt = now;
        MotionEvent event = MotionEvent.obtain(touchDownAt, now, action, x, y, 0);
        // Without this the event is dropped: injected events must name a source.
        event.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);
        inject(event);
        event.recycle();
        if (action == MotionEvent.ACTION_UP) touchDownAt = 0;
    }

    private static void key(int keycode) {
        long now = SystemClock.uptimeMillis();
        KeyEvent down = new KeyEvent(now, now, KeyEvent.ACTION_DOWN, keycode, 0);
        down.setSource(android.view.InputDevice.SOURCE_KEYBOARD);
        inject(down);
        KeyEvent up = new KeyEvent(now, SystemClock.uptimeMillis(), KeyEvent.ACTION_UP, keycode, 0);
        up.setSource(android.view.InputDevice.SOURCE_KEYBOARD);
        inject(up);
    }

    private static void readCommands() {
        try {
            BufferedReader in = new BufferedReader(new InputStreamReader(System.in));
            String line;
            while ((line = in.readLine()) != null) {
                String[] parts = line.trim().split("\\s+");
                if (parts.length == 0 || parts[0].isEmpty()) continue;
                switch (parts[0]) {
                    case "t":
                        if (parts.length >= 4) {
                            touch(Integer.parseInt(parts[1]), Integer.parseInt(parts[2]),
                                  Integer.parseInt(parts[3]));
                        }
                        break;
                    case "k":
                        if (parts.length >= 2) key(Integer.parseInt(parts[1]));
                        break;
                    case "q":
                        System.exit(0);
                        break;
                    default:
                        break;
                }
            }
        } catch (Throwable t) {
            System.err.println("legacy-agent: input loop ended: " + t);
        }
        // stdin closed: the host is gone.
        System.exit(0);
    }
}
