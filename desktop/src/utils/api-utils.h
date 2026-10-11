#ifndef SEAFILE_CLIENT_API_UTILS_H_
#define SEAFILE_CLIENT_API_UTILS_H_

#include <QHash>
#include <QString>

namespace SeafileLoginMetadata {
// TokenV2 stores names in 40 characters and versions in 16. Count Unicode
// characters without cutting a UTF-16 surrogate pair in half.
inline QString bounded(const QString& input, int limit)
{
    QString result;
    for (int i = 0, count = 0; i < input.size() && count < limit; ++i) {
        const QChar character = input.at(i);
        if (character.isHighSurrogate() && i + 1 < input.size() && input.at(i + 1).isLowSurrogate()) {
            result.append(character); result.append(input.at(++i)); ++count;
        } else if (!character.isSurrogate() && character.category() != QChar::Other_Control) {
            result.append(character); ++count;
        }
    }
    return result.trimmed();
}

inline QHash<QString, QString> parameters(const QString& name, const QString& fallbackName,
                                         const QString& deviceId, const QString& platform,
                                         const QString& clientVersion, const QString& systemVersion,
                                         const QString& prefix = QString())
{
    QString deviceName = bounded(name.trimmed(), 40);
    if (deviceName.isEmpty()) deviceName = bounded(fallbackName.trimmed(), 40);
    if (deviceName.isEmpty()) deviceName = "Seafile Next";
    QHash<QString, QString> result;
    result.insert(prefix + "platform", platform);
    result.insert(prefix + "device_id", deviceId);
    result.insert(prefix + "device_name", deviceName);
    result.insert(prefix + "client_version", bounded(clientVersion, 16));
    const QString version = bounded(systemVersion, 16);
    // The original serializer allows this field to be omitted, but rejects an
    // explicitly empty value. Do not send an empty optional version.
    if (!version.isEmpty()) result.insert(prefix + "platform_version", version);
    return result;
}
}

QHash<QString, QString>
getSeafileLoginParams(const QString& computer_name=QString(),
                      const QString& prefix=QString());

#endif // SEAFILE_CLIENT_API_UTILS_H_
