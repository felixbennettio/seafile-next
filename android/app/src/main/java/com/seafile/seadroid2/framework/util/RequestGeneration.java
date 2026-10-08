package com.seafile.seadroid2.framework.util;

import java.util.concurrent.atomic.AtomicLong;

/** Prevent a previous navigation or refresh from replacing the current screen. */
public final class RequestGeneration {
    private final AtomicLong generation = new AtomicLong();

    public long next() {
        return generation.incrementAndGet();
    }

    public boolean isCurrent(long request) {
        return generation.get() == request;
    }
}
