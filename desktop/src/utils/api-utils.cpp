#include <QHash>
#include <QHostInfo>
#include <QSysInfo>

#include "utils.h"
#include "seafile-applet.h"
#include "rpc/rpc-client.h"
#include "api-utils.h"

namespace {

#if defined(Q_OS_WIN32)
const char *kOsName = "windows";
#elif defined(Q_OS_LINUX)
const char *kOsName = "linux";
#else
const char *kOsName = "mac";
#endif

} // namespace

QHash<QString, QString>
getSeafileLoginParams(const QString& computer_name, const QString& prefix)
{

    return SeafileLoginMetadata::parameters(computer_name, QHostInfo::localHostName(),
                                            seafApplet->getUniqueClientId(), kOsName,
                                            STRINGIZE(SEAFILE_CLIENT_VERSION),
                                            QSysInfo::productVersion(), prefix);
}
