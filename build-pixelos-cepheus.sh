#!/bin/bash
# PixelOS 17 (манифест seventeen, база AOSP android-17.0.0_r1)
# для Xiaomi Mi 9 (M1902F1G / cepheus)
#
# Запуск с хоста:  bash ~/build-pixelos-cepheus.sh
# Скрипт сам зайдёт в distrobox-контейнер "rom" и продолжит уже внутри него.
#
#   Синк   -> 3 потока  (медленно, но переживает обрывы; есть авто-ретраи)
#   Сборка -> 16 потоков
#
# ============================================================================
# ЧТО ИМЕННО СОБИРАЕТСЯ И ПОЧЕМУ ТАК
# ============================================================================
#
# Проблема из постановки задачи: дерево cepheus есть только для LineageOS 23.2
# (Android 16), а PixelOS — seventeen (Android 17). Но «адаптировать с нуля»
# почти ничего не нужно, потому что:
#
#  1) Общее дерево платформы ОДНО НА ВСЕ sm8150-устройства Xiaomi, и оно УЖЕ
#     переведено на Android 17: android_device_xiaomi_sm8150-common имеет ветку
#     lineage-24.0 (последний коммит 28.10.2026, активная). Именно в ней лежит
#     99% платформенного кода: BoardConfigCommon.mk, разделы, sepolicy, HAL'ы,
#     rootdir, libinit, udfps, XiaomiParts. Дельта 23.2 -> 24.0 там крошечная
#     (убраны disable_configstore / fastbootd / PRODUCT_ENABLE_UFFD_GC /
#     TARGET_KERNEL_NO_GCC, добавлены libion legacy_impl и sepolicy libion).
#     Поэтому общее дерево берём 24.0 и НЕ правим.
#
#  2) Вендорное общее дерево вообще существует только как lineage-24.0
#     (ветки 23.2 у proprietary_vendor_xiaomi_sm8150-common нет), так что
#     выбора тут нет — и это удачно, оно согласовано с device-common 24.0.
#
#  3) Ядро: android_kernel_xiaomi_sm8150 lineage-24.0 и lineage-23.2 — это
#     один и тот же коммит (c8c62303). Разницы нет, берём 24.0.
#
#  4) Своего у cepheus мало: device.mk, BoardConfig.mk, audio/*.xml,
#     libinit-вариант, 6 RRO-оверлеев. Ничего из этого под A17 не ломается:
#     TARGET_IS_LEGACY (retrofit dynamic на 6 ГБ super, A-only) полностью
#     обрабатывается общим деревом 24.0, а soong_config-мост
#     (xiaomi_msmnile/variant_lib) в 24.0 не изменился.
#
#  5) PixelOS собирает Lineage-деревья нативно: PixelOS-AOSP/android_build —
#     это форк build/make от LineageOS, где в core/config.mk стоит
#     "ifneq ($(or $(LINEAGE_BUILD),$(CUSTOM_BUILD)),)" -> подключаются
#     vendor/lineage/config/BoardConfigLineage.mk и
#     device/lineage/sepolicy/common/sepolicy.mk. TARGET_VENDOR_PROP /
#     TARGET_ODM_PROP / TARGET_PRODUCT_PROP там тоже поддержаны. То есть
#     ничего из лексикона Lineage-дерева переписывать не надо.
#
# Поэтому реальных правок всего три, и они ниже в блоке «Правки» (P1..P4).
#
# ============================================================================
# Полезные переопределения:
#   NO_SYNC=1    bash ~/build-pixelos-cepheus.sh   # пропустить repo sync
#   SYNC_ONLY=1  bash ~/build-pixelos-cepheus.sh   # только синк, без сборки
#   WIPE_OUT=1   ...                               # принудительно снести out/
#   WIPE_OUT=0   ...                               # запретить снос out/
#   SYNC_THREADS=1 ...                             # если совсем плохой канал
#   SYNC_DEPTH=0 ...                               # полная история git
#   BUILD_VARIANT=user ...                         # вместо userdebug
#   SPOOF_API32=0 ...                              # не подменять first_api_level
#   KEEP_AWAKE=0 ...                               # разрешить машине уснуть
#   TARGET=bacon ...                               # собрать другую цель вместо pixelos

if [ -z "$CONTAINER_ID" ]; then
    # Мы на хосте. hypridle усыпляет машину через 20 мин простоя (systemctl suspend),
    # а сборка для idle-таймера "активностью" не считается. Держим блокировку logind
    # на всё время работы — hypridle её уважает (ignore_systemd_inhibit не выставлен).
    SELF="$(readlink -f "$0")"
    if [ "${KEEP_AWAKE:-1}" = "1" ] && command -v systemd-inhibit >/dev/null; then
        echo "== Сон и автоблокировка отключены на время сборки (systemd-inhibit) =="
        exec systemd-inhibit \
            --what=idle:sleep:handle-lid-switch \
            --who="PixelOS cepheus build" \
            --why="Идёт сборка PixelOS 17 для cepheus" \
            --mode=block \
            distrobox enter rom -- bash "$SELF" "$@"
    fi
    exec distrobox enter rom -- bash "$SELF" "$@"
fi

set -e

# ==========================================
WORK_DIR="${WORK_DIR:-$HOME/pixelos}"

MANIFEST_URL="https://github.com/PixelOS-AOSP/android_manifest.git"
MANIFEST_BRANCH="seventeen"        # PixelOS 17 (AOSP android-17.0.0_r1)

DEVICE="cepheus"                   # Xiaomi Mi 9, M1902F1G
PRODUCT="custom_$DEVICE"           # PixelOS: breakfast лунчит именно custom_<device>
                                   # (vendor/custom/build/envsetup.sh:
                                   #  CUSTOM_BUILD=$(echo $1 | sed 's/^custom_//'))
RELEASE="cp2a"                     # релиз-конфиг Android 17.
                                   # Источник истины — vendor/lineage/vars/aosp_target_release
                                   # в форке PixelOS: "aosp_target_release=cp2a".
                                   # (у A16-дерева было bp4a)
VARIANT="${BUILD_VARIANT:-userdebug}"
TARGET="${TARGET:-pixelos}"        # цель PixelOS: собирает OTA-zip PixelOS_*.zip
                                   # (vendor/custom/build/tasks/pixelos.mk)

# Деревья устройства. В манифест PixelOS они не входят — добавляем local_manifest.
# Ветки выбраны по принципу «всё общее на 24.0 (A17), своё у cepheus — 23.2,
# другого просто нет»; обоснование в шапке.
DT_COMMON_BRANCH="${DT_COMMON_BRANCH:-lineage-24.0}"
DT_DEVICE_BRANCH="${DT_DEVICE_BRANCH:-lineage-23.2}"

SYNC_THREADS="${SYNC_THREADS:-3}"      # потоки для repo sync
BUILD_THREADS="${BUILD_THREADS:-16}"   # потоки для сборки
SYNC_RETRIES="${SYNC_RETRIES:-8}"      # сколько раз пробовать досинкать при обрывах
SYNC_DEPTH="${SYNC_DEPTH:-1}"          # глубина истории git. На состав дерева не влияет:
                                       # проекты все, просто без старых коммитов.
                                       # SYNC_DEPTH=0 -> полная история (+~150 ГБ).

NO_SYNC="${NO_SYNC:-0}"
SYNC_ONLY="${SYNC_ONLY:-0}"
WIPE_OUT="${WIPE_OUT:-auto}"       # auto = снести out/, если он от другой ветки/манифеста
USE_CCACHE_BUILD="true"
CCACHE_SIZE="${CCACHE_SIZE:-50G}"

# Ограничение параллельных «тяжёлых по памяти» задач (линковка, R8/d8).
# 31 ГБ RAM на 16 потоков полной прошивки — впритык.
HIGHMEM_JOBS="${HIGHMEM_JOBS:-4}"

NEED_FREE_GB="${NEED_FREE_GB:-300}"   # исходники ~130 ГБ + out ~130 ГБ + ccache 50 ГБ
# ==========================================

export PATH="$HOME/.local/bin:$PATH"
LOG_DIR="$WORK_DIR/logs"

echo "=============================================="
echo " PixelOS $MANIFEST_BRANCH -> $DEVICE ($PRODUCT-$RELEASE-$VARIANT)"
echo " common tree: $DT_COMMON_BRANCH   device tree: $DT_DEVICE_BRANCH"
echo " sync: -j$SYNC_THREADS   build: -j$BUILD_THREADS   target: $TARGET"
echo "=============================================="

command -v repo >/dev/null || { echo "!! repo не найден в PATH ($PATH)"; exit 1; }
# --git-lfs обязателен: GMS/Launcher/ThemePicker PixelOS лежат на GitLab через LFS
# (vendor/pixel/gms и компания, remote="gitlab"), без lfs они приедут
# указателями и сборка упадёт на невалидных apk.
command -v git-lfs >/dev/null || { echo "!! git-lfs не найден — PixelOS без него не синкнется"; exit 1; }

# Ядро cepheus собирается ИЗ ИСХОДНИКОВ (TARGET_KERNEL_SOURCE := kernel/xiaomi/sm8150),
# а не берётся пребилтом, поэтому хостовые зависимости ядра нужны реально.
miss=""
for t in bc bison flex make gcc g++ python3 rsync zip unzip lz4 openssl; do
    command -v "$t" >/dev/null || miss="$miss $t"
done
for f in /usr/include/openssl/ssl.h /usr/include/libelf.h; do
    [ -f "$f" ] || miss="$miss $f"
done
if [ -n "$miss" ]; then
    echo "!! В контейнере не хватает для inline-сборки ядра:$miss"
    echo "   sudo apt install bc bison flex build-essential libssl-dev libelf-dev lz4 zip unzip rsync"
    exit 1
fi

# ------------------------------------------------------------------
# Память — самое узкое место этой сборки, и проверять её надо ДО синка.
#
# Фаза анализа Soong — это ОДИН процесс soong_build, и потоки сборки на него
# не влияют никак. Замерено на этом дереве (PixelOS 17 / cp2a / cepheus):
# пик RSS soong_build = 25,4 ГБ. Проверено дважды, в том числе с выключенным
# инкрементальным анализом — цифра та же, OOM повторяется (exit=137).
#
# Почему 31 ГБ RAM при этом НЕ хватает, хотя 25,4 < 31: zram. Это сжатая
# оперативка, его страницы лежат в той же физической RAM. Под нагрузкой ядро
# свапит в zram, тот держит ~25 ГБ сжатыми в ~8 ГБ RAM, и в сумме
# 25 (процесс) + 8 (zram) + остальное > 31 -> kswapd0 зовёт oom-killer.
# Поэтому zram в зачёт не идёт вообще: нужен swap НА ДИСКЕ, он один даёт
# настоящий запас.
#
# ВНИМАНИЕ про XFS (здесь / это именно xfs): swap-файл, созданный fallocate,
# XFS под swapon не отдаёт — у него unwritten extents, swapon падает с
# "Invalid argument". На XFS файл надо занулить через dd.
# ------------------------------------------------------------------
ram_gb=$(free -g | awk '/^Mem:/{print $2}')
# /proc/swaps виден из контейнера как есть — ядро общее с хостом.
disk_swap=0
if [ -r /proc/swaps ]; then
    while read -r swname _; do
        case "$swname" in
            Filename|/dev/zram*) continue ;;
        esac
        disk_swap=1
    done < /proc/swaps
fi

echo "== RAM: ${ram_gb} ГБ, дисковый swap: $([ "$disk_swap" = "1" ] && echo есть || echo 'НЕТ (zram не считается)') =="
# Порог 48 ГБ — не из документации, а из замера: пик 25,4 ГБ плюс kati, ninja,
# page cache и сам zram. На 31 ГБ без дискового swap тут уже дважды был OOM.
if [ "${ram_gb:-0}" -lt 48 ] && [ "$disk_swap" != "1" ]; then
    cat <<'EOF'
!! Нет дискового swap, а RAM меньше 48 ГБ — фаза анализа Soong упадёт по OOM
   (замер на этом дереве: пик soong_build 25,4 ГБ; zram не спасает, см. комментарий выше).

   Лечение — swap-файл на хосте (НЕ в контейнере, нужен sudo).
   На XFS именно dd, не fallocate:

       sudo dd if=/dev/zero of=/swapfile bs=1M count=65536 status=progress
       sudo chmod 600 /swapfile
       sudo mkswap /swapfile
       sudo swapon /swapfile

   Проверить:  swapon --show   (должна появиться строка /swapfile, TYPE=file)
   Убрать потом:  sudo swapoff /swapfile && sudo rm /swapfile
   Чтобы жил после перезагрузки — строка в /etc/fstab:
       /swapfile none swap defaults 0 0

   Продолжить без swap всё равно: FORCE_LOWMEM=1
EOF
    [ "${FORCE_LOWMEM:-0}" = "1" ] || exit 1
fi

mkdir -p "$WORK_DIR" "$LOG_DIR" && cd "$WORK_DIR"

free_gb=$(df -BG --output=avail . | tail -1 | tr -dc '0-9')
echo "== Свободно на разделе с $WORK_DIR: ${free_gb} ГБ (хотим >= ${NEED_FREE_GB}) =="
if [ "$free_gb" -lt "$NEED_FREE_GB" ]; then
    echo "!! Места мало для полной прошивки (не recovery): исходники ~130 ГБ + out ~130 ГБ."
    echo "   Если уверен — запусти с NEED_FREE_GB=$free_gb"
    if [ "$NEED_FREE_GB" != "$free_gb" ]; then
        exit 1
    fi
fi

if [ "$NO_SYNC" != "1" ]; then

echo "== repo init -b $MANIFEST_BRANCH --git-lfs =="
repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --git-lfs --no-clone-bundle \
    $([ "$SYNC_DEPTH" != "0" ] && echo "--depth=$SYNC_DEPTH")

# ------------------------------------------------------------------
# local_manifest: деревья устройства.
#
# PixelOS, в отличие от LineageOS, НЕ запускает roomservice из breakfast
# (vendor/custom/build/envsetup.sh: breakfast просто зовёт lunch), поэтому
# lineage.dependencies сами по себе ничего не подтянут — перечисляем всё руками,
# включая hardware/xiaomi (его в манифесте PixelOS нет вообще, а общее дерево
# ссылается на //hardware/xiaomi:xiaomifingerprint_headers,
# //hardware/xiaomi:libudfps_extension.xiaomi,
# //hardware/xiaomi:vendor.xiaomi.hardware.motor-V1.0-java и
# hardware/xiaomi/vintf/xiaomi_framework_compatibility_matrix.xml).
#
# hardware/xiaomi берём из форка PixelOS (ветка seventeen): это та же база, что
# у LineageOS lineage-24.0, плюс их face-unlock HAL; все нужные cepheus модули
# (fingerprint-заголовки, udfps-extension, motor HIDL) в нём есть.
# ------------------------------------------------------------------
echo "== local_manifests/cepheus.xml =="
mkdir -p .repo/local_manifests
cat > .repo/local_manifests/cepheus.xml << EOF
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <remote name="sm8150-devs" fetch="https://github.com/xiaomi-sm8150-devs" />
  <remote name="pixelos" fetch="https://github.com/PixelOS-AOSP" />

  <!-- своё у cepheus: только 23.2, другой ветки не существует -->
  <project path="device/xiaomi/$DEVICE" name="android_device_xiaomi_$DEVICE"
           remote="sm8150-devs" revision="$DT_DEVICE_BRANCH" />
  <project path="vendor/xiaomi/$DEVICE" name="proprietary_vendor_xiaomi_$DEVICE"
           remote="sm8150-devs" revision="$DT_DEVICE_BRANCH" />

  <!-- общее для всех sm8150 Xiaomi: уже переведено на Android 17 -->
  <project path="device/xiaomi/sm8150-common" name="android_device_xiaomi_sm8150-common"
           remote="sm8150-devs" revision="$DT_COMMON_BRANCH" />
  <project path="vendor/xiaomi/sm8150-common" name="proprietary_vendor_xiaomi_sm8150-common"
           remote="sm8150-devs" revision="$DT_COMMON_BRANCH" />
  <project path="kernel/xiaomi/sm8150" name="android_kernel_xiaomi_sm8150"
           remote="sm8150-devs" revision="$DT_COMMON_BRANCH" />

  <project path="hardware/xiaomi" name="android_hardware_xiaomi"
           remote="pixelos" revision="seventeen" />
</manifest>
EOF

# ------------------------------------------------------------------
# Синк с автоматическими повторами при обрывах. repo sync возвращает
# ненулевой код, если хоть один проект не докачался, поэтому просто крутим
# цикл — уже скачанное не перекачивается.
#
# Гоним через script(1): repo печатает прогресс только когда видит tty, а в
# обычном пайпе на tee замолкает на часы. script даёт ему pty, и прогресс
# виден в терминале, и лог пишется.
#
# ВАЖНО: без --no-tags. В манифесте PixelOS default revision — это ТЕГ
# (refs/tags/android-17.0.0_r1), и при --no-tags часть AOSP-проектов не находит
# свою ревизию. В AERA-скрипте --no-tags был безопасен, там ветки.
# ------------------------------------------------------------------
echo "== repo sync -j$SYNC_THREADS (до $SYNC_RETRIES попыток) =="
SYNC_CMD="repo sync -c -j$SYNC_THREADS --force-sync --no-clone-bundle --retry-fetches=3 --optimized-fetch"
sync_ok=0
for attempt in $(seq 1 "$SYNC_RETRIES"); do
    echo "---- sync: попытка $attempt/$SYNC_RETRIES ----"
    # Код возврата снимаем явно, а не через "$?" после fi: при set -e падение
    # repo sync в теле if (тело, в отличие от условия, под set -e попадает)
    # оборвало бы скрипт, и цикл ретраев никогда бы не отработал.
    rc_sync=0
    if command -v script >/dev/null; then
        script -q -e -a "$LOG_DIR/sync.log" -c "$SYNC_CMD" || rc_sync=$?
    else
        # в пайпе смотрим именно repo, а не tee
        $SYNC_CMD 2>&1 | tee -a "$LOG_DIR/sync.log"
        rc_sync=${PIPESTATUS[0]}
    fi
    if [ "$rc_sync" -eq 0 ]; then
        sync_ok=1
        break
    fi
    echo "---- обрыв (код $rc_sync), пауза 20с перед повтором ----"
    sleep 20
done

if [ "$sync_ok" != "1" ]; then
    cat <<EOF

!! repo sync не завершился за $SYNC_RETRIES попыток (лог: $LOG_DIR/sync.log).
   Включи VPN (FlClashX) и перезапусти этот же скрипт — докачает только
   недостающее. GitLab (vendor/pixel/*) и LFS особенно любят отваливаться.
EOF
    exit 1
fi

echo "== repo sync завершён =="

fi # NO_SYNC

DEVICE_PATH="device/xiaomi/$DEVICE"
COMMON_PATH="device/xiaomi/sm8150-common"

for p in "$DEVICE_PATH" "$COMMON_PATH" "vendor/xiaomi/$DEVICE" \
         "vendor/xiaomi/sm8150-common" "kernel/xiaomi/sm8150" "hardware/xiaomi" \
         "vendor/custom" "vendor/lineage"; do
    [ -d "$WORK_DIR/$p" ] || { echo "!! нет $p — синк не доехал"; exit 1; }
done

# ============================================================================
# ПРАВКИ. Все идемпотентны и применяются при каждом запуске.
# ============================================================================
echo "== Правлю дерево под PixelOS 17 =="

# ----------------------------------------------------------------------------
# P1) Продуктовый makefile: lineage_cepheus -> custom_cepheus.
#
# Два независимых требования PixelOS именно к ИМЕНИ продукта:
#   * breakfast/lunch: vendor/custom/build/envsetup.sh снимает с имени префикс
#     "custom_" и кладёт остаток в CUSTOM_BUILD. CUSTOM_BUILD потом уходит в
#     ro.custom.device (vendor/custom/config/version.mk) и в условие
#     "ifneq ($(or $(LINEAGE_BUILD),$(CUSTOM_BUILD)),)" в core/config.mk форка
#     build/make — то есть именно по нему включаются BoardConfigLineage.mk и
#     lineage-sepolicy. Соберись как lineage_cepheus — CUSTOM_BUILD останется
#     пустым и половина Lineage-инфраструктуры просто не подключится.
#   * EPPE: vendor/custom/config/common.mk ищет
#     $(wildcard device/*/$(CUSTOM_BUILD)/$(TARGET_PRODUCT).mk),
#     то есть файл обязан называться custom_cepheus.mk.
#
# Генерируем его ИЗ lineage_cepheus.mk, а не пишем копию руками: тогда правки
# апстрима (BuildFingerprint, PRODUCT_MODEL и т.п.) подхватятся сами.
# Сам lineage_cepheus.mk не удаляем — он в форке PixelOS всё ещё парсится
# (vendor/lineage/config/common_full_phone.mk на месте), пусть остаётся для
# сравнения.
# ----------------------------------------------------------------------------
{
    cat << 'HDR'
#
# Сгенерировано build-pixelos-cepheus.sh из lineage_cepheus.mk. НЕ ПРАВИТЬ РУКАМИ.
#
HDR
    sed -e 's|vendor/lineage/config/common_full_phone.mk|vendor/custom/config/common_full_phone.mk|' \
        -e "s|^PRODUCT_NAME := lineage_$DEVICE|PRODUCT_NAME := $PRODUCT|" \
        "$DEVICE_PATH/lineage_$DEVICE.mk"
    cat << 'TAIL'

# ----------------------------------------------------------------------------
# EPPE (Enforce Product Packages Exist) — выключен осознанно.
#
# vendor/custom/config/common.mk по умолчанию требует, чтобы КАЖДЫЙ пакет из
# PRODUCT_PACKAGES существовал как модуль. Дерево sm8150-common писалось под
# LineageOS и тянет пакеты, которых в PixelOS нет: lineage-sdk в форке PixelOS
# отключён жёстко (vendor/lineage/config/common.mk: TARGET_DISABLE_LINEAGE_SDK
# = true), поэтому org.lineageos.platform и его спутники не собираются вообще.
# С включённым EPPE сборка падает на product_config, не дойдя до компиляции.
# Отключаем проверку, а не вырезаем пакеты: вырезание развалит обновление
# деревьев из апстрима.
# ----------------------------------------------------------------------------
TARGET_DISABLE_EPPE := true
TAIL
} > "$DEVICE_PATH/$PRODUCT.mk"
echo "   P1: $DEVICE_PATH/$PRODUCT.mk сгенерирован"

grep -q "^PRODUCT_NAME := $PRODUCT$" "$DEVICE_PATH/$PRODUCT.mk" || {
    echo "!! P1: в lineage_$DEVICE.mk не нашлось 'PRODUCT_NAME := lineage_$DEVICE'."
    echo "   Дерево изменилось — проверь руками:"
    grep -n 'PRODUCT_NAME' "$DEVICE_PATH/lineage_$DEVICE.mk"
    exit 1
}
grep -q 'vendor/custom/config/common_full_phone.mk' "$DEVICE_PATH/$PRODUCT.mk" || {
    echo "!! P1: не подменился inherit на vendor/custom — продукт соберётся без PixelOS."
    exit 1
}

# ----------------------------------------------------------------------------
# P2) AndroidProducts.mk: зарегистрировать новый продукт и дать меню lunch.
# ----------------------------------------------------------------------------
cat > "$DEVICE_PATH/AndroidProducts.mk" << EOF
#
# Сгенерировано build-pixelos-cepheus.sh. НЕ ПРАВИТЬ РУКАМИ.
#
# SPDX-License-Identifier: Apache-2.0
#

PRODUCT_MAKEFILES := \\
    \$(LOCAL_DIR)/$PRODUCT.mk \\
    \$(LOCAL_DIR)/lineage_$DEVICE.mk

COMMON_LUNCH_CHOICES := \\
    $PRODUCT-$RELEASE-user \\
    $PRODUCT-$RELEASE-userdebug \\
    $PRODUCT-$RELEASE-eng
EOF
echo "   P2: AndroidProducts.mk обновлён"

# ----------------------------------------------------------------------------
# P3) Разбор Mi Pad 5 keyboard HAL из общего дерева, если его нет в hardware/xiaomi.
#
# В sm8150-common lineage-24.0 появился device/xiaomi/sm8150-common/accessories/
# (модуль vendor.lineage.accessories-service.xiaomi-sm8150, клавиатура для nabu).
# Его Android.bp опирается на
#   defaults: ["//hardware/xiaomi:vendor.lineage.accessories-service.xiaomi-defaults"]
# а этого модуля нет НИ в форке PixelOS (seventeen), НИ в LineageOS
# (lineage-24.0) — апстрим общего дерева опередил hardware/xiaomi. Soong парсит
# все Android.bp в дереве независимо от продукта, поэтому несуществующий
# defaults — это жёсткая ошибка анализа, хотя сам модуль собирается только при
# TARGET_IS_TABLET (у cepheus он false).
# То же с sepolicy: sepolicy/vendor/hal_lineage_accessories_default.te адресует
# домен hal_lineage_accessories_default, которого нет в device/lineage/sepolicy
# lineage-24.0 — компиляция policy упала бы на неизвестном типе.
#
# Проверяем наличие defaults и убираем accessories только если его правда нет:
# когда апстрим допушит модуль в hardware/xiaomi, правка сама перестанет
# применяться.
# ----------------------------------------------------------------------------
if grep -rqs 'vendor.lineage.accessories-service.xiaomi-defaults' \
        --include='*.bp' hardware/xiaomi; then
    echo "   P3: hardware/xiaomi уже содержит accessories-defaults — ничего не трогаю"
else
    if [ -d "$COMMON_PATH/accessories" ]; then
        echo "   P3: убираю accessories (Mi Pad 5 keyboard) — defaults в hardware/xiaomi нет"
        rm -rf "$COMMON_PATH/accessories"
    fi
    rm -f "$COMMON_PATH/sepolicy/vendor/hal_lineage_accessories_default.te"
    sed -i '/accessories/d' "$COMMON_PATH/sepolicy/vendor/file_contexts"
    # И сам пакет из msmnile.mk. Удаляем ВЕСЬ блок, а не одну строку с именем
    # пакета: он оформлен как
    #     # Accessories
    #     ifeq ($(TARGET_IS_TABLET),true)
    #     PRODUCT_PACKAGES += \
    #         vendor.lineage.accessories-service.xiaomi-sm8150
    #     endif
    # и если выкинуть только имя, останется "PRODUCT_PACKAGES += \" прямо перед
    # endif — продолжение строки съест endif, ifeq останется незакрытым и make
    # упадёт на "unterminated conditional" далеко от места правки.
    if grep -q '^# Accessories$' "$COMMON_PATH/msmnile.mk"; then
        sed -i '/^# Accessories$/,/^endif$/d' "$COMMON_PATH/msmnile.mk"
    fi
fi

# ----------------------------------------------------------------------------
# P4) first_api_level.
#
# cepheus вышел на Android 9 и честно объявляет PRODUCT_SHIPPING_API_LEVEL := 28.
# PixelOS держит для таких устройств свой переключатель: vendor/custom/config/common.mk
# пробрасывает SPOOF_FIRST_API_LEVEL_32 в soong-переменную
# lineageGlobalVars_spoof_first_api_level_32, а vendor/custom/build/soong/Android.bp
# превращает её в -DSPOOF_FIRST_API_LEVEL_32 для нативных потребителей.
# Нужно это ради Play Integrity / проверок Google-приложений, которые на
# first_api_level=28 режут функциональность.
#
# Это переменная окружения, не BoardConfig. SPOOF_API32=0 — выключить.
# ----------------------------------------------------------------------------
if [ "${SPOOF_API32:-1}" = "1" ]; then
    export SPOOF_FIRST_API_LEVEL_32=true
    echo "   P4: SPOOF_FIRST_API_LEVEL_32=true (SPOOF_API32=0 чтобы отключить)"
else
    echo "   P4: подмена first_api_level отключена"
fi

# ----------------------------------------------------------------------------
# P5) Боковая кнопка «AI» -> вызов ассистента (Gemini).
#
# На Mi 9 сбоку есть отдельная аппаратная клавиша. В ядре она объявлена в
#   kernel/xiaomi/sm8150/.../xiaomi/overlay/cepheus/cepheus-sm8150.dtsi
#     gpio_keys { ai_key { label = "ai_key"; linux,code = <KEY_AI>; ... } }
# где KEY_AI = 0x2b1 = 689 (include/uapi/linux/input-event-codes.h:647).
#
# Почему сейчас не работает: имя input-устройства берётся из label узла
# gpio_keys, то есть "gpio-keys", и Android ищет /vendor/usr/keylayout/gpio-keys.kl.
# Такого файла в дереве нет, поэтому применяется frameworks/base Generic.kl,
# а в нём код 689 не описан вообще — нажатие просто уходит в никуда.
#
# ВАЖНО: в этом же узле gpio_keys живёт громкость вверх (KEY_VOLUMEUP = 115).
# Свой gpio-keys.kl ПОЛНОСТЬЮ заменяет Generic.kl для устройства, поэтому 115
# обязан быть в файле — иначе кнопка громкости перестанет работать.
#
# Почему именно ASSIST, а не VOICE_ASSIST: PhoneWindowManager.java:5050
# на нажатие KEYCODE_ASSIST шлёт MSG_LAUNCH_ASSIST -> launchAssistAction(),
# а тот идёт через SearchManager к приложению с ролью ассистента. При
# установленном GMS это Gemini. VOICE_ASSIST (строка 5063) срабатывает на
# отпускание и ведёт в голосовой путь — не то.
#
# Флаг WAKE: в DTS у клавиши стоит gpio-key,wakeup, так что ядро умеет будить
# ею устройство. WAKE заставляет и политику будить экран — поведение как в
# MIUI. Если будет срабатывать в кармане, убери слово WAKE из строки ниже.
# ----------------------------------------------------------------------------
mkdir -p "$DEVICE_PATH/keylayout"
cat > "$DEVICE_PATH/keylayout/gpio-keys.kl" << 'EOF'
# Сгенерировано build-pixelos-cepheus.sh. НЕ ПРАВИТЬ РУКАМИ.
#
# Узел gpio_keys у cepheus содержит ДВЕ клавиши, обе должны быть здесь:
# этот файл целиком заменяет Generic.kl для устройства "gpio-keys".

# качелька громкости вверх (KEY_VOLUMEUP)
key 115   VOLUME_UP

# боковая кнопка «AI» (KEY_AI = 0x2b1) -> ассистент по умолчанию, т.е. Gemini
key 689   ASSIST   WAKE
EOF

# Keylayout тачскрина — чинит двойной тап для пробуждения, см. комментарий
# внутри самого файла. Лежит в ~/cepheus-patches, чтобы переживать repo sync.
[ -f "${PATCH_SRC:-$HOME/cepheus-patches}/fts.kl" ] && \
    cp "${PATCH_SRC:-$HOME/cepheus-patches}/fts.kl" "$DEVICE_PATH/keylayout/fts.kl"

cat > "$DEVICE_PATH/keylayout/Android.bp" << 'EOF'
// Сгенерировано build-pixelos-cepheus.sh. НЕ ПРАВИТЬ РУКАМИ.
// SPDX-License-Identifier: Apache-2.0

prebuilt_usr_keylayout {
    name: "gpio-keys.kl",
    src: "gpio-keys.kl",
    vendor: true,
}

prebuilt_usr_keylayout {
    name: "fts.kl",
    src: "fts.kl",
    vendor: true,
}
EOF

# Подключаем пакет к продукту. Идемпотентно.
# Проверяем ИМЕННО fts.kl, а не gpio-keys.kl: когда-то блок уже был записан
# только с gpio-keys, и защита «если есть — пропустить» молча не дала добавить
# второй keylayout. Поэтому отдельно обрабатываем случай неполного блока.
if ! grep -q 'fts\.kl' "$DEVICE_PATH/device.mk"; then
    if grep -q 'gpio-keys\.kl' "$DEVICE_PATH/device.mk"; then
        sed -i 's|^    gpio-keys\.kl$|    gpio-keys.kl \\\n    fts.kl|' "$DEVICE_PATH/device.mk"
    else
cat >> "$DEVICE_PATH/device.mk" << 'EOF'

# Keylayout: боковая кнопка «AI» и двойной тап тачскрина (P5)
PRODUCT_PACKAGES += \
    gpio-keys.kl \
    fts.kl
EOF
    fi
fi
echo "   P5: боковая кнопка AI (код 689) -> ASSIST"

# ----------------------------------------------------------------------------
# P6) Зелёный оттенок экрана: вернуть управление цветовым режимом фреймворку.
#
# Симптом: экран «зеленит», и поменять ничего нельзя — ни в настройках, ни
# через adb (setprop падает с "Failed to set property").
#
# Причина. В device/xiaomi/sm8150-common/vendor.prop жёстко прописано
#     persist.sys.sf.color_mode=9      <- ui::ColorMode DISPLAY_P3
#     persist.sys.sf.native_mode=2
# SurfaceFlinger читает это на старте (SurfaceFlinger.cpp:1183) и НАМЕРТВО
# форсирует P3: по комментарию в SurfaceFlinger.h:1582 форс действует всегда,
# когда native_mode != 1. В LineageOS поверх этого работает LiveDisplay из
# lineage-sdk и даёт пользователю выбор, но в PixelOS sdk отключён жёстко
# (vendor/lineage/config/common.mk: TARGET_DISABLE_LINEAGE_SDK = true).
# Переключать стало нечему — панель осталась в P3 без компенсации, отсюда
# перенасыщенность и уход в зелень.
#
# Почему adb setprop не помогает: свойство размечено как
# surfaceflinger_color_prop (system/sepolicy/private/property_contexts:1582),
# и set_prop на него выдан только system_server и vendor_init. Shell не имеет
# права. Рут тоже не вариант: сборка хоть и userdebug, но PixelOS выставляет
# ro.debuggable=0 (vendor/lineage/config/common.mk:42), поэтому adb root
# не поднимется.
#
# Решение — штатный путь AOSP вместо LiveDisplay. ColorModePreferenceController
# в Settings показывает выбор «Цвета» ровно тогда, когда непуст массив
# config_availableColorModes, а он в AOSP пуст по умолчанию
# (frameworks/base/core/res/res/values/config.xml:1096). Заполняем его — и
# появляется живой переключатель в Настройки -> Экран -> Цвета. Дальше
# DisplayTransformManager.java:344 сам пишет persist.sys.sf.color_mode под
# выбранный режим, то есть свойством начинает владеть фреймворк.
#
# Значения проверены по исходникам:
#   ColorDisplayManager: NATURAL=0, BOOSTED=1, SATURATED=2
#   Display:             COLOR_MODE_SRGB=7, COLOR_MODE_DISPLAY_P3=9
# Сопоставление: естественный и насыщенный композитятся в sRGB, «яркий» —
# в P3. Так пользователь получает и нормальный цвет, и прежний вариант.
# ----------------------------------------------------------------------------
# 1) снимаем жёсткий форс из общего дерева
sed -i -E '/^persist\.sys\.sf\.(color_mode|color_saturation|native_mode)=/d' \
    "$COMMON_PATH/vendor.prop"

# ...но native_mode возвращаем со значением 1. Это НЕ форс:
#  * SurfaceFlinger.h:1586 — принудительный color_mode действует только при
#    native_mode != 1, то есть единица как раз ГАСИТ любой форс;
#  * ColorDisplayService.getCurrentColorModeFromSystemProperties (строка 1264)
#    берёт из этого пропа ДЕФОЛТНЫЙ режим, когда пользователь ещё ничего не
#    выбирал: 1 -> COLOR_MODE_SATURATED. Это родной режим панели без
#    цветоуправления — единственный, который на этом QDCM выглядит правильно
#    (проверено на устройстве: «на насыщенных цвет фиксится»). Остальные
#    режимы (managed sRGB) целят в D65 и воспринимаются жёлтыми — это
#    особенность калибровки, а не баг; они остаются доступными в меню.
grep -q '^persist\.sys\.sf\.native_mode=1$' "$COMMON_PATH/vendor.prop" || \
    echo 'persist.sys.sf.native_mode=1' >> "$COMMON_PATH/vendor.prop"

# 2) включаем штатный выбор режимов в оверлее устройства
CFG="$DEVICE_PATH/rro_overlays/FrameworkResOverlayDevice/res/values/config.xml"
if ! grep -q 'config_availableColorModes' "$CFG"; then
python3 - "$CFG" << 'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
block = '''
    <!-- Цветовые режимы: добавлено build-pixelos-cepheus.sh (P6).
         Непустой массив включает выбор в Настройки -> Экран -> Цвета. -->
    <integer-array name="config_availableColorModes">
        <item>0</item> <!-- NATURAL:   насыщенность 1.0, MANAGED -->
        <item>1</item> <!-- BOOSTED:   насыщенность 1.1, MANAGED -->
        <item>2</item> <!-- SATURATED: насыщенность 1.0, UNMANAGED (родной режим панели) -->
        <item>3</item> <!-- AUTOMATIC: насыщенность 1.0, ENHANCED -->
    </integer-array>

    <!-- Цветовое пространство композиции НЕ навязываем: COLOR_MODE_DEFAULT (0)
         означает «система подбирает сама под содержимое». Попытка жёстко
         назначить sRGB ломала цвет на этой панели: HWC с QDCM-калибровкой
         корректно отрабатывает только родной режим, поэтому правильно
         выглядели лишь «Насыщенные» (UNMANAGED). Режимы и так различаются
         между собой матрицей насыщенности и managed/unmanaged/enhanced. -->
    <integer-array name="config_displayCompositionColorModes">
        <item>0</item>
        <item>1</item>
        <item>2</item>
        <item>3</item>
    </integer-array>

    <integer-array name="config_displayCompositionColorSpaces">
        <item>0</item>
        <item>0</item>
        <item>0</item>
        <item>0</item>
    </integer-array>
</resources>'''
idx = s.rindex('</resources>')
open(p, 'w', encoding='utf-8').write(s[:idx] + block.lstrip('\n') + s[idx+len('</resources>'):])
PY
fi
echo "   P6: выбор цветового режима включён, форс DISPLAY_P3 снят"

# ----------------------------------------------------------------------------
# P7) Настраиваемое действие боковой клавиши: ассистент / приложение / ничего.
#
# P5 жёстко назначил клавише ASSIST. Здесь добавляется выбор в настройках.
#
# Как это работает. В форке frameworks/base у PixelOS есть Lineage-механизм
# device-specific обработчиков клавиш:
#   * ресурсы config_deviceKeyHandlerLibs / config_deviceKeyHandlerClasses
#     объявлены в frameworks/base/core/res/res/values/custom_config.xml;
#   * PhoneWindowManager.java:2617 грузит по ним класс через PathClassLoader;
#   * вызов dispatchKeyToKeyHandlers стоит в interceptKeyBeforeQueueing на
#     строке 4740, то есть ДО switch(keyCode) с KEYCODE_ASSIST на строке 5050.
# Значит наш обработчик получает клавишу первым. Вернёт null — событие
# поглощено; вернёт сам event — уйдёт дальше по штатному пути.
#
# Отсюда конструкция из двух частей:
#   cepheus-keyhandler  — java_library в /system_ext/framework, живёт внутри
#                         system_server, читает выбор из Settings.System;
#   CepheusParts        — экран настроек, встраивается в «Настройки -> Система»
#                         через IA_SETTINGS (тот же приём, что у XiaomiParts).
#
# Режим «ассистент» реализован бездействием: обработчик возвращает событие как
# есть, и ассистента поднимает сам PhoneWindowManager по KEYCODE_ASSIST из
# нашего gpio-keys.kl. Так уважается выбранный по умолчанию ассистент, а при
# неудачной загрузке библиотеки поведение остаётся прежним, а не ломается.
#
# Исходники лежат ВНЕ дерева AOSP (~/cepheus-patches), потому что
# repo sync --force-sync затирает всё внутри device/. Здесь их копируем.
# ----------------------------------------------------------------------------
PATCH_SRC="${PATCH_SRC:-$HOME/cepheus-patches}"
if [ -d "$PATCH_SRC/keyhandler" ] && [ -d "$PATCH_SRC/parts" ]; then
    rm -rf "$DEVICE_PATH/keyhandler" "$DEVICE_PATH/parts"
    cp -r "$PATCH_SRC/keyhandler" "$DEVICE_PATH/keyhandler"
    cp -r "$PATCH_SRC/parts"      "$DEVICE_PATH/parts"

    # оверлей: указать системе, где лежит обработчик и как называется класс
    if ! grep -q 'config_deviceKeyHandlerLibs' "$CFG"; then
python3 - "$CFG" << 'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
block = '''
    <!-- Обработчик боковой клавиши: добавлено build-pixelos-cepheus.sh (P7).
         Загружается PhoneWindowManager через PathClassLoader. -->
    <string-array name="config_deviceKeyHandlerLibs" translatable="false">
        <item>/system_ext/framework/cepheus-keyhandler.jar</item>
    </string-array>

    <string-array name="config_deviceKeyHandlerClasses" translatable="false">
        <item>org.lineageos.settings.cepheus.keyhandler.KeyHandler</item>
    </string-array>
</resources>'''
idx = s.rindex('</resources>')
open(p, 'w', encoding='utf-8').write(s[:idx] + block.lstrip('\n') + s[idx+len('</resources>'):])
PY
    fi

    if ! grep -q 'CepheusParts' "$DEVICE_PATH/device.mk"; then
cat >> "$DEVICE_PATH/device.mk" << 'EOF'

# Боковая клавиша: обработчик + экран настроек (см. P7 в build-pixelos-cepheus.sh)
PRODUCT_PACKAGES += \
    cepheus-keyhandler \
    CepheusParts
EOF
    fi
    echo "   P7: настройка действия боковой клавиши (обработчик + экран)"
else
    echo "   P7: пропущено — нет $PATCH_SRC"
fi

# ----------------------------------------------------------------------------
# P8) 90 Гц.
#
# Панель cepheus (Samsung EA8076) в стоке объявляет ровно один режим — 60 Гц,
# timing@0 в
#   kernel/.../xiaomi/overlay/common/display/dsi-panel-samsung-fhd-ea8076-cmd.dtsi
# Добавляем ещё три: 72 / 81 / 90 Гц.
#
# Откуда данные. Режимы взяты из рабочего стороннего dtbo (разгон DarkWolf),
# то есть это проверенные вендорные значения, а не придуманные: тот же
# clockrate (линейно от 1,1 ГГц), те же порчи и, главное, та же
# qcom,mdss-dsi-timing-switch-command — набор регистров панели, который
# выдумать нельзя.
#
# ЧТО ИСПРАВЛЕНО ОТНОСИТЕЛЬНО ЧУЖОГО DTBO. Там во все четыре режима
# скопированы одни и те же qcom,mdss-dsi-panel-phy-timings, посчитанные для
# 1,1 ГГц, хотя 90 Гц гонит DSI PHY на 1,65 ГГц — отсюда сдвиг гаммы и
# «значительное повышение яркости», которым хвалится описание модуля.
# Мы эти тайминги вырезаем, и вот почему это правильно: в исходнике ядра у
# панели их нет вообще, а dsi_display.c:4607 применяет значения из DTS только
# при phy_timing_len != 0. Без них драйвер считает тайминги сам
# (dsi_phy_timing_calc.c) под реальный битклок каждого режима.
#
# Готовые блоки лежат в ~/cepheus-patches/panel-timings.dtsi.
# ----------------------------------------------------------------------------
# ВАЖНО: у Mi 9 ШЕСТЬ ревизий панели ea8076 (_cmd, _f1, _f1p2, _f1p2_2,
# _f1mp, _f1s), какая стоит в конкретном аппарате — определяется при загрузке.
# Патчить надо все: на первой сборке я тронул только базовую, и у тестового
# аппарата с ревизией f1* частота так и осталась 60 Гц.
# PANEL_90HZ=0 — собрать со стоковой панелью 60 Гц.
# Нужно, потому что разгон на тестовом аппарате оказался нерабочим: даже с
# вендорными PHY-таймингами из донорского dtbo список режимов обрывался на
# 72 Гц и они «лагали», а на расчётных таймингах ломались яркость и
# пробуждение экрана. До выяснения причины публикуемая сборка — 60 Гц.
PANEL_90HZ="${PANEL_90HZ:-1}"
PANEL_DIR="kernel/xiaomi/sm8150/arch/arm64/boot/dts/qcom/xiaomi/overlay/common/display"
if [ "$PANEL_90HZ" != "1" ]; then
    # вычищаем добавленные режимы, если дерево осталось пропатченным
    if grep -lq 'timing@1' "$PANEL_DIR"/dsi-panel-samsung-fhd-ea8076*.dtsi 2>/dev/null; then
        (cd kernel/xiaomi/sm8150 && git checkout -- \
            arch/arm64/boot/dts/qcom/xiaomi/overlay/common/display/)
    fi
    echo "   P8: пропущено (PANEL_90HZ=0) — панель остаётся 60 Гц"
else
patched=0; skipped=0
for src in "$PATCH_SRC"/panel/*.dtsi; do
    [ -f "$src" ] || continue
    name="$(basename "$src")"
    PANEL_DTSI="$PANEL_DIR/$name"
    [ -f "$PANEL_DTSI" ] || { echo "   P8: нет $name в ядре — пропуск"; continue; }
    if grep -q 'timing@1' "$PANEL_DTSI"; then
        skipped=$((skipped+1))
    else
        python3 - "$PANEL_DTSI" "$src" "$src.sw" << 'PY'
import re, sys
panel, timings, sw = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(panel, encoding='utf-8').read()
add = open(timings, encoding='utf-8').read().rstrip('\n')
swtxt = open(sw, encoding='utf-8').read().rstrip('\n')

# 1) timing@0 нужна команда переключения, иначе возврат на 60 Гц не сработает
if 'mdss-dsi-timing-switch-command' not in s:
    i = s.index('qcom,mdss-dsi-panel-jitter')
    j = s.index('\n', i) + 1
    s = s[:j] + swtxt + '\n' + s[j:]

# 2) сами режимы — перед закрытием блока display-timings
start = s.index('qcom,mdss-dsi-display-timings')
depth, k = 0, s.index('{', start)
pos = k
while True:
    if s[pos] == '{':
        depth += 1
    elif s[pos] == '}':
        depth -= 1
        if depth == 0:
            break
    pos += 1
s = s[:pos] + add + '\n\t\t' + s[pos:]
open(panel, 'w', encoding='utf-8').write(s)
PY
        patched=$((patched+1))
    fi
done
echo "   P8: панелей с режимами 72/81/90 — добавлено $patched, уже было $skipped"
fi  # PANEL_90HZ

# Фреймворк: разрешить переключение частоты и снять потолок на локскрине.
if ! grep -q 'config_defaultPeakRefreshRate' "$CFG"; then
python3 - "$CFG" << 'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
block = '''
    <!-- Частота обновления: добавлено build-pixelos-cepheus.sh (P8).
         Панель умеет 60/72/81/90, см. правку dsi-panel-samsung-fhd-ea8076-cmd.dtsi.
         Пик включается переключателем «Плавное изображение» в настройках экрана. -->
    <integer name="config_defaultRefreshRate">60</integer>
    <integer name="config_defaultPeakRefreshRate">90</integer>
</resources>'''
idx = s.rindex('</resources>')
open(p, 'w', encoding='utf-8').write(s[:idx] + block.lstrip('\n') + s[idx+len('</resources>'):])
PY
fi
# иначе локскрин насильно держит 60 Гц и переключение выглядит сломанным
sed -i -E 's|<integer name="config_keyguardMaxRefreshRate">60</integer>|<integer name="config_keyguardMaxRefreshRate">90</integer>|' \
    "$COMMON_PATH/rro_overlays/SystemUIOverlayCommon/res/values/config.xml"

# ----------------------------------------------------------------------------
# P9) Статусбар: часы заезжают в скруглённый угол.
#
# ДИАГНОЗ (вторая итерация, после проверки на устройстве). Правка
# status_bar_padding_start/end в SystemUI-оверлее видимого эффекта НЕ дала.
# Причина — не тот рычаг: в A17 горизонтальные границы контента статусбара
# задаёт StatusBarContentInsetsProvider.kt, и его формула (строки 338-345):
#     minLeft  = max(minDotPadding, roundedCornerPadding)
#     minRight = roundedCornerPadding
# то есть единственный ресурс, который реально двигает контент от углов, —
# rounded_corner_content_padding. SystemUI ссылается на ОДНОИМЁННЫЙ ресурс
# фреймворка (@*android:dimen/..., core/res/res/values/dimens.xml:143,
# по умолчанию 0dp) — поэтому править его надо во Framework-оверлее, который
# на устройстве доказанно применяется (цветовые режимы через него заработали).
#
# РАСЧЁТ значения. Панель 1080x2340, density 440 -> 2.75 px/dp.
# Радиус угла из дерева: rounded_corner_radius_top = 89px.
# Статусбар 28dp = 77px; верхняя кромка текста часов y ~= 18px.
# Горизонтальный заход стекла на этой высоте:
#     r - sqrt(r^2 - (r-y)^2) = 89 - sqrt(89^2 - 71^2) ~= 35px.
# Внутри макета остаётся штатный status_bar_padding_start = 4dp = 11px,
# итого нужно rcp >= (35-11)px ~= 9dp. Берём 12dp (33px): контент начинается
# с 33+11 = 44px от кромки — дуга очищена с запасом ~9px.
# Свои значения в SystemUIOverlayDevice больше не пишем (и вычищаем старые,
# если дерево осталось с прошлого прогона) — чтобы сдвиг не задвоился.
# ----------------------------------------------------------------------------
SUI="$DEVICE_PATH/rro_overlays/SystemUIOverlayDevice/res/values/dimens.xml"
if [ -f "$SUI" ] && grep -q 'status_bar_padding_start' "$SUI"; then
python3 - "$SUI" << 'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'\n\s*<!-- Отступы статусбара.*?status_bar_padding_end">[^<]*</dimen>', '', s, flags=re.S)
s = re.sub(r'\n\s*<dimen name="status_bar_padding_(start|end)">[^<]*</dimen>', '', s)
open(p, 'w', encoding='utf-8').write(s)
PY
    echo "   P9: лишние status_bar_padding из SystemUI-оверлея удалены"
fi
# Сам сдвиг — через Framework-оверлей (обоснование и расчёт в шапке P9).
if ! grep -q 'rounded_corner_content_padding' "$CFG"; then
python3 - "$CFG" << 'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
block = '''
    <!-- Отступ контента от скруглённого угла: добавлено (P9).
         Углы экрана 89px (~32dp), в AOSP этот отступ 0dp. -->
    <dimen name="rounded_corner_content_padding">12dp</dimen>
</resources>'''
idx = s.rindex('</resources>')
open(p, 'w', encoding='utf-8').write(s[:idx] + block.lstrip('\n') + s[idx+len('</resources>'):])
PY
fi
sed -i -E 's|(<dimen name="rounded_corner_content_padding">)[^<]*|\112dp|' "$CFG"
echo "   P9: rounded_corner_content_padding=12dp (расчёт от радиуса 89px)"

# ----------------------------------------------------------------------------
# P10) Оптимизация под Snapdragon 855.
#
# Только то, что реально работает на A17, без форумных пропов:
#  * PRODUCT_DEXPREOPT_SPEED_APPS — AOT-компиляция с фильтром speed на этапе
#    сборки (build/make/core/dex_preopt_config.mk:106 -> SpeedApps). SystemUI
#    и лаунчер — два процесса, которые рисуют каждый кадр интерфейса; по
#    умолчанию они speed-profile без собранного профиля, то есть заметная
#    часть кода крутится в интерпретаторе. На 6-летнем чипе это ощутимо.
#  * Фазовые офсеты SurfaceFlinger НЕ трогаем: значения в vendor.prop дерева
#    (early.app 16.5ms / late.app 20.5ms / late.sf 10.5ms) — это конфигурация
#    Pixel 4 (coral), то есть такого же sm8150 с 90-герцовым экраном. Они
#    уже рассчитаны под 90 Гц.
#  * Алгоритм блюра не трогаем: без переопределения SF берёт
#    KawaseDualFilterV2 — самый дешёвый (SurfaceFlinger.cpp:944).
# ----------------------------------------------------------------------------
if ! grep -q 'PRODUCT_DEXPREOPT_SPEED_APPS' "$DEVICE_PATH/device.mk"; then
cat >> "$DEVICE_PATH/device.mk" << 'EOF'

# AOT speed для процессов, рисующих UI (см. P10 в build-pixelos-cepheus.sh)
PRODUCT_DEXPREOPT_SPEED_APPS += \
    SystemUI \
    NexusLauncherRelease
EOF
fi
echo "   P10: dexpreopt speed для SystemUI и лаунчера"

echo "== Правки применены =="

if [ "$SYNC_ONLY" = "1" ]; then
    echo "== SYNC_ONLY=1: исходники и деревья готовы, сборку не запускаю =="
    exit 0
fi

# ------------------------------------------------------------------
# out/ от другого манифеста/ветки несовместим — сносим.
# ------------------------------------------------------------------
OUT_STAMP="$WORK_DIR/out/.pixelos_manifest"
STAMP_NOW="$MANIFEST_BRANCH/$PRODUCT-$RELEASE-$VARIANT"
if [ "$WIPE_OUT" = "1" ] || \
   { [ "$WIPE_OUT" = "auto" ] && [ -d "$WORK_DIR/out" ] && \
     [ "$(cat "$OUT_STAMP" 2>/dev/null)" != "$STAMP_NOW" ]; }; then
    echo "== out/ остался от другой сборки — удаляю =="
    rm -rf "$WORK_DIR/out"
fi
mkdir -p "$WORK_DIR/out"
echo "$STAMP_NOW" > "$OUT_STAMP"

if [ "$USE_CCACHE_BUILD" = "true" ] && command -v ccache >/dev/null; then
    export USE_CCACHE=1
    export CCACHE_EXEC=$(command -v ccache)
    ccache -M "$CCACHE_SIZE" >/dev/null
    echo "== ccache включён, лимит $CCACHE_SIZE =="
fi

export LC_ALL=C

# Держим тяжёлые по памяти шаги в узде: 31 ГБ RAM на 16 потоков — впритык
export NINJA_HIGHMEM_NUM_JOBS="$HIGHMEM_JOBS"

# ------------------------------------------------------------------
# Инкрементальный анализ Soong — выключен. Это НЕ лечит OOM (проверено:
# с false пик soong_build остался 25,4 ГБ и его снова убило), но убирает
# лишнюю gob-сериализацию провайдеров и экономию даёт бесплатно. Настоящее
# лечение памяти — дисковый swap, см. блок проверки RAM выше.
#
# Заодно это отключает поведение, специфичное для A17: в AOSP флаг
# RELEASE_SOONG_INCREMENTAL_ANALYSIS по умолчанию false
# (build/release/flag_declarations/), но релиз-конфиг cp2a — ровно тот, что
# нужен Android 17 — выставляет его в true:
#   build/release/flag_values/cp2a/RELEASE_SOONG_INCREMENTAL_ANALYSIS.textproto
# Отсюда и расхождение в логе: lunch печатает SOONG_INCREMENTAL_ANALYSIS=false
# (релиз ещё не применён), а сама сборка — уже true. На A16/bp4a этого значения
# в release config не было.
#
# Переменная окружения имеет приоритет над релиз-конфигом: ui/build/config.go
# на ветке IsFalse выставляет incrementalBuildActionsSetInEnv, и флаг из
# release config решение уже не перезаписывает.
#
# Крутить GOGC/GOMEMLIMIT бессмысленно: soong_build запускается через "env -i"
# с белым списком переменных, Go-ручки туда не доходят.
# ------------------------------------------------------------------
export SOONG_INCREMENTAL_ANALYSIS="${SOONG_INCREMENTAL_ANALYSIS:-false}"
echo "== SOONG_INCREMENTAL_ANALYSIS=$SOONG_INCREMENTAL_ANALYSIS (на cp2a он по умолчанию true и роняет анализ по OOM) =="

# ALLOW_MISSING_DEPENDENCIES здесь СОЗНАТЕЛЬНО не выставляем (в отличие от
# recovery-сборки AERA): для полной прошивки он превращает отсутствующие модули
# в молча выключенные и даёт на выходе образ без половины HAL'ов. Пусть падает.

set +e
source build/envsetup.sh

# lunch нельзя гнать через pipe (ушёл бы в subshell вместе с TARGET_PRODUCT),
# поэтому пишем в лог и печатаем его отдельно.
# Можно было бы "breakfast $DEVICE" — он ровно это и делает, подставляя
# cp2a из vendor/lineage/vars/aosp_target_release; зовём lunch напрямую,
# чтобы релиз-конфиг был виден в логе явно.
lunch "${PRODUCT}-${RELEASE}-${VARIANT}" > "$LOG_DIR/lunch.log" 2>&1
rc=$?
cat "$LOG_DIR/lunch.log"
if [ $rc -ne 0 ] || [ "$TARGET_PRODUCT" != "$PRODUCT" ]; then
    cat <<EOF

!! lunch ${PRODUCT}-${RELEASE}-${VARIANT} не прошёл (лог: $LOG_DIR/lunch.log).
   Что смотреть в первую очередь:
     * "Can not locate config makefile" -> P1/P2 не применились, проверь
       $DEVICE_PATH/$PRODUCT.mk и AndroidProducts.mk
     * "XXX is obsolete" -> переменная из A16-дерева в A17 больше не
       поддерживается; её надо осознанно заменить в $DEVICE_PATH или
       $COMMON_PATH, а не вырезать вслепую
     * "release config cp2a not found" -> сверь
       vendor/lineage/vars/aosp_target_release, апстрим мог сдвинуть релиз
EOF
    exit 1
fi

BUILD_LOG="$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log"
echo "== Сборка: m $TARGET -j$BUILD_THREADS =="
echo "   лог: $BUILD_LOG"
echo "   первая сборка с нуля на 16 потоках — ориентировочно 3-6 часов"
m "$TARGET" -j"$BUILD_THREADS" 2>&1 | tee "$BUILD_LOG"
rc=${PIPESTATUS[0]}

OUT_PRODUCT="$WORK_DIR/out/target/product/$DEVICE"
if [ $rc -eq 0 ]; then
    echo
    echo "== Готово =="
    ls -lh "$OUT_PRODUCT"/PixelOS_*.zip 2>/dev/null
    ls -lh "$OUT_PRODUCT"/*-ota-*.zip 2>/dev/null
    ls -lh "$OUT_PRODUCT"/boot.img "$OUT_PRODUCT"/dtbo.img \
           "$OUT_PRODUCT"/recovery.img "$OUT_PRODUCT"/super_empty.img 2>/dev/null
    cat <<EOF

   PixelOS_*.zip — OTA-пакет, ставится сайдлоадом из recovery:
       adb reboot sideload-auto-reboot
       adb sideload $OUT_PRODUCT/PixelOS_*.zip

   cepheus — A-only с retrofit dynamic partitions (super 6 ГБ на
   system/vendor/cust), слотов нет. Перед первой установкой нужен
   свежий recovery, умеющий это super, и вайп data (f2fs).
EOF
else
    echo
    echo "!! Сборка упала (код $rc). Первые ошибки:"
    grep -nE "error:|FAILED|ninja: build stopped|No private recovery resources" "$BUILD_LOG" | head -20
    echo "   полный лог: $BUILD_LOG"
    echo "   повторный прогон без синка:  NO_SYNC=1 bash $0"
fi
exit $rc
