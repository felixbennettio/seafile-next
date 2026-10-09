#include "test_server-info.h"
#include <QSet>
#include <QtTest/QtTest>

#include "../src/api/server-info.h"

void ServerInfoTest::testFeature() {
    ServerInfo info1;
    QString feature1 = "file-search,office-preview,seafile-pro";
    info1.parseFeatureFromStrings(feature1.split(','));
    QVERIFY(info1.proEdition);
    QVERIFY(info1.fileSearch);
    QVERIFY(info1.officePreview);
    const QStringList list1 = feature1.split(','), list1b = info1.getFeatureStrings();
    QSet<QString> info1_set(list1.cbegin(), list1.cend());
    QSet<QString> info1b_set(list1b.cbegin(), list1b.cend());
    QCOMPARE(info1_set, info1b_set);

    ServerInfo info2;
    QString feature2 = "file-search,seafile-pro";
    info2.parseFeatureFromStrings(feature2.split(','));
    QVERIFY(info2.proEdition);
    QVERIFY(info2.fileSearch);
    QVERIFY(!info2.officePreview);
    const QStringList list2 = feature2.split(','), list2b = info2.getFeatureStrings();
    QSet<QString> info2_set(list2.cbegin(), list2.cend());
    QSet<QString> info2b_set(list2b.cbegin(), list2b.cend());
    QCOMPARE(info2_set, info2b_set);

    ServerInfo info3;
    QString feature3 = "file-search,office-preview,seafile-pro";
    info3.parseFeatureFromStrings(feature3.split(','));
    QVERIFY(info3.proEdition);
    QVERIFY(info3.fileSearch);
    QVERIFY(info3.officePreview);
    const QStringList list3 = feature3.split(','), list3b = info3.getFeatureStrings();
    QSet<QString> info3_set(list3.cbegin(), list3.cend());
    QSet<QString> info3b_set(list3b.cbegin(), list3b.cend());
    QCOMPARE(info3_set, info3b_set);

    info3.parseFeatureFromString("office-preview", false);
    QVERIFY(!info3.officePreview);
}

void ServerInfoTest::testVersion() {
    ServerInfo info;
    QString version = "1.2.4";
    info.parseVersionFromString(version);
    QCOMPARE(info.majorVersion, 1u);
    QCOMPARE(info.minorVersion, 2u);
    QCOMPARE(info.patchVersion, 4u);
    QCOMPARE(info.getVersionString(), version);
}

QTEST_APPLESS_MAIN(ServerInfoTest)

void ServerInfoTest::testModernSSOSurvivesStoredFeatures() {
    // AccountManager stores this comma-separated list in the account database
    // and reconstructs ServerInfo when restoring the saved account.
    ServerInfo discovered;
    discovered.parseFeatureFromStrings(QStringList() << "seafile-pro" << "client-sso-via-local-browser" << "file-search");
    const QString stored = discovered.getFeatureStrings().join(",");
    ServerInfo restored;
    restored.parseFeatureFromStrings(stored.split(','));
    QVERIFY(restored.clientSSOViaLocalBrowser);
    QVERIFY(restored.proEdition);
    QVERIFY(restored.fileSearch);
    QVERIFY(discovered == restored);
}

void ServerInfoTest::testModernSSOChangesServerInfoEquality() {
    ServerInfo before, after;
    after.parseFeatureFromString("client-sso-via-local-browser");
    // AccountManager otherwise returns early and omits its update signal.
    QVERIFY(before != after);
    after.parseFeatureFromString("client-sso-via-local-browser", false);
    QVERIFY(before == after);
}
