package sk.fourq.otaupdate;

import android.text.TextUtils;
import org.apache.commons.codec.binary.Hex;
import org.apache.commons.codec.digest.DigestUtils;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;

/**
 * Util class for validat sha-256 checksum of upgrade file downloaded via
 * ota update
 */
public class Sha256ChecksumValidator {

    private static final String UTF_8 = "UTF-8";
    private static final String SHA_256 = "SHA-256";
    private static final int BUFFER_LENGTH = 8192;

    /**
     * Generate checksum of provided file and compare with checksum provided in parameter
     *
     * @param checksum expected SHA 256 checksum
     * @param file     File to compare
     * @return If calculated checksum matches checksum in parameter true, otherwise false
     */
    public static boolean validateChecksum(String checksum, File file) {
        if (TextUtils.isEmpty(checksum) || file == null) {
            throw new IllegalArgumentException("checksum or file cannot be empty");
        }
        InputStream is = null;
        try {
            is = new FileInputStream(file);
            String calculatedChecksum = new String(Hex.encodeHex(DigestUtils.sha256(is)));
            return calculatedChecksum.equalsIgnoreCase(checksum);
        } catch (FileNotFoundException e) {
            throw new IllegalStateException("File not found", e);
        } catch (IOException e) {
            throw new IllegalStateException("Unknown IO error", e);
        } finally {
            if (is != null) {
                try {
                    is.close();
                } catch (IOException e) {
                    //noinspection ThrowFromFinallyBlock
                    throw new IllegalStateException("Cannot close IO stream", e);
                }
            }
        }
    }
}