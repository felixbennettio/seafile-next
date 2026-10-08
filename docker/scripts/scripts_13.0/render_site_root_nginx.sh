#!/usr/bin/env bash
set -euo pipefail

site_root="${SITE_ROOT:-/}"
public_protocol="${SEAFILE_SERVER_PROTOCOL:-https}"
template_path="${NGINX_TEMPLATE_PATH:-/services/seafile-site-root.nginx.conf.template}"
default_path="${NGINX_DEFAULT_PATH:-/services/seafile.nginx.conf}"
output_path="${NGINX_OUTPUT_PATH:-/etc/nginx/sites-enabled/seafile.nginx.conf}"

if [[ ! "${site_root}" =~ ^/([A-Za-z0-9._~-]+/)*$ ]]; then
    echo "SITE_ROOT must start and end with '/', for example /seafile/ or /cloud/." >&2
    exit 1
fi

if [[ "${public_protocol}" != "http" && "${public_protocol}" != "https" ]]; then
    echo 'SEAFILE_SERVER_PROTOCOL must be http or https.' >&2
    exit 1
fi

output_tmp="$(mktemp "${output_path}.tmp.XXXXXX")"
trap 'rm -f "${output_tmp}"' EXIT

if [[ "${site_root}" == "/" ]]; then
    test -s "${default_path}"
    cp "${default_path}" "${output_tmp}"
else
    test -s "${template_path}"
    site_root_base="${site_root%/}"
    site_root_regex="${site_root//./\\.}"
    site_root_regex_for_sed="${site_root_regex//\\/\\\\}"

    sed \
        -e "s|@@SITE_ROOT@@|${site_root}|g" \
        -e "s|@@SITE_ROOT_BASE@@|${site_root_base}|g" \
        -e "s|@@SITE_ROOT_REGEX@@|${site_root_regex_for_sed}|g" \
        -e "s|@@PUBLIC_PROTOCOL@@|${public_protocol}|g" \
        "${template_path}" > "${output_tmp}"
fi

chmod 0644 "${output_tmp}"
mv -f "${output_tmp}" "${output_path}"
trap - EXIT

if [[ "${NGINX_SKIP_CONFIG_TEST:-false}" != "true" ]]; then
    nginx -t
fi
