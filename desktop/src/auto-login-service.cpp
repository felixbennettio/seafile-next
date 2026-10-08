#include <QDesktopServices>
#include <QHash>

#include "seafile-applet.h"
#include "account-mgr.h"
#include "api/api-error.h"
#include "api/requests.h"
#include "utils/utils.h"

#include "auto-login-service.h"

namespace {

} // namespace

SINGLETON_IMPL(AutoLoginService)

AutoLoginService::AutoLoginService(QObject *parent)
    : QObject(parent)
{
}

void AutoLoginService::startAutoLogin(const QString& next_url)
{
    const Account account = seafApplet->accountManager()->currentAccount();
    QUrl absolute_url = QUrl(next_url).isRelative()
                            ? account.getAbsoluteUrl(next_url)
                            : next_url;
    if (!account.isValid() || !account.isAtLeastVersion(4, 2, 0)) {
        openUrl(absolute_url);
        return;
    }

    QString next = urlPathWithQueryAndFragment(absolute_url);
    GetLoginTokenRequest *req = new GetLoginTokenRequest(account, next);

    connect(req, SIGNAL(success(const QString&)),
            this, SLOT(onGetLoginTokenSuccess(const QString&)));

    connect(req, SIGNAL(failed(const ApiError&)),
            this, SLOT(onGetLoginTokenFailed(const ApiError&)));

    req->send();
}

void AutoLoginService::onGetLoginTokenSuccess(const QString& token)
{
    GetLoginTokenRequest *req = (GetLoginTokenRequest *)(sender());
    // printf("login token is %s\n", token.toUtf8().data());

    QUrl url = req->account().getAbsoluteUrl("/client-login/");
    QString next_url = req->nextUrl();

    QHash<QString, QString> params;
    params.insert("token", token);
    params.insert("next", req->nextUrl());
    url = includeQueryParams(url, params);

    openUrl(url);
    req->deleteLater();
}

void AutoLoginService::onGetLoginTokenFailed(const ApiError& error)
{
    GetLoginTokenRequest *req = (GetLoginTokenRequest *)(sender());
    qWarning("get login token failed: %s\n", error.toString().toUtf8().data());
    // Two-factor enabled servers intentionally return an empty token response,
    // and older servers may not support direct login. nextUrl() already
    // contains SITE_ROOT, so appending it to account.serverUrl would duplicate
    // a non-root deployment prefix.
    openUrl(urlFromSameOriginPath(req->account().serverUrl, req->nextUrl()));
    req->deleteLater();
}
