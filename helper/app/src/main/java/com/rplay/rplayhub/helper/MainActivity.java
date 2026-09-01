package com.rplay.rplayhub.helper;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/**
 * A plain explainer. The app does its work from the Share sheet, so the launcher screen only
 * needs to say so.
 */
public final class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER);
        int pad = dp(28);
        root.setPadding(pad, pad, pad, pad);
        root.setBackgroundColor(Color.WHITE);

        TextView title = new TextView(this);
        title.setText("rPlayHub Share");
        title.setTextSize(24);
        title.setTextColor(Color.parseColor("#111111"));
        title.setGravity(Gravity.CENTER);

        TextView body = new TextView(this);
        body.setText("Share anything — a photo, a file, a page — and pick “Send to Mac”. "
                + "It shows up on your Mac, ready to drag wherever you want.\n\n"
                + "Your Mac must be running rPlayHub Android with this phone connected.");
        body.setTextSize(16);
        body.setTextColor(Color.parseColor("#444444"));
        body.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams bodyParams = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        bodyParams.topMargin = dp(16);
        body.setLayoutParams(bodyParams);

        root.addView(title);
        root.addView(body);
        setContentView(root);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
