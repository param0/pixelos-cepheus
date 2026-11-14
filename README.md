# PixelOS 17 для Xiaomi Mi 9 (cepheus) — неофициальная сборка

Android 17 (SDK 37) на Mi 9. Собрано из исходников PixelOS `seventeen`
с деревьями устройства от LineageOS.

Сборка **неофициальная**, поддержки PixelOS не имеет, за последствия
установки отвечает тот, кто прошивает.

---

## Известные проблемы

**1. Не работает двойной тап для пробуждения.**
Переключатель «Нажмите, чтобы активировать» в *Настройки → Экран* есть и
включается, но экран не просыпается. Вся цепочка проверена и исправна:
драйвер шлёт `KEY_WAKEUP` по жесту, узел `/sys/touchpanel/double_tap`
создаётся, SELinux-метка и права power HAL на месте, раскладка с флагом
`WAKE` добавлена. Причина пока не найдена.
Обходного пути нет, будите кнопкой питания.

**2. Цвета по умолчанию выглядят жёлтыми.**
Лечится один раз: *Настройки → Экран → Цвета → **Насыщенные***.
Причина: QDCM-калибровка панели корректно отрабатывает только родной режим
без цветоуправления, а управляемые режимы (Естественные/Яркие) целят в
точный D65 и на фоне холодного белого этой панели читаются как жёлтые.
В сборке «Насыщенные» уже выставлены режимом по умолчанию, но на
**обновлении поверх** старой прошивки сохранившееся в `/data` значение
перебивает дефолт — поэтому выберите режим руками.

---

## Что добавлено сверх обычной сборки

**Настройка боковой кнопки.** *Настройки → Система → Боковая кнопка.*
Аппаратная клавиша «AI» на торце Mi 9 в стоке не делает ничего. Теперь ей
можно назначить:

* **Ассистент** — вызывает выбранного по умолчанию ассистента (Gemini, если
  он выбран в *Настройки → Приложения → Приложения по умолчанию → Цифровой
  помощник*) компактным всплывающим окном, как угловой свайп, а не
  полноэкранным приложением;
* **Открыть приложение** — любое из установленных;
* **Ничего**.

**Выбор частоты обновления и размытия.** *Настройки → Экран → Экран (Mi 9).*
Список частот строится из того, что реально отдаёт панель. На этой сборке
панель стоковая (60 Гц), поэтому пункт частоты скрыт — он появится, если
прошить dtbo с дополнительными режимами.
Переключатель размытия окон гасит разом фон шторки, диалоги и переходы
приложений — заметно разгружает графику на Snapdragon 855.

**Выбор цветового режима.** *Настройки → Экран → Цвета.* В PixelOS отключён
lineage-sdk, вместе с ним пропал LiveDisplay, и управлять цветом было нечем.
Включён штатный механизм AOSP с четырьмя режимами.

**Оптимизация под Snapdragon 855.** SystemUI и лаунчер компилируются AOT с
фильтром `speed` — это два процесса, рисующие каждый кадр интерфейса.

**Прочее.** Исправлен заезд часов и иконок статусбара в скруглённые углы
экрана.

---

## Установка

Нужен recovery, умеющий retrofit dynamic partitions (super 6 ГБ на
`system`/`vendor`/`cust`). Устройство A-only, слотов нет — **сделайте бэкап**,
откат возможен только полной перепрошивкой.

Пакет разрезан на части, потому что GitHub не принимает файлы больше 2 ГиБ.

Склейка, Linux/macOS:

```
cat PixelOS_cepheus-17.0-20261112-1815.zip.part-* > PixelOS_cepheus-17.0-20261112-1815.zip
```

Windows (PowerShell):

```
cmd /c copy /b PixelOS_cepheus-17.0-20261112-1815.zip.part-00 + PixelOS_cepheus-17.0-20261112-1815.zip.part-01 PixelOS_cepheus-17.0-20261112-1815.zip
```

Проверьте контрольную сумму из `SHA256SUMS` и прошивайте:

```
adb reboot sideload-auto-reboot
adb sideload PixelOS_cepheus-17.0-20261112-1815.zip
```

При первой установке — вайп data (f2fs).

---

## Сборка из исходников

```
repo init -u https://github.com/PixelOS-AOSP/android_manifest.git -b seventeen --git-lfs
repo sync
```

Деревья устройства в манифест PixelOS не входят, добавьте
`.repo/local_manifests/cepheus.xml` — его содержимое генерирует сам скрипт.

Ревизии, на которых собран этот релиз:

| проект | путь в дереве | ветка | коммит |
|---|---|---|---|
| [`android_manifest`](https://github.com/PixelOS-AOSP/android_manifest) | `.repo/manifests` | [`seventeen`](https://github.com/PixelOS-AOSP/android_manifest/tree/seventeen) | [`29f6010`](https://github.com/PixelOS-AOSP/android_manifest/commit/29f6010) |
| [`android_device_xiaomi_cepheus`](https://github.com/xiaomi-sm8150-devs/android_device_xiaomi_cepheus) | `device/xiaomi/cepheus` | [`lineage-23.2`](https://github.com/xiaomi-sm8150-devs/android_device_xiaomi_cepheus/tree/lineage-23.2) | [`3fae840`](https://github.com/xiaomi-sm8150-devs/android_device_xiaomi_cepheus/commit/3fae840) |
| [`android_device_xiaomi_sm8150-common`](https://github.com/xiaomi-sm8150-devs/android_device_xiaomi_sm8150-common) | `device/xiaomi/sm8150-common` | [`lineage-24.0`](https://github.com/xiaomi-sm8150-devs/android_device_xiaomi_sm8150-common/tree/lineage-24.0) | [`f498a68`](https://github.com/xiaomi-sm8150-devs/android_device_xiaomi_sm8150-common/commit/f498a68) |
| [`proprietary_vendor_xiaomi_cepheus`](https://github.com/xiaomi-sm8150-devs/proprietary_vendor_xiaomi_cepheus) | `vendor/xiaomi/cepheus` | [`lineage-23.2`](https://github.com/xiaomi-sm8150-devs/proprietary_vendor_xiaomi_cepheus/tree/lineage-23.2) | [`a85ef02`](https://github.com/xiaomi-sm8150-devs/proprietary_vendor_xiaomi_cepheus/commit/a85ef02) |
| [`proprietary_vendor_xiaomi_sm8150-common`](https://github.com/xiaomi-sm8150-devs/proprietary_vendor_xiaomi_sm8150-common) | `vendor/xiaomi/sm8150-common` | [`lineage-24.0`](https://github.com/xiaomi-sm8150-devs/proprietary_vendor_xiaomi_sm8150-common/tree/lineage-24.0) | [`65ef529`](https://github.com/xiaomi-sm8150-devs/proprietary_vendor_xiaomi_sm8150-common/commit/65ef529) |
| [`android_kernel_xiaomi_sm8150`](https://github.com/xiaomi-sm8150-devs/android_kernel_xiaomi_sm8150) | `kernel/xiaomi/sm8150` | [`lineage-24.0`](https://github.com/xiaomi-sm8150-devs/android_kernel_xiaomi_sm8150/tree/lineage-24.0) | [`c8c6230`](https://github.com/xiaomi-sm8150-devs/android_kernel_xiaomi_sm8150/commit/c8c6230) |
| [`android_hardware_xiaomi`](https://github.com/PixelOS-AOSP/android_hardware_xiaomi) | `hardware/xiaomi` | [`seventeen`](https://github.com/PixelOS-AOSP/android_hardware_xiaomi/tree/seventeen) | [`dae6cb6`](https://github.com/PixelOS-AOSP/android_hardware_xiaomi/commit/dae6cb6) |

Запуск:

```
bash build-pixelos-cepheus.sh
```

Скрипт сам поднимает `repo init`/`sync`, создаёт local manifest, применяет
правки и собирает. Полезные переопределения перечислены в его шапке;
`PANEL_90HZ=1` включает экспериментальные режимы панели (см. ниже).

### Патчи

Если собираете вручную или просто хотите посмотреть, что именно изменено,
в каталоге `patches/` лежат готовые диффы против указанных выше коммитов:

| файл | дерево | что внутри |
|---|---|---|
| `0001-device_xiaomi_cepheus.patch` | `device/xiaomi/cepheus` | продукт `custom_cepheus`, keylayout'ы, обработчик клавиши, приложение `CepheusParts`, цветовые режимы и отступ от скруглений, AOT-оптимизация — 21 файл |
| `0002-device_xiaomi_sm8150-common.patch` | `device/xiaomi/sm8150-common` | дефолтный цветовой режим, потолок частоты на локскрине, вырезанный блок `accessories` — 11 файлов |
| `0003-kernel_xiaomi_sm8150-90hz-EXPERIMENTAL.patch` | `kernel/xiaomi/sm8150` | **не применён в релизе.** Режимы 72/81/90 Гц для всех шести ревизий панели. Работает нестабильно, подробности ниже |

Применяются обычным `git apply` из корня соответствующего дерева:

```
cd device/xiaomi/cepheus && git apply /путь/к/patches/0001-device_xiaomi_cepheus.patch
```

Запускать скрипт после этого не нужно — он делает ровно то же самое, просто
идемпотентно и с комментариями. Патчи полезнее для чтения и ревью.

### Про адаптацию Android 16 → 17

Дерево cepheus существует только для LineageOS 23.2 (Android 16), а PixelOS —
это Android 17. Переписывать почти ничего не пришлось: общее дерево
`sm8150-common` уже переведено на `lineage-24.0`, вендорное общее дерево
вообще существует только в этой ветке, а ядро на обеих ветках — один и тот
же коммит. Своего у cepheus мало, и под A17 оно не ломается.

Реальных правок в скрипте десять (P1–P10), каждая подробно откомментирована
прямо в коде. Ключевые:

* продукт переименован в `custom_cepheus` — PixelOS включает Lineage-инфраструктуру
  по непустому `CUSTOM_BUILD`, а он выводится из имени продукта;
* релиз-конфиг `cp2a` (Android 17);
* отключён EPPE — в PixelOS жёстко выключен lineage-sdk, а общее дерево его тянет;
* вырезан блок `accessories` из общего дерева: он ссылается на модуль,
  которого нет ни в одном публичном `hardware/xiaomi`.

### Про 90 Гц

Панель Mi 9 (Samsung EA8076) разгоняется до 90 Гц, в сети есть готовый dtbo.
В этой сборке разгон **выключен**: на тестовом аппарате он оказался
нерабочим в обоих вариантах.

С расчётными PHY-таймингами (свойство `qcom,mdss-dsi-panel-phy-timings`
убрано, чтобы драйвер посчитал их сам под каждый битклок) ломаются яркость
и пробуждение экрана. С вендорными таймингами из донорского dtbo список
режимов обрывается на 72 Гц и они заметно лагают.

Важная деталь для тех, кто продолжит: у Mi 9 **шесть ревизий** панели
(`_cmd`, `_f1`, `_f1p2`, `_f1p2_2`, `_f1mp`, `_f1s`), и патчить надо все —
какая стоит в конкретном аппарате, определяется при загрузке.

Проверять правки панели нужно **только** через `m dtboimage` и
`fastboot flash dtbo`: прошивка одного раздела откатывается за минуту, а
неудачная полная сборка стоит нескольких часов.

---

## Лицензии

Скрипт сборки и приложение `CepheusParts` — Apache-2.0.
Деревья устройства, ядро и `hardware/xiaomi` принадлежат их авторам
(LineageOS, Xiaomi SM8150 devs, PixelOS) и здесь не дублируются — в таблице
выше указаны точные ревизии.
