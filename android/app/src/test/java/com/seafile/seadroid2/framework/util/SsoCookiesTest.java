package com.seafile.seadroid2.framework.util;

import org.junit.Test;
import static org.junit.Assert.*;

public class SsoCookiesTest {
    private final String token = "0123456789abcdef0123456789abcdef01234567";

    @Test public void originalQuotedCookiePreservesTheCompleteUsernameAndToken() {
        String value = SsoCookies.find("session=unused; seahub_auth=\"first@fixture.invalid@" + token + "\"; other=unused", "seahub_auth");
        SsoCookies.Identity identity = SsoCookies.identity(value);
        assertNotNull(identity);
        assertEquals("first@fixture.invalid", identity.username);
        assertEquals(token, identity.token);
    }

    @Test public void similarNamesAndValuesCannotImpersonateTheRequestedCookie() {
        assertNull(SsoCookies.find("fake_seahub_auth=wrong; unrelated=seahub_auth", "seahub_auth"));
        assertEquals("", SsoCookies.find("seahub_auth=", "seahub_auth"));
        assertEquals("value=with=separators", SsoCookies.find("seahub_auth=value=with=separators", "seahub_auth"));
    }

    @Test public void logoutAndMalformedCookiesNeverThrowOrProduceAnAccount() {
        for (String value : new String[] {null, "", "\"\"", "missing separator", "@" + token, "first@", "\"first@" + token, "first@" + token + "\"", "first@invalid"}) {
            assertNull(SsoCookies.identity(value));
        }
        assertNull(SsoCookies.find(null, "seahub_auth"));
    }

    @Test public void controlCharactersAndOversizedUsernamesAreRejected() {
        assertNull(SsoCookies.identity("first\n@fixture.invalid@" + token));
        assertNull(SsoCookies.identity("x".repeat(255) + "@" + token));
        assertNotNull(SsoCookies.identity("x".repeat(254) + "@" + token));
    }
}
