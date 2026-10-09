package com.seafile.seadroid2.account;

import android.app.Application;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import static org.junit.Assert.*;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, application = Application.class)
public class AccountLoggingTest {
    @Test public void loggingDoesNotExposeOrChangeLoginCredentials() {
        Account account = new Account("https://example.org/seafile/?secret=url-sentinel", "person@example.org", "Person", "https://example.org/avatar?secret=avatar-sentinel", "token-sentinel", true);
        account.setSessionKey("cookie-sentinel");
        String message = account.toString();
        for (String sensitive : new String[] {account.server, account.email, account.token, account.sessionKey, "url-sentinel", "avatar-sentinel"}) {
            assertFalse(message.contains(sensitive));
        }
        assertTrue(message.contains("authenticated=true"));
        assertTrue(message.contains("hasWebSession=true"));
        assertEquals("token-sentinel", account.getToken());
        assertEquals("cookie-sentinel", account.getSessionKey());
    }

    @Test public void sortingStaysDeterministicAcrossCredentialChanges() {
        Account first = new Account("https://a.example.org/", "one@example.org", "One", "", "z-token", false);
        Account second = new Account("https://b.example.org/", "two@example.org", "Two", "", "a-token", false);
        assertTrue(first.compareTo(second) < 0);
        first.setToken(null);
        first.setSessionKey("new-cookie");
        assertTrue(first.compareTo(second) < 0);
        assertTrue(second.compareTo(first) > 0);
        assertEquals(0, first.compareTo(first));
        assertTrue(new Account().toString().contains("authenticated=false"));
        assertTrue(new Account().compareTo(first) < 0);
    }
}
