package com.seafile.seadroid2.framework.util;

import android.app.Application;

import com.seafile.seadroid2.framework.db.entities.FileCacheStatusEntity;
import com.seafile.seadroid2.framework.worker.queue.TransferModel;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Locale;

import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, application = Application.class)
public class CachedFileFingerprintTest {
    @Rule public TemporaryFolder temporary = new TemporaryFolder();

    private TransferModel transfer(File file) {
        TransferModel value = new TransferModel();
        value.related_account = "test-account";
        value.repo_id = "test-library";
        value.file_name = "notes.txt";
        value.full_path = "/notes.txt";
        value.target_path = file.getAbsolutePath();
        return value;
    }

    @Test public void deletedDownloadedFileKeepsItsMetadataWithoutThrowing() throws Exception {
        File file = temporary.newFile();
        assertTrue(file.delete());
        FileCacheStatusEntity record = FileCacheStatusEntity.convertFromDownload(transfer(file));
        assertEquals("/notes.txt", record.full_path);
        assertEquals(file.getAbsolutePath(), record.target_path);
        assertEquals("test-account", record.related_account);
        assertNull(record.file_md5);
        assertFalse(CachedFileFingerprint.hasChanged(record.file_md5, "new-content"));
    }

    @Test public void unavailableUploadedFileKeepsItsRemoteIdentityWithoutThrowing() throws Exception {
        File file = temporary.newFile();
        assertTrue(file.delete());
        TransferModel value = transfer(file);
        value.full_path = file.getAbsolutePath();
        value.target_path = "/notes.txt";
        FileCacheStatusEntity record = FileCacheStatusEntity.convertFromUpload(value, "uploaded-id");
        assertEquals("uploaded-id", record.file_id);
        assertEquals("/notes.txt", record.full_path);
        assertNull(record.file_md5);
    }

    @Test public void realEmptyFileHasAKnownFingerprint() throws Exception {
        File file = temporary.newFile();
        FileCacheStatusEntity record = FileCacheStatusEntity.convertFromDownload(transfer(file));
        assertEquals("d41d8cd98f00b204e9800998ecf8427e", record.file_md5);
        assertFalse(CachedFileFingerprint.hasChanged(record.file_md5, CachedFileFingerprint.read(file)));
    }

    @Test public void realEditIsDetectedWithoutTreatingCaseAsAnEdit() throws Exception {
        File file = temporary.newFile();
        Files.write(file.toPath(), "before".getBytes(StandardCharsets.UTF_8));
        String before = CachedFileFingerprint.read(file);
        assertNotNull(before);
        assertFalse(CachedFileFingerprint.hasChanged(before.toUpperCase(Locale.ROOT), before));
        Files.write(file.toPath(), "after".getBytes(StandardCharsets.UTF_8));
        assertTrue(CachedFileFingerprint.hasChanged(before, CachedFileFingerprint.read(file)));
    }

    @Test public void directoryAndMissingFingerprintsNeverTriggerAnAutomaticReplacement() throws Exception {
        assertNull(CachedFileFingerprint.read(temporary.newFolder()));
        assertNull(CachedFileFingerprint.read(null));
        assertFalse(CachedFileFingerprint.hasChanged("old", null));
        assertFalse(CachedFileFingerprint.hasChanged("", "new"));
        assertFalse(CachedFileFingerprint.hasChanged(null, "new"));
    }
}
