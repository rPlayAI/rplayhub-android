package com.rplay.rplayhub.helper;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

import android.app.Activity;

/**
 * The Share-sheet entry. It takes the shared items, copies them to the outbox, tells the user,
 * and finishes — it has no UI of its own (a translucent, no-history activity).
 */
public final class ShareActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        List<Uri> uris = collectUris(getIntent());
        if (uris.isEmpty()) {
            toast("Nothing to send");
            finish();
            return;
        }
        try {
            Outbox.deliver(this, uris);
            int n = uris.size();
            toast(n == 1 ? "Sent to your Mac" : "Sent " + n + " items to your Mac");
        } catch (Exception e) {
            toast("Couldn't send: " + e.getMessage());
        }
        finish();
    }

    private List<Uri> collectUris(Intent intent) {
        List<Uri> uris = new ArrayList<>();
        if (intent == null || intent.getAction() == null) {
            return uris;
        }
        switch (intent.getAction()) {
            case Intent.ACTION_SEND: {
                Uri uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
                if (uri != null) {
                    uris.add(uri);
                } else {
                    // A text-only share (no stream): keep the text as a .txt so it still lands.
                    CharSequence text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT);
                    if (text != null) {
                        // Handled by writing a temp file would need FileProvider; instead reuse
                        // the stream path only. Plain text with no stream is dropped for now.
                    }
                }
                break;
            }
            case Intent.ACTION_SEND_MULTIPLE: {
                ArrayList<Uri> list = intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM);
                if (list != null) {
                    for (Uri uri : list) {
                        if (uri != null) {
                            uris.add(uri);
                        }
                    }
                }
                break;
            }
            default:
                break;
        }
        return uris;
    }

    private void toast(String message) {
        Toast.makeText(getApplicationContext(), message, Toast.LENGTH_SHORT).show();
    }
}
