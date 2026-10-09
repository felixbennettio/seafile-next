package com.seafile.seadroid2.framework.util;

import androidx.annotation.Nullable;

import com.blankj.utilcode.util.FileUtils;

import java.io.File;
import java.util.Locale;

/** File checksums used to detect edits, never an authorization or integrity primitive. */
public final class CachedFileFingerprint {
    private CachedFileFingerprint() {}

    @Nullable
    public static String read(File file) {
        if (file == null || !file.isFile() || !file.canRead()) {
            return null;
        }
        long size = file.length();
        long modified = file.lastModified();
        // The utility returns null for an IO failure, including a file removed after isFile().
        String digest = FileUtils.getFileMD5ToString(file);
        if (digest == null || !file.isFile()
                || size != file.length() || modified != file.lastModified()) {
            return null;
        }
        return digest.toLowerCase(Locale.ROOT);
    }

    public static boolean hasChanged(String baseline, String current) {
        // An unknown baseline must not authorize replacing the server's file automatically.
        return baseline != null && !baseline.isEmpty() && current != null
                && !baseline.equalsIgnoreCase(current);
    }
}
