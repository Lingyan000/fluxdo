package sk.fourq.otaupdate;

import android.content.pm.PackageInstaller;
import android.util.Log;

public class InstallSessionCallback extends PackageInstaller.SessionCallback {

    @Override
    public void onActiveChanged(int sessionId, boolean active) {

    }

    @Override
    public void onBadgingChanged(int sessionId) {

    }

    @Override
    public void onCreated(int sessionId) {

    }

    @Override
    public void onFinished(int sessionId, boolean success) {
        Log.d(OtaUpdatePlugin.TAG, "Install session finished " + success);
        // DOES NOT PROPAGATE TO PLUGIN AS IT SHOULD BE HANDLED BY InstallResultReceiver
    }

    @Override
    public void onProgressChanged(int sessionId, float progress) {
        Log.d(OtaUpdatePlugin.TAG, "Install session callback progress " + progress);
        OtaUpdatePlugin otaUpdatePlugin = OtaUpdatePlugin.getInstance();
        if(otaUpdatePlugin != null){
            otaUpdatePlugin.onInstallProgress(sessionId, progress);
        }
    }
}
