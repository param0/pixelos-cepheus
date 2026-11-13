/*
 * SPDX-License-Identifier: Apache-2.0
 */

package org.lineageos.settings.cepheus;

import android.os.Bundle;

import com.android.settingslib.collapsingtoolbar.CollapsingToolbarBaseActivity;

public class DisplayExtrasActivity extends CollapsingToolbarBaseActivity {

    private static final String TAG_DISPLAY = "displayextras";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        getSupportFragmentManager()
                .beginTransaction()
                .replace(com.android.settingslib.collapsingtoolbar.R.id.content_frame,
                        new DisplayExtrasFragment(), TAG_DISPLAY)
                .commit();
    }
}
