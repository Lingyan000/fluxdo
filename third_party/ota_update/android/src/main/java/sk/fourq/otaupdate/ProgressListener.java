package sk.fourq.otaupdate;

/**
 * Listener for progress updates
 */
public interface ProgressListener {
    void onDownloadProgress(long bytesRead, long contentLength, boolean done);
}
