package com.fko.vib;

import android.os.Build;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XC_MethodHook;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.XposedHelpers;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

/**
 * FKO-Vib: 让 ColorOS 在振动模式下保留「通知铃声 → 振动」的联动。
 *
 * 原理（单点 Hook）：
 *   OplusSoundVibrateManager.hasVibrationRingMuteFeature() 在 ColorOS 上由
 *   系统 feature "oplus.software.vibration_ringtone" 决定。部分机型（如 13T）
 *   没有该 feature，导致 isVibrationRingMuteSupport() 为 false，振动模式下
 *   NMS 直接走 AOSP fallback 振动。
 *
 *   本模块只把该方法强制返回 true，使系统走它自己的
 *   "振动模式下仍播放铃声、但音频被静音、haptic 通道保留" 的原生路径。
 *   不伪造波形、不替换振动效果、不修改音频路由。
 *
 * 安全：
 *   - 仅注入 system_server（包名 android），不注入任何普通应用。
 *   - 只读/单点修改一个布尔判定，失败时自动回退原生行为。
 *   - 所有 Hook 注册和回调体均捕获 Throwable，不会让 system_server 崩溃。
 *   - 禁用模块后行为完全恢复原生。
 */
public class Hook implements IXposedHookLoadPackage {
    private static final String TAG = "FKOVib";

    /** 系统框架包（system_server）。 */
    private static final String TARGET_PACKAGE = "android";
    /** OPlus 声音/振动管理器。 */
    private static final String TARGET_CLASS =
            "com.android.server.notification.OplusSoundVibrateManager";
    /** 唯一 Hook 的方法：无参数，返回 boolean。 */
    private static final String TARGET_METHOD = "hasVibrationRingMuteFeature";

    @Override
    public void handleLoadPackage(LoadPackageParam lpparam) {
        if (!TARGET_PACKAGE.equals(lpparam.packageName)) {
            return;
        }
        if (Build.VERSION.SDK_INT < 35) {
            log("skip: sdk " + Build.VERSION.SDK_INT + " < 35");
            return;
        }
        try {
            install(lpparam);
        } catch (Throwable t) {
            // 任何失败都不影响系统，保持原生行为。
            log("install failed, native behavior kept: " + t);
        }
    }

    private void install(LoadPackageParam lpparam) {
        final Class<?> target = XposedHelpers.findClass(TARGET_CLASS, lpparam.classLoader);
        if (target == null) {
            log("class not found: " + TARGET_CLASS);
            return;
        }

        XposedHelpers.findAndHookMethod(target, TARGET_METHOD, new XC_MethodHook() {
            @Override
            protected void afterHookedMethod(MethodHookParam param) {
                try {
                    // 只在原值为 false 时改写；true 时保持原样，减少无谓改动。
                    if (Boolean.FALSE.equals(param.getResult())) {
                        param.setResult(Boolean.TRUE);
                    }
                } catch (Throwable t) {
                    log("hook body error: " + t);
                }
            }
        });

        log("installed: " + TARGET_CLASS + "." + TARGET_METHOD + " -> true");
    }

    private static void log(String message) {
        XposedBridge.log("[" + TAG + "] " + message);
    }
}
