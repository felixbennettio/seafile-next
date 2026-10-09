package com.seafile.seadroid2.ui.star;

import android.app.Application;
import androidx.arch.core.executor.testing.InstantTaskExecutorRule;
import com.seafile.seadroid2.account.Account;
import com.seafile.seadroid2.framework.db.entities.StarredModel;
import org.junit.*;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import java.util.List;
import io.reactivex.Single;
import io.reactivex.android.plugins.RxAndroidPlugins;
import io.reactivex.plugins.RxJavaPlugins;
import io.reactivex.schedulers.TestScheduler;
import io.reactivex.schedulers.Schedulers;
import io.reactivex.subjects.SingleSubject;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, application = Application.class)
public class StarredViewModelTest {
    @Rule public final InstantTaskExecutorRule liveData = new InstantTaskExecutorRule();
    private final TestScheduler io = new TestScheduler();
    private final Account account = new Account("https://example.org/seafile/", "one@example.org", "One", "", "test-token", false);
    private FakeViewModel vm;
    private static class FakeViewModel extends StarredViewModel {
        SingleSubject<List<StarredModel>> response = SingleSubject.create();
        @Override protected Single<List<StarredModel>> remoteStarredItems(Account account) { return response; }
    }
    @Before public void setup() throws Exception {
        com.elvishew.xlog.XLog.init();
        RxJavaPlugins.setIoSchedulerHandler(ignored -> io);
        RxAndroidPlugins.setInitMainThreadSchedulerHandler(ignored -> Schedulers.trampoline());
        RxAndroidPlugins.setMainThreadSchedulerHandler(ignored -> Schedulers.trampoline());
        java.lang.reflect.Field context = com.seafile.seadroid2.SeadroidApplication.class.getDeclaredField("context");
        context.setAccessible(true); context.set(null, org.robolectric.RuntimeEnvironment.getApplication());
        vm = new FakeViewModel();
    }
    @After public void cleanup() { vm.clearAll(); RxJavaPlugins.reset(); RxAndroidPlugins.reset(); }
    private void refresh(Account selected) { vm.loadData(selected); io.triggerActions(); }

    @Test public void slowPreviousRefreshCannotReplaceNewFavorites() {
        SingleSubject<List<StarredModel>> old = vm.response;
        refresh(account); vm.response = SingleSubject.create(); refresh(account);
        assertFalse(old.hasObservers());
        List<StarredModel> latest = List.of(new StarredModel());
        vm.response.onSuccess(latest); old.onSuccess(List.of());
        assertSame(latest, vm.getListLiveData().getValue());
        assertEquals(false, vm.getRefreshLiveData().getValue());
    }
    @Test public void oldAccountErrorCannotStopTheNewAccountRefresh() {
        SingleSubject<List<StarredModel>> old = vm.response;
        refresh(account); vm.response = SingleSubject.create();
        refresh(new Account("https://other.example.org/prefix/", "two@example.org", "Two", "", "test-token", false));
        old.onError(new java.io.IOException("old account offline"));
        assertEquals(true, vm.getRefreshLiveData().getValue());
        assertNull(vm.getSeafExceptionLiveData().getValue());
        List<StarredModel> latest = List.of(new StarredModel()); vm.response.onSuccess(latest);
        assertSame(latest, vm.getListLiveData().getValue());
    }
    @Test public void failedRefreshKeepsExistingFavorites() {
        List<StarredModel> cached = List.of(new StarredModel()); vm.getListLiveData().setValue(cached);
        refresh(account); vm.response.onError(new java.io.IOException("offline"));
        assertSame(cached, vm.getListLiveData().getValue()); assertEquals(false, vm.getRefreshLiveData().getValue());
    }
    @Test public void destroyedViewDoesNotDeliverALateListOrError() {
        refresh(account); assertTrue(vm.response.hasObservers()); vm.clearAll();
        assertFalse(vm.response.hasObservers()); vm.response.onError(new java.io.IOException("late response"));
        assertNull(vm.getListLiveData().getValue()); assertNull(vm.getSeafExceptionLiveData().getValue());
    }
}
