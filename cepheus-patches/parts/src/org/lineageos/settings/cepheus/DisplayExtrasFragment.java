/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Экран «Экран (Mi 9)»: размытие окон и выбор частоты обновления.
 *
 * РАЗМЫТИЕ. В AOSP переключатель есть только в «Для разработчиков»
 * (development_settings.xml, ключ enable_blurs_on_windows). Здесь тот же
 * Settings.Global.DISABLE_WINDOW_BLURS вынесен в обычные настройки.
 * Применяется мгновенно: WindowManager слушает значение через ContentObserver
 * (BlurController.java:82) и гасит разом все размытия — и фон шторки, и
 * переходы при открытии/закрытии приложений, это один механизм.
 *
 * ЧАСТОТА. Штатный переключатель «Плавное изображение» умеет только
 * «60 или максимум». Панель cepheus после правки dtbo отдаёт четыре режима
 * (60/72/81/90), поэтому здесь полный список. Пишем в
 * Settings.System.PEAK_REFRESH_RATE — её читает DisplayModeDirector:1262,
 * подставляя config_defaultPeakRefreshRate как значение по умолчанию.
 * MIN_REFRESH_RATE оставляем нулём: это позволяет системе опускать частоту
 * на статичной картинке и экономить батарею. Выбранное значение —
 * это потолок, а не жёсткая фиксация.
 */

package org.lineageos.settings.cepheus;

import android.os.Bundle;
import android.provider.Settings;
import android.view.Display;

import androidx.preference.ListPreference;
import androidx.preference.Preference;
import androidx.preference.SwitchPreferenceCompat;

import com.android.settingslib.widget.SettingsBasePreferenceFragment;

import java.util.ArrayList;
import java.util.List;
import java.util.TreeSet;

public class DisplayExtrasFragment extends SettingsBasePreferenceFragment
        implements Preference.OnPreferenceChangeListener {

    private static final String PREF_BLUR = "window_blurs";
    private static final String PREF_RATE = "refresh_rate";

    private SwitchPreferenceCompat mBlurPref;
    private ListPreference mRatePref;

    @Override
    public void onCreatePreferences(Bundle savedInstanceState, String rootKey) {
        setPreferencesFromResource(R.xml.display_extras, rootKey);

        mBlurPref = findPreference(PREF_BLUR);
        mRatePref = findPreference(PREF_RATE);

        mBlurPref.setPersistent(false);
        mRatePref.setPersistent(false);

        // В системе хранится «выключено», в интерфейсе показываем «включено».
        final boolean disabled = Settings.Global.getInt(
                requireContext().getContentResolver(),
                Settings.Global.DISABLE_WINDOW_BLURS, 0) == 1;
        mBlurPref.setChecked(!disabled);
        mBlurPref.setOnPreferenceChangeListener(this);

        loadRates();
        mRatePref.setOnPreferenceChangeListener(this);
        updateRateSummary();
    }

    /**
     * Список частот берём у самого дисплея, а не зашиваем числами: если
     * режимы в dtbo изменятся, экран подстроится сам. Если панель отдаёт
     * только 60 — пункт прячем, чтобы не вводить в заблуждение.
     */
    private void loadRates() {
        final Display display = requireContext().getDisplay();
        final TreeSet<Integer> rates = new TreeSet<>();
        if (display != null) {
            for (Display.Mode mode : display.getSupportedModes()) {
                rates.add(Math.round(mode.getRefreshRate()));
            }
        }

        if (rates.size() < 2) {
            mRatePref.setVisible(false);
            return;
        }

        final List<CharSequence> labels = new ArrayList<>();
        final List<CharSequence> values = new ArrayList<>();
        for (Integer r : rates) {
            labels.add(r + " " + getString(R.string.refresh_rate_hz));
            values.add(String.valueOf(r));
        }
        mRatePref.setEntries(labels.toArray(new CharSequence[0]));
        mRatePref.setEntryValues(values.toArray(new CharSequence[0]));

        final float peak = Settings.System.getFloat(
                requireContext().getContentResolver(),
                Settings.System.PEAK_REFRESH_RATE, rates.last());
        mRatePref.setValue(String.valueOf(Math.round(peak)));
    }

    private void updateRateSummary() {
        final CharSequence entry = mRatePref.getEntry();
        if (entry != null) {
            mRatePref.setSummary(entry);
        }
    }

    @Override
    public boolean onPreferenceChange(Preference preference, Object newValue) {
        if (preference == mBlurPref) {
            final boolean enabled = (Boolean) newValue;
            Settings.Global.putInt(requireContext().getContentResolver(),
                    Settings.Global.DISABLE_WINDOW_BLURS, enabled ? 0 : 1);
            return true;
        }

        if (preference == mRatePref) {
            final float rate = Float.parseFloat((String) newValue);
            Settings.System.putFloat(requireContext().getContentResolver(),
                    Settings.System.PEAK_REFRESH_RATE, rate);
            // ноль = разрешаем системе опускать частоту ради батареи
            Settings.System.putFloat(requireContext().getContentResolver(),
                    Settings.System.MIN_REFRESH_RATE, 0f);
            mRatePref.setValue((String) newValue);
            updateRateSummary();
            return true;
        }

        return false;
    }
}
