package com.seafile.seadroid2.framework.util;

import android.app.Application;
import androidx.room.Room;
import com.seafile.seadroid2.account.Account;
import com.seafile.seadroid2.framework.db.AppDatabase;
import com.seafile.seadroid2.framework.db.dao.StarredDirentDAO;
import com.seafile.seadroid2.framework.db.entities.StarredModel;
import com.seafile.seadroid2.framework.model.star.StarredWrapperModel;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import java.util.List;
import io.reactivex.Single;
import io.reactivex.subjects.SingleSubject;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, application = Application.class)
public class StarredCacheTest {
    private AppDatabase db;
    private StarredDirentDAO cache;
    private final Account account = new Account("https://example.org/seafile/", "one@example.org", "One", "", "test-token", false);
    @Before public void setup() {
        db = Room.inMemoryDatabaseBuilder(RuntimeEnvironment.getApplication(), AppDatabase.class).allowMainThreadQueries().build();
        cache = db.starredDirentDAO();
        cache.insertAllSync(List.of(item(account.getSignature(), "old.txt"), item("other-account", "other.txt")));
    }
    @After public void cleanup() { db.close(); }
    private static StarredModel item(String owner, String name) { StarredModel value = new StarredModel(); value.related_account = owner; value.obj_name = name; value.path = "/" + name; return value; }
    private static StarredWrapperModel reply(List<StarredModel> items) { StarredWrapperModel value = new StarredWrapperModel(); value.starred_item_list = items; return value; }
    private void assertOriginalCache() {
        assertEquals("old.txt", cache.getListByAccountSync(account.getSignature()).get(0).obj_name);
        assertEquals("other.txt", cache.getListByAccountSync("other-account").get(0).obj_name);
    }
    @Test public void pendingAndFailedRequestPreserveTheOfflineCache() {
        SingleSubject<StarredWrapperModel> remote = SingleSubject.create();
        var observer = Objs.cacheStarredItems(account, remote, cache).test(); assertOriginalCache();
        remote.onError(new java.io.IOException("offline")); observer.assertError(java.io.IOException.class); assertOriginalCache();
    }
    @Test public void validEmptyReplyClearsOnlyThatAccount() {
        Objs.cacheStarredItems(account, Single.just(reply(List.of())), cache).test().assertComplete();
        assertTrue(cache.getListByAccountSync(account.getSignature()).isEmpty());
        assertEquals("other.txt", cache.getListByAccountSync("other-account").get(0).obj_name);
    }
    @Test public void malformedReplyPreservesTheOfflineCache() {
        Objs.cacheStarredItems(account, Single.just(reply(null)), cache).test().assertError(java.io.IOException.class);
        assertOriginalCache();
    }
    @Test public void failedInsertRollsBackTheDeletedFavorites() {
        db.getOpenHelper().getWritableDatabase().execSQL("CREATE TRIGGER reject_test_insert BEFORE INSERT ON starred_dirents BEGIN SELECT RAISE(ABORT, 'simulated failed insert'); END");
        Objs.cacheStarredItems(account, Single.just(reply(List.of(item("", "new.txt")))), cache).test().assertError(error -> true);
        assertOriginalCache();
    }
    @Test public void successfulReplyReplacesOnlyThatAccount() {
        Objs.cacheStarredItems(account, Single.just(reply(List.of(item("", "new.txt")))), cache).test().assertComplete();
        assertEquals("new.txt", cache.getListByAccountSync(account.getSignature()).get(0).obj_name);
        assertEquals("other.txt", cache.getListByAccountSync("other-account").get(0).obj_name);
    }
}
