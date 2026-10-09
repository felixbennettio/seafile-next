package com.seafile.seadroid2.framework.http;

import java.io.IOException;
import java.util.function.Consumer;
import okhttp3.Interceptor;
import okhttp3.Request;
import okhttp3.Response;

/** Request headers, paths, query values and bodies can all carry credentials. */
final class MetadataLoggingInterceptor implements Interceptor {
    private final Consumer<String> logger;
    MetadataLoggingInterceptor(Consumer<String> logger) { this.logger = logger; }
    @Override public Response intercept(Chain chain) throws IOException {
        Request request = chain.request();
        String description = "HTTP " + request.method() + " " + request.url().host();
        try {
            Response response = chain.proceed(request);
            logger.accept(description + " -> " + response.code());
            return response;
        } catch (IOException failure) {
            // Exception messages can contain the complete signed request URL.
            logger.accept(description + " failed: " + failure.getClass().getSimpleName());
            throw failure;
        }
    }
}
