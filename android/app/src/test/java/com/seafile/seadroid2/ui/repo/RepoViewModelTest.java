package com.seafile.seadroid2.ui.repo;

import android.app.Application;
import com.seafile.seadroid2.account.Account;
import com.seafile.seadroid2.context.NavContext;
import com.seafile.seadroid2.enums.RefreshStatusEnum;
import com.seafile.seadroid2.framework.model.BaseModel;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import androidx.arch.core.executor.testing.InstantTaskExecutorRule;
import org.junit.Test;
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
public class RepoViewModelTest {
    @Rule public final InstantTaskExecutorRule liveData = new InstantTaskExecutorRule();
    private final TestScheduler io = new TestScheduler();
    private FakeViewModel vm;

    private static class FakeViewModel extends RepoViewModel {
        Account account = new Account("https://example.org/seafile/", "one@example.org", "One", "", "test-token", false);
        SingleSubject<List<BaseModel>> response = SingleSubject.create();
        @Override protected Account currentListingAccount() { return account; }
        @Override protected boolean hasListingNetwork() { return true; }
        @Override protected Single<List<BaseModel>> remoteRepositories(Account ignored) { return response; }
    }

    @Before public void setup() {
        com.elvishew.xlog.XLog.init();
        RxJavaPlugins.setIoSchedulerHandler(ignored -> io);
        RxAndroidPlugins.setInitMainThreadSchedulerHandler(ignored -> Schedulers.trampoline());
        RxAndroidPlugins.setMainThreadSchedulerHandler(ignored -> Schedulers.trampoline());
        try {
            java.lang.reflect.Field context = com.seafile.seadroid2.SeadroidApplication.class.getDeclaredField("context");
            context.setAccessible(true);
            context.set(null, org.robolectric.RuntimeEnvironment.getApplication());
        } catch (ReflectiveOperationException error) {
            throw new AssertionError(error);
        }
        vm = new FakeViewModel();
    }

    @After public void cleanup() {
        vm.clearAll();
        RxJavaPlugins.reset();
        RxAndroidPlugins.reset();
    }

    private void refresh() {
        vm.loadData(new NavContext(), RefreshStatusEnum.ONLY_REMOTE, false);
        io.triggerActions();
    }

    @Test public void slowPreviousRefreshCannotReplaceNewResults() {
        SingleSubject<List<BaseModel>> old = vm.response;
        refresh();
        vm.response = SingleSubject.create();
        refresh();
        List<BaseModel> newest = List.of(new BaseModel());
        vm.response.onSuccess(newest);
        old.onSuccess(List.of());
        assertSame(newest, vm.getObjListLiveData().getValue());
        assertEquals(false, vm.getRefreshLiveData().getValue());
    }

    @Test public void previousAccountResponseCannotAppearAfterSwitch() {
        refresh();
        vm.account = new Account("https://other.example.org/prefix/", "two@example.org", "Two", "", "test-token", false);
        vm.response.onSuccess(List.of(new BaseModel()));
        assertNull(vm.getObjListLiveData().getValue());
    }

    @Test public void destroyedViewCancelsSubscriptionsAndErrors() {
        refresh();
        assertTrue(vm.response.hasObservers());
        vm.clearAll();
        assertFalse(vm.response.hasObservers());
        vm.response.onError(new IllegalStateException("late response"));
        assertNull(vm.getSeafExceptionLiveData().getValue());
        assertNull(vm.getObjListLiveData().getValue());
    }

    @Test public void failedRefreshKeepsPreviouslyVisibleFiles() {
        List<BaseModel> cached = List.of(new BaseModel());
        vm.getObjListLiveData().setValue(cached);
        refresh();
        vm.response.onError(new java.io.IOException("offline"));
        assertSame(cached, vm.getObjListLiveData().getValue());
        assertEquals(false, vm.getRefreshLiveData().getValue());
    }
}
