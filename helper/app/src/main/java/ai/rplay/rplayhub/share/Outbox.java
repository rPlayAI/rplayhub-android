package ai.rplay.rplayhub.share;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;

/**
 * Where shared items are handed to the Mac.
 *
 * The app copies each shared item into its own external files directory —
 * {@code /sdcard/Android/data/ai.rplay.rplayhub.share/files/outbox/} — which needs no runtime
 * permission and which the Mac's shell agent can read (shell is in the ext_data_rw group). Each
 * share is one numbered batch directory; a {@code .ready} marker is written last, so the Mac only
 * ever pulls a batch once every file in it is complete.
 */
final class Outbox {
    private Outbox() {}

    /** Copy every URI into a fresh batch directory and mark it ready. Returns the batch name. */
    static String deliver(Context context, List<Uri> uris) throws IOException {
        File root = new File(context.getExternalFilesDir(null), "outbox");
        if (!root.exists() && !root.mkdirs()) {
            throw new IOException("cannot create " + root);
        }
        // A monotonic, sortable name: time plus this process's nanos, so two quick shares never
        // collide and the Mac can pull them oldest first.
        String batchName = System.currentTimeMillis() + "-" + (System.nanoTime() & 0xffffff);
        File batch = new File(root, batchName);
        if (!batch.mkdirs()) {
            throw new IOException("cannot create " + batch);
        }

        ContentResolver resolver = context.getContentResolver();
        int index = 0;
        for (Uri uri : uris) {
            String name = displayName(resolver, uri, index);
            File out = uniqueChild(batch, name);
            try (InputStream in = resolver.openInputStream(uri)) {
                if (in == null) {
                    throw new IOException("cannot open " + uri);
                }
                copy(in, out);
            }
            index++;
        }

        // The marker is the last thing written; the Mac watches for it, not for the files.
        File ready = new File(batch, ".ready");
        try (OutputStream os = new FileOutputStream(ready)) {
            os.write(Integer.toString(index).getBytes());
        }
        return batchName;
    }

    /** The name the source app gave the item, or a generated one when it gave none. */
    private static String displayName(ContentResolver resolver, Uri uri, int index) {
        String name = null;
        try (Cursor c = resolver.query(uri, new String[]{OpenableColumns.DISPLAY_NAME},
                                       null, null, null)) {
            if (c != null && c.moveToFirst() && !c.isNull(0)) {
                name = c.getString(0);
            }
        } catch (Exception ignored) {
            // Some providers reject the query; fall through to the generated name.
        }
        if (name == null || name.trim().isEmpty()) {
            String ext = extensionFor(resolver.getType(uri));
            name = "shared-" + (index + 1) + ext;
        }
        return sanitize(name);
    }

    /** Strip path separators so a provider's name can never escape the batch directory. */
    private static String sanitize(String name) {
        String cleaned = name.replace('/', '_').replace('\\', '_').trim();
        return cleaned.isEmpty() ? "shared" : cleaned;
    }

    /** Avoid overwriting when a share carries two items of the same name. */
    private static File uniqueChild(File dir, String name) {
        File file = new File(dir, name);
        if (!file.exists()) {
            return file;
        }
        int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        String ext = dot > 0 ? name.substring(dot) : "";
        for (int n = 2; ; n++) {
            File candidate = new File(dir, base + "-" + n + ext);
            if (!candidate.exists()) {
                return candidate;
            }
        }
    }

    private static String extensionFor(String mime) {
        if (mime == null) {
            return "";
        }
        switch (mime) {
            case "image/jpeg": return ".jpg";
            case "image/png": return ".png";
            case "image/gif": return ".gif";
            case "image/webp": return ".webp";
            case "video/mp4": return ".mp4";
            case "text/plain": return ".txt";
            case "application/pdf": return ".pdf";
            default:
                int slash = mime.indexOf('/');
                return slash >= 0 && slash < mime.length() - 1 ? "." + mime.substring(slash + 1) : "";
        }
    }

    private static void copy(InputStream in, File out) throws IOException {
        try (OutputStream os = new FileOutputStream(out)) {
            byte[] buffer = new byte[64 * 1024];
            int read;
            while ((read = in.read(buffer)) != -1) {
                os.write(buffer, 0, read);
            }
        }
    }
}
