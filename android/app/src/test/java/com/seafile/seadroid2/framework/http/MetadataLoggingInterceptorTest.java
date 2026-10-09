package com.seafile.seadroid2.framework.http;

import java.io.IOException;
import java.util.ArrayList;
import okhttp3.*;
import org.junit.Test;
import static org.junit.Assert.*;

public class MetadataLoggingInterceptorTest {
    private Request authenticatedRequest() {
        return new Request.Builder().url("https://example.org/files/signed-path-secret?token=query-secret")
            .header("Authorization", "Token header-secret").header("Cookie", "sessionid=cookie-secret")
            .header("X-Seafile-OTP", "otp-secret")
            .post(RequestBody.create("password=body-secret", MediaType.get("application/x-www-form-urlencoded"))).build();
    }
    @Test public void onlyMetadataIsLoggedWhileTheOriginalAuthenticatedRequestIsSent() throws Exception {
        Request request = authenticatedRequest();
        Response response = new Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").build();
        TestChain chain = new TestChain(request, response, null);
        ArrayList<String> logs = new ArrayList<>();
        assertSame(response, new MetadataLoggingInterceptor(logs::add).intercept(chain));
        assertEquals(1, chain.calls); assertEquals(1, logs.size()); assertEquals("HTTP POST example.org -> 200", logs.get(0));
        for (String secret : new String[] {"signed-path-secret", "query-secret", "header-secret", "cookie-secret", "otp-secret", "body-secret"}) { assertFalse(logs.toString().contains(secret)); }
        assertEquals("Token header-secret", request.header("Authorization"));
    }
    @Test public void failuresDoNotLogSignedURLsAndAreNotSwallowedOrRetried() throws Exception {
        Request request = authenticatedRequest(); IOException error = new IOException("Failure at " + request.url());
        TestChain chain = new TestChain(request, null, error);
        ArrayList<String> logs = new ArrayList<>();
        try { new MetadataLoggingInterceptor(logs::add).intercept(chain); fail("Expected the network failure"); }
        catch (IOException caught) { assertSame(error, caught); }
        assertEquals(1, chain.calls); assertEquals("HTTP POST example.org failed: IOException", logs.get(0));
        assertFalse(logs.toString().contains("secret"));
    }
    private static final class TestChain implements Interceptor.Chain {
        private final Request request;
        private final Response response;
        private final IOException failure;
        int calls;
        TestChain(Request request, Response response, IOException failure) { this.request = request; this.response = response; this.failure = failure; }
        public Request request() { return request; }
        public Response proceed(Request sent) throws IOException { assertSame(request, sent); calls++; if (failure != null) throw failure; return response; }
        public Connection connection() { return null; }
        public Call call() { return null; }
        public int connectTimeoutMillis() { return 1000; }
        public int readTimeoutMillis() { return 1000; }
        public int writeTimeoutMillis() { return 1000; }
        public Interceptor.Chain withConnectTimeout(int timeout, java.util.concurrent.TimeUnit unit) { return this; }
        public Interceptor.Chain withReadTimeout(int timeout, java.util.concurrent.TimeUnit unit) { return this; }
        public Interceptor.Chain withWriteTimeout(int timeout, java.util.concurrent.TimeUnit unit) { return this; }
    }
}
