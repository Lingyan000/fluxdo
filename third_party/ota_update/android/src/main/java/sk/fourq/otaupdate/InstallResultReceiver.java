package sk.fourq.otaupdate;

import android.app.Activity;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.os.Build;
import android.util.Log;
import androidx.core.app.NotificationCompat;

public class InstallResultReceiver extends BroadcastReceiver {
    public static final String ACTION_INSTALL_COMPLETE = "ACTION_INSTALL_COMPLETE";
    public static final String EXTRA_SESSION_ID = "ota_session_id";
    public static final String EXTRA_NOTIFICATION_TEXT = "ota_confirmation_text";
    private static final String CHANNEL = "ota_install_confirmation";
    private static Intent pendingConfirmation;
    private static int pendingSessionId = -1;

    @Override
    public void onReceive(Context context, Intent intent) {
        int sessionId = intent.getIntExtra(EXTRA_SESSION_ID, -1);
        if (sessionId == -1) return;
        OtaUpdatePlugin plugin = OtaUpdatePlugin.getInstance();
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirmation = getConfirmationIntent(intent);
            if (confirmation != null) {
                pendingConfirmation = confirmation;
                pendingSessionId = sessionId;
                try {
                    if (plugin != null && plugin.showInstallConfirmation(confirmation)) {
                        clearPendingConfirmation(context, sessionId);
                        return;
                    }
                } catch (RuntimeException e) {
                    Log.w(OtaUpdatePlugin.TAG, "打开安装确认界面失败，改为通知入口", e);
                }
                showConfirmationNotification(context, confirmation, sessionId,
                        intent.getStringExtra(EXTRA_NOTIFICATION_TEXT));
                return;
            }
        }
        clearPendingConfirmation(context, sessionId);
        if (plugin == null || !plugin.ownsInstallSession(sessionId)) return;
        if (status == PackageInstaller.STATUS_SUCCESS) {
            plugin.onInstallSuccess(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE));
        } else {
            String message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE);
            plugin.onInstallFailure(message != null ? message : "系统未能完成安装，状态码：" + status);
        }
    }

    /** 通知被禁用时，回到应用也能继续完成系统要求的确认。 */
    public static void resumePendingConfirmation(Activity activity) {
        if (pendingConfirmation == null) return;
        try {
            activity.startActivity(pendingConfirmation);
            clearPendingConfirmation(activity, pendingSessionId);
        } catch (RuntimeException e) {
            Log.w(OtaUpdatePlugin.TAG, "恢复安装确认界面失败", e);
        }
    }

    private static void clearPendingConfirmation(Context context, int sessionId) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        manager.cancel(CHANNEL, sessionId);
        if (pendingSessionId == sessionId) {
            pendingConfirmation = null;
            pendingSessionId = -1;
        }
    }

    private static void showConfirmationNotification(Context context, Intent confirmation,
                                                    int sessionId, String text) {
        NotificationManager manager = context.getSystemService(NotificationManager.class);
        CharSequence appName = context.getApplicationInfo().loadLabel(context.getPackageManager());
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(new NotificationChannel(
                    CHANNEL, appName, NotificationManager.IMPORTANCE_HIGH));
        }
        PendingIntent action = PendingIntent.getActivity(context, sessionId,
                new Intent(confirmation).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        try {
            manager.notify(CHANNEL, sessionId, new NotificationCompat.Builder(context, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle(appName)
                    .setContentText(text != null ? text : appName)
                    .setContentIntent(action)
                    .setAutoCancel(true)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    .build());
        } catch (SecurityException e) {
            // 不为更新额外索取通知权限；保留待确认状态，回到应用时继续。
            Log.w(OtaUpdatePlugin.TAG, "通知权限不可用，等待回到应用确认安装", e);
        }
    }

    @SuppressWarnings("deprecation")
    private static Intent getConfirmationIntent(Intent intent) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            return intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent.class);
        }
        return intent.getParcelableExtra(Intent.EXTRA_INTENT);
    }
}
