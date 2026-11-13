/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Экран «Боковая кнопка». Пишет выбор в Settings.System, откуда его читает
 * org.lineageos.settings.cepheus.keyhandler.KeyHandler, живущий внутри
 * system_server. Поэтому обычный SharedPreferences тут не годится —
 * system_server не имеет доступа к приватным настройкам приложения.
 *
 * Запись в Settings.System разрешена, потому что приложение подписано
 * платформенным ключом и работает под android.uid.system (см. манифест).
 */

package org.lineageos.settings.cepheus;

import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.Bundle;
import android.provider.Settings;

import androidx.preference.ListPreference;
import androidx.preference.Preference;

import com.android.settingslib.widget.SettingsBasePreferenceFragment;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public class AiKeySettingsFragment extends SettingsBasePreferenceFragment
        implements Preference.OnPreferenceChangeListener {

    /** Должно совпадать с KeyHandler.SETTING_ACTION / SETTING_PACKAGE. */
    private static final String SETTING_ACTION = "cepheus_ai_key_action";
    private static final String SETTING_PACKAGE = "cepheus_ai_key_package";

    private static final String PREF_ACTION = "ai_key_action";
    private static final String PREF_APP = "ai_key_app";

    private static final int ACTION_ASSISTANT = 0;
    private static final int ACTION_APP = 1;

    private ListPreference mActionPref;
    private ListPreference mAppPref;

    @Override
    public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
        setPreferencesFromResource(R.xml.ai_key_settings, rootKey);

        mActionPref = findPreference(PREF_ACTION);
        mAppPref = findPreference(PREF_APP);

        // Значения храним в Settings.System, а не в SharedPreferences.
        mActionPref.setPersistent(false);
        mAppPref.setPersistent(false);

        loadApps();

        final int action = Settings.System.getInt(
                requireContext().getContentResolver(), SETTING_ACTION, ACTION_ASSISTANT);
        mActionPref.setValue(String.valueOf(action));
        mActionPref.setOnPreferenceChangeListener(this);

        final String pkg = Settings.System.getString(
                requireContext().getContentResolver(), SETTING_PACKAGE);
        if (pkg != null && !pkg.isEmpty()) {
            mAppPref.setValue(pkg);
        }
        mAppPref.setOnPreferenceChangeListener(this);

        updateState(action);
    }

    /** Список приложений, у которых есть значок запуска. */
    private void loadApps() {
        final PackageManager pm = requireContext().getPackageManager();

        final Intent launcherIntent = new Intent(Intent.ACTION_MAIN, null);
        launcherIntent.addCategory(Intent.CATEGORY_LAUNCHER);

        final List<ResolveInfo> apps = pm.queryIntentActivities(launcherIntent, 0);
        Collections.sort(apps, new ResolveInfo.DisplayNameComparator(pm));

        final List<CharSequence> labels = new ArrayList<>();
        final List<CharSequence> values = new ArrayList<>();
        for (ResolveInfo info : apps) {
            final String pkg = info.activityInfo.packageName;
            if (values.contains(pkg)) {
                continue; // у приложения может быть несколько activity в лаунчере
            }
            labels.add(info.loadLabel(pm));
            values.add(pkg);
        }

        mAppPref.setEntries(labels.toArray(new CharSequence[0]));
        mAppPref.setEntryValues(values.toArray(new CharSequence[0]));
    }

    private void updateState(int action) {
        mAppPref.setVisible(action == ACTION_APP);

        final CharSequence actionEntry = mActionPref.getEntry();
        if (actionEntry != null) {
            mActionPref.setSummary(actionEntry);
        }

        final CharSequence appEntry = mAppPref.getEntry();
        mAppPref.setSummary(appEntry != null ? appEntry : getString(R.string.ai_key_app_none));
    }

    @Override
    public boolean onPreferenceChange(Preference preference, Object newValue) {
        if (preference == mActionPref) {
            final int action = Integer.parseInt((String) newValue);
            Settings.System.putInt(
                    requireContext().getContentResolver(), SETTING_ACTION, action);
            mActionPref.setValue((String) newValue);
            updateState(action);
            return true;
        }

        if (preference == mAppPref) {
            Settings.System.putString(
                    requireContext().getContentResolver(), SETTING_PACKAGE, (String) newValue);
            mAppPref.setValue((String) newValue);
            updateState(Integer.parseInt(mActionPref.getValue()));
            return true;
        }

        return false;
    }
}
