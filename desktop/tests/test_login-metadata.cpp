#include <QtTest/QtTest>
#include "../src/utils/api-utils.h"

class LoginMetadataTest : public QObject {
    Q_OBJECT
private slots:
    void emptyNameUsesFallbackAndUnknownSystemVersionIsOmitted() {
        const auto fields = SeafileLoginMetadata::parameters(" \n", "Desktop", "stable-device", "linux", "9.0.20", "");
        QCOMPARE(fields.value("device_name"), QString("Desktop"));
        QCOMPARE(fields.value("device_id"), QString("stable-device"));
        QVERIFY(!fields.contains("platform_version"));
        const auto noHost = SeafileLoginMetadata::parameters("", "", "stable-device", "windows", "9.0.20", "11");
        QVERIFY(!noHost.value("device_name").isEmpty());
        QCOMPARE(noHost.value("platform_version"), QString("11"));
    }
    void passwordAndSSOUseTheSameBoundedFields() {
        const auto password = SeafileLoginMetadata::parameters(QString(80, 'n'), "Fallback", "stable-device", "windows", QString(30, '1'), QString(30, '2'));
        const auto sso = SeafileLoginMetadata::parameters(QString(80, 'n'), "Fallback", "stable-device", "windows", QString(30, '1'), QString(30, '2'), "shib_");
        for (auto it = password.cbegin(); it != password.cend(); ++it) QCOMPARE(sso.value("shib_" + it.key()), it.value());
        QCOMPARE(password.value("device_name").size(), 40);
        QCOMPARE(password.value("client_version").size(), 16);
        QCOMPARE(password.value("platform_version").size(), 16);
        QCOMPARE(password.value("device_id"), QString("stable-device"));
    }
    void nonBMPNamesStayWholeAndControlsAreNotSent() {
        const QString character = QString::fromUtf8("\xF0\x9F\x93\x81");
        const auto fields = SeafileLoginMetadata::parameters(character.repeated(45), "Fallback", "stable-device", "linux", "9.0.20", "24.04");
        QCOMPARE(fields.value("device_name"), character.repeated(40));
        QCOMPARE(SeafileLoginMetadata::bounded("Desk\n\tTop", 40), QString("DeskTop"));
        QCOMPARE(SeafileLoginMetadata::bounded(QString(QChar(0xd800)) + "Name", 40), QString("Name"));
    }
};
QTEST_APPLESS_MAIN(LoginMetadataTest)
#include "test_login-metadata.moc"
