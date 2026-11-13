/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Засев значений по умолчанию для Circle to Search.
 *
 * Почему это нужно. NavBarHelper.java:494-506 берёт признак «долгое нажатие
 * на полоску навигации вызывает поиск» так:
 *     Settings.Secure.getInt(SEARCH_ALL_ENTRYPOINTS_ENABLED, значение_ресурса)
 * Ресурсный дефолт (config_searchAllEntrypointsEnabledDefault) равен true,
 * то есть при ОТСУТСТВУЮЩЕЙ настройке всё работает. Но если ключ однажды
 * записан нулём — ресурс уже не спасает, и функция молча выключена.
 *
 * Поэтому пишем единицу только когда ключа нет вообще. Это именно значение
 * по умолчанию, а не принуждение: переключатель в
 * «Настройки -> Жесты -> Навигация» продолжает работать, и выбор
 * пользователя не затирается при следующей загрузке.
 */

package org.lineageos.settings.cepheus;

import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.Context;
import android.content.Intent;
import android.provider.Settings;
import android.util.Log;

public class BootCompletedReceiver extends BroadcastReceiver {

    private static final String TAG = "CepheusParts";

    /** Ключи те же, что читает NavBarHelper. */
    private static final String[] DEFAULT_ON = {
        Settings.Secure.SEARCH_ALL_ENTRYPOINTS_ENABLED,
        Settings.Secure.ASSIST_LONG_PRESS_HOME_ENABLED,
    };

    @Override
    public void onReceive(Context context, Intent intent) {
        final ContentResolver cr = context.getContentResolver();
        for (String key : DEFAULT_ON) {
            if (Settings.Secure.getString(cr, key) == null) {
                Settings.Secure.putInt(cr, key, 1);
                Log.i(TAG, "Выставлено значение по умолчанию: " + key + "=1");
            }
        }
    }
}
