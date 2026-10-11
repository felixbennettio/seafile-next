package com.seafile.seadroid2.framework.util;

import java.util.regex.Pattern;

/** Parse the original server cookie without exposing it to diagnostics. */
public final class SsoCookies {
    private static final Pattern TOKEN = Pattern.compile("[0-9a-fA-F]{40}");
    private SsoCookies() {}

    public static String find(String header, String name) {
        if (header == null || name == null || name.isEmpty()) return null;
        for (String entry : header.split(";")) {
            int separator = entry.indexOf('=');
            if (separator >= 0 && entry.substring(0, separator).trim().equals(name)) {
                return entry.substring(separator + 1).trim();
            }
        }
        return null;
    }

    public static Identity identity(String value) {
        if (value == null) return null;
        value = value.trim();
        if (value.isEmpty()) return null;
        if (value.startsWith("\"") || value.endsWith("\"")) {
            if (value.length() < 2 || !value.startsWith("\"") || !value.endsWith("\"")) return null;
            value = value.substring(1, value.length() - 1);
        }
        int separator = value.lastIndexOf('@');
        if (separator <= 0 || separator == value.length() - 1) return null;
        String username = value.substring(0, separator);
        String token = value.substring(separator + 1);
        if (username.trim().isEmpty() || username.codePointCount(0, username.length()) > 254 || !TOKEN.matcher(token).matches()) return null;
        for (int offset = 0; offset < username.length();) {
            int character = username.codePointAt(offset);
            if (Character.isISOControl(character)) return null;
            offset += Character.charCount(character);
        }
        return new Identity(username, token);
    }

    public static final class Identity {
        public final String username;
        public final String token;
        private Identity(String username, String token) { this.username = username; this.token = token; }
    }
}
