/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * Обработчик боковой клавиши «AI» на Xiaomi Mi 9 (cepheus).
 *
 * Загружается не приложением, а самим system_server: PhoneWindowManager
 * читает config_deviceKeyHandlerLibs / config_deviceKeyHandlerClasses и
 * создаёт этот класс через PathClassLoader (PhoneWindowManager.java:2617).
 * Вызов идёт из interceptKeyBeforeQueueing (строка 4740) — то есть ДО
 * switch(keyCode), который обрабатывает KEYCODE_ASSIST на строке 5050.
 * Благодаря этому мы получаем клавишу первыми и решаем, что с ней делать.
 *
 * Контракт DeviceKeyHandler: вернуть null — событие поглощено, вернуть
 * сам event — пропустить дальше по обычному пути.
 */

package org.lineageos.settings.cepheus.keyhandler;

import android.app.SearchManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.os.SystemClock;
import android.os.UserHandle;
import android.provider.Settings;
import android.util.Log;
import android.view.KeyEvent;

import com.android.internal.app.AssistUtils;
import com.android.internal.os.DeviceKeyHandler;

public class KeyHandler implements DeviceKeyHandler {

    private static final String TAG = "CepheusKeyHandler";

    /**
     * KEY_AI = 0x2b1 (include/uapi/linux/input-event-codes.h:647).
     * Именно этот код объявлен для клавиши в cepheus-sm8150.dtsi:254.
     */
    private static final int SCANCODE_AI_KEY = 689;

    /** Ключи в Settings.System — их пишет экран настроек CepheusParts. */
    public static final String SETTING_ACTION = "cepheus_ai_key_action";
    public static final String SETTING_PACKAGE = "cepheus_ai_key_package";

    public static final int ACTION_ASSISTANT = 0;
    public static final int ACTION_APP = 1;
    public static final int ACTION_NOTHING = 2;

    private final Context mContext;

    public KeyHandler(Context context) {
        mContext = context;
    }

    @Override
    public KeyEvent handleKeyEvent(KeyEvent event) {
        if (event.getScanCode() != SCANCODE_AI_KEY) {
            return event;
        }

        final int action = Settings.System.getIntForUser(mContext.getContentResolver(),
                SETTING_ACTION, ACTION_ASSISTANT, UserHandle.USER_CURRENT);

        // Реагируем только на первое нажатие. Отпускание и автоповтор глушим,
        // чтобы KEYCODE_ASSIST не утёк в приложение.
        if (event.getAction() != KeyEvent.ACTION_DOWN || event.getRepeatCount() != 0) {
            return null;
        }

        if (action == ACTION_ASSISTANT) {
            launchAssistant();
        } else if (action == ACTION_APP) {
            launchApp();
        }

        return null;
    }

    /**
     * Поднимает ассистента так же, как угловой свайп, — всплывающим окном
     * поверх текущего экрана, а не запуском приложения на весь экран.
     *
     * Разницу делает единственный extra: AssistUtils.INVOCATION_TYPE_KEY.
     * Значение INVOCATION_TYPE_GESTURE (1) соответствует экранному жесту, и
     * ассистент показывает компактный оверлей. Если отдать событие дальше
     * в PhoneWindowManager, тот вызовет launchAssistAction с типом для
     * физической клавиши, и откроется полноэкранное приложение.
     */
    private void launchAssistant() {
        final Bundle args = new Bundle();
        args.putInt(AssistUtils.INVOCATION_TYPE_KEY, AssistUtils.INVOCATION_TYPE_GESTURE);
        args.putLong(Intent.EXTRA_TIME, SystemClock.uptimeMillis());

        final SearchManager sm = mContext.getSystemService(SearchManager.class);
        if (sm == null) {
            Log.w(TAG, "SearchManager недоступен");
            return;
        }
        try {
            sm.launchAssist(args);
        } catch (Exception e) {
            Log.e(TAG, "Не удалось вызвать ассистента", e);
        }
    }

    private void launchApp() {
        final String pkg = Settings.System.getStringForUser(mContext.getContentResolver(),
                SETTING_PACKAGE, UserHandle.USER_CURRENT);
        if (pkg == null || pkg.isEmpty()) {
            Log.w(TAG, "Приложение для боковой клавиши не выбрано");
            return;
        }

        final PackageManager pm = mContext.getPackageManager();
        final Intent intent = pm.getLaunchIntentForPackage(pkg);
        if (intent == null) {
            Log.w(TAG, "У пакета " + pkg + " нет launch-intent, пропускаю");
            return;
        }

        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
        try {
            mContext.startActivityAsUser(intent, UserHandle.CURRENT);
        } catch (Exception e) {
            Log.e(TAG, "Не удалось запустить " + pkg, e);
        }
    }
}
