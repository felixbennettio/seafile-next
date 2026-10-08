package com.seafile.seadroid2.framework.http;

import androidx.annotation.Nullable;

import com.blankj.utilcode.util.CloneUtils;
import com.seafile.seadroid2.account.Account;
import com.seafile.seadroid2.account.SupportAccountManager;

import java.util.Objects;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentMap;

public class HttpManager {
    private static final String CURRENT_ACCOUNT_HTTP_KEY = "current_account_http_key";
    private static final ConcurrentMap<String, HttpIO> IO_MAP = new ConcurrentHashMap<>();

    /**
     * When log in again or switch account, you should reset this IO Singleton.
     * <p><b>because it's a SINGLETON, unless kill the APP!<b/></p>
     */
    public static void reset() {
        IO_MAP.clear();
    }

    public static void removeHttpWithAccount(Account account) {
        if (account == null) {
            return;
        }

        IO_MAP.remove(account.getSignature());
    }

    @Nullable
    public static HttpIO getCurrentLoggedHttp() {
        return getCurrentIO();
    }

    public static HttpIO getCurrentHttp() {
        HttpIO httpIO = getCurrentIO();
        if (httpIO == null) {
            throw new IllegalStateException("No user logged in");
        }

        return httpIO;
    }

    @Nullable
    private static HttpIO getCurrentIO() {
        HttpIO httpIO = IO_MAP.get(CURRENT_ACCOUNT_HTTP_KEY);
        if (httpIO != null) {
            return httpIO;
        }

        synchronized (HttpManager.class) {
            Account curAccount = SupportAccountManager.getInstance().getCurrentAccount();
            if (curAccount == null) {
                return null;
            }

            HttpIO io = new HttpIO(curAccount);
            IO_MAP.put(CURRENT_ACCOUNT_HTTP_KEY, io);
            return io;
        }
    }

    /**
     * Not Logged/Log in to another server
     */
    public static HttpIO getHttpWithAccount(Account account) {
        if (account == null) {
            return null;
        }

        // Not logged in
        if (!IO_MAP.containsKey(account.getSignature())) {
            return resetHttpIo(account);
        }

        HttpIO httpIo = IO_MAP.get(account.getSignature());
        if (httpIo == null) {
            return resetHttpIo(account);
        }

        if (!Objects.equals(httpIo.getAccount(), account)) {
            return resetHttpIo(account);
        }

        return httpIo;

    }

    private static HttpIO resetHttpIo(Account account) {
        Account newAccount = CloneUtils.deepClone(account, Account.class);// deep clone
        HttpIO httpIo = new HttpIO(newAccount);
        IO_MAP.put(newAccount.getSignature(), httpIo);
        return httpIo;
    }

}
