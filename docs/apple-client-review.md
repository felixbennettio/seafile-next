# Native Apple client review

The first native TestFlight build (1.0.0 / 2412.47.16) was an incomplete beta. Compilation and upload did not establish feature parity or validate the iPhone navigation flow. The original iOS source and extensions remain in `ios-legacy/`.

## October 7, 2026 fixes

- On a compact iPhone, the original `NavigationSplitView` displayed its account sidebar without a link to its library detail. Selecting an account changed the model but never opened the file browser. iOS now starts on Files, with separate Starred and Accounts tabs. Switching accounts opens that account's libraries.
- Login was limited to password/OTP authentication. Browser SSO uses the existing Seafile `api2/client-sso-link/` creation/polling protocol, the server's configured OIDC/SAML login and all five device parameters. Successful login verifies `api2/account/info/` before saving credentials and loading libraries.
- Library failures have a visible error and retry action. They are no longer covered by a misleading empty-library placeholder. Existing cached listings remain usable when available.
- Upgrading from the first beta retains access to the original Keychain group and migrates credentials to the explicit shared group. File Provider setup errors are reported independently of account authentication.
- The signing lookup matches the exact parent Bundle ID, even when Apple's identifier filter also returns its File Provider child.
- After the owner explicitly chose to retain system file integration, `group.io.felixbennett.seafile` was registered and assigned only to the existing universal app and its File Provider extension. Both platforms declare the matching document group and entitlement. CI reuses valid group-enabled profiles and checks the actual signed host, extension and embedded profiles before upload; it no longer registers App IDs automatically.
- iOS and macOS uploads and processing checks now run in separate steps. A macOS rejection no longer hides a successfully processed iOS build.

## Server compatibility

A read-only check of the existing `/seafile/` deployment returned `13.0.25`, a working `api2/ping/`, and the `client-sso-via-local-browser` capability. These client fixes use existing server APIs and do not require replacing that Docker deployment. No production server configuration or data was changed.

An additional isolated browser-flow test exposed a server default: after setting `SITE_ROOT=/seafile/`, the default `LOGIN_URL` still pointed to `/accounts/login/`, outside that deployment. The new server source resolves default login, post-login and OTP URLs after loading both configuration files and Docker's `SITE_ROOT` environment override, preserving custom authentication endpoints. Image `13.0.25-next.6` contains this correction. The existing production deployment's full browser SSO flow has not been authenticated; the presence of its capability alone does not prove its IdP/redirect configuration. The client navigation defect itself is independent of this server issue.

Isolated CI server checks cover both `/` and `/seafile/`: password login, canonical account identity, libraries, the native client's v2.1 directory response, Unicode paths, binary upload/download, rename and delete. This verifies the new image separately from the owner's existing deployment.

## Current implementation and gaps

The cross-platform source/build audit and per-platform missing features are now tracked in [platform-feature-audit.md](platform-feature-audit.md). In particular, retaining `ios-legacy/` did not port its controllers or extensions into the native iOS target. The table below records the earlier October 7 state; the linked audit supersedes its macOS pending items after the October 8 work.

| Capability | Native application status |
| --- | --- |
| Multiple accounts, password login and OTP | Implemented |
| Browser OIDC/SAML/SSO | Implemented for servers advertising browser client SSO; older cookie-bridge SSO fallback remains pending |
| Libraries, folders, refresh and cached listings | Implemented; iPhone entry repaired |
| File upload, download, Quick Look preview | Implemented |
| Folder creation, rename, delete, star and share links | Implemented |
| Encrypted-library password unlock | Implemented through the server; the old iOS optional local-decryption path has not been ported |
| macOS desktop synchronization | Native UI with bundled existing sync engine; actual login-item behavior after reboot still needs device validation |
| macOS Finder File Provider | Included in the sandbox/TestFlight target; signed group and upload verified; actual device behavior remains unverified |
| iOS system Files integration | Embedded with the same registered App Group; signed group and upload verified; actual device behavior remains unverified |
| Non-sandbox macOS | Separate direct target retained; current CI artifact uses ad-hoc signing and is not notarized |
| Automatic camera/Live Photo backup | Pending native implementation |
| Batch selection, copy/move, server-wide search | macOS implemented on October 8; iOS UI remains pending |
| File history, editing, richer media playback and legacy share extensions | macOS default-app editing/Finder history added; original iOS editors/media/share extensions remain pending |
| Localization parity with the existing iOS application | Pending |

Tests must pass before TestFlight publishing. Core tests exercise SSO requests, device metadata, deployment paths, canonical identity and rejection of invalid sessions/links, alongside transfer/cache protections. iPhone simulator UI tests launch a Debug-only isolated fixture, verify initial libraries, nested folder navigation, account switching, and an SSO button that needs only the server address. Fixture modes are absent from Release builds and never write credentials or contact a real server.

The owner's actual OIDC provider and signed-in library content cannot be validated with an unauthenticated server check. The build status, simulator results and TestFlight processing state must be reported separately from a real-device sign-in result.

Apple's [File Provider sample](https://developer.apple.com/documentation/fileprovider/synchronizing-files-using-file-provider-extensions) uses one registered group across the apps and extensions. Its [macOS App Group guidance](https://developer.apple.com/documentation/xcode/accessing-app-group-containers) requires a provisioning profile authorizing a `group.` identifier. These requirements are checked against the signed archive rather than inferred from source configuration.

## Verified delivery on October 7, 2026

[Native Apple run 37611158560](https://github.com/felixbennettio/seafile-next/actions/runs/37611158560), built from `3cde1cccd9964ba0867eab7fe2d1d575508f34f4`, completed successfully:

- 14 Core/API tests passed and 5 iPhone simulator UI tests passed.
- The iOS and macOS signed archives each passed host/extension App Group, embedded provisioning profile and document-group checks.
- Both uploads succeeded. App Store Connect reported iOS and macOS build **1.0.0 (2414.62.57)** as `VALID`; both were assigned to the existing automatic internal group with one tester. This processing state is separate from external beta review.
- The same run retains the non-sandbox Mac ZIP in its `native-apple-validation` artifact. It uses ad-hoc signing and is not notarized.

[Server integration run 37581848403](https://github.com/felixbennettio/seafile-next/actions/runs/37581848403) passed against image `13.0.25-next.6`, including complete isolated iOS and macOS browser SSO flows under both `/` and `/seafile/`. Anonymous GHCR access was verified and the downloaded manifest matched digest `sha256:2b785e46be47023a5252804d5c335ee20b174937db7c8b8a2610097cd21f2b2e`.

No actual owner-account OIDC sign-in, physical iPhone Files session, Finder session or macOS reboot/login-item test is established by these CI results. Those remain explicit device-validation limits.

## Follow-up from the owner's device report

The owner reported persistent TLS handshake failures after file preview, accidental loss of favorites after preview, missing folder favorites, and IdP authorization app links failing inside the authentication sheet. These reports supersede any assumption that the earlier CI delivery established a complete real-device SSO/preview flow.

- Network requests now share a bounded connection pool. Transient network or TLS handshake failures retire the pool and establish new connections, including for subsequent requests. Safe reads, downloads, token retrieval and nonce creation receive at most two retries. Uploads and file mutations are never replayed automatically, certificate failures remain failures, and cancellation is preserved. Final errors include the hostname and URL error code without signed query values.
- Favorites use the server's `api/v2.1/starred-items/` API, including folder metadata. A folder favorite opens its own path after verifying its library and encryption state. Preview has one plain button; unstar is a separate context/swipe action requiring confirmation.
- SSO now opens the actual default browser, allowing the IdP's app links/passkeys to use normal browser handoff. It marks the nonce visited once without following the login redirect, then directly opens the deployment-prefixed `sso/` route with one encoded `next` value. When the user returns to the app, server nonce polling supplies the identity; browser URLs never supply credentials.
- A read-only response from the existing deployment confirmed its login template interpolates the nested `next` query with literal `&amp;` inside JavaScript, losing device parameters when its SSO button is clicked. The native direct route bypasses that old template. The server template is also corrected for web users in image `13.0.25-next.7`; the native repair does not require installing that image.
- Literal plus signs in API paths/device metadata are encoded as `%2B`, matching Django's query parser.
- iPhone regression testing exposed a second preview issue: a plain file button's accessibility frame covered the list row, while its actual touch area covered only the label. Center-row taps missed the action. File/favorite rows now give the entire row a rectangular touch area; both entry points are covered by preview tests.
- New TestFlight builds receive Chinese and English functional test notes automatically, verified by reading the saved build-localization records back from App Store Connect.

Native validation for this follow-up passed in [run 37622591055](https://github.com/felixbennettio/seafile-next/actions/runs/37622591055), built from `21fffed0b0d497d95a20593c5532cbaeac45cfb4`: all 24 Core/API tests and all 8 iPhone simulator UI tests passed with zero failures. The signed iOS archive passed its host/extension checks and uploaded successfully. App Store Connect reported iOS **1.0.0 (2415.22.80)** as `VALID`, with the existing automatic internal group containing one tester.

That run subsequently stopped while saving test notes because the API rejected the UI label `whatToTest` as an unknown attribute. The publisher now uses Apple's documented [`whatsNew` field](https://developer.apple.com/documentation/appstoreconnectapi/betabuildlocalizationcreaterequest/data-data.dictionary/attributes-data.dictionary). [Delivery recovery run 37626472528](https://github.com/felixbennettio/seafile-next/actions/runs/37626472528), built from `a308fc7028431c7cd3ae4f8bbb63be6324985384`, completed successfully after checking the previous native test results and verifying that the application sources, dependency pins, signing commands and archive checks were unchanged.

- Both iOS and macOS **1.0.0 (2415.22.80)** are `VALID` in App Store Connect, with the existing automatic internal group containing one tester.
- The macOS host and File Provider signed archives passed App Group, embedded profile and document-group checks before uploading.
- Chinese and English test notes were saved and read back successfully for each platform.
- The non-sandbox Mac ZIP and successful simulator screenshots remain in the original validation run's `native-apple-validation` artifact. The direct ZIP is ad-hoc signed and not notarized.
- These automated results do not establish that the owner's physical iPhone TLS fault or its IdP authorization-app handoff has been reproduced and resolved. Retesting that device remains necessary; final network errors now include the hostname and URL error code.

[Run 37620402299](https://github.com/felixbennettio/seafile-next/actions/runs/37620402299) passed all 24 Core/API tests. Its simulator screenshots and accessibility trees confirmed both center-row preview actions opened Quick Look with the actual fixture text. The UI test incorrectly expected a `Done` label; iOS 26 exposes the close control as `QLOverlayDoneButtonAccessibilityIdentifier`, labeled `close`. The corrected tests use that observed identifier, assert the displayed text, close the preview and reload favorites. The two runs with failed preview tests stopped before uploading.

Server validation for the follow-up passed:

- [Run 37617592433](https://github.com/felixbennettio/seafile-next/actions/runs/37617592433) used the existing `13.0.25-next.6` image and verified file/folder favorites, preview preserving both favorites, password browser SSO and the native direct SSO route through an isolated OAuth/OIDC provider, under both `/` and `/seafile/` for iOS and macOS device metadata.
- [Run 37618558534](https://github.com/felixbennettio/seafile-next/actions/runs/37618558534) verified `13.0.25-next.7`, including executing the rendered web login button's JavaScript and following its actual URL through the isolated IdP's code exchange, server callback, confirmation and API-token polling. Both deployment paths and device platforms passed.
- The `next.7` manifest was pulled anonymously from GHCR and matched the published digest `sha256:04090ce96812bc5ed680a3367b966d9ddf1142929384d0b014c5a28f30df6629`.
- A local macOS Foundation client made 12 successive read-only `server-info/` requests to the owner's existing deployment successfully. This does not reproduce or exclude the reported iPhone TLS failure.

## Signing and unified release on October 8, 2026

The signing audit confirmed both cached distribution private keys match their existing Apple certificates, which expire on October 7, 2027. The app and File Provider retain their two universal Identifiers and four active App Store profiles. Four invalid profiles created before enabling App Groups were deleted; other team certificates were retained. Missing or mismatched cached keys now stop publishing instead of automatically creating another certificate. Profile names do not include the app version.

The first unified GitHub Release reuses the already validated Android, Windows, Linux and native non-sandbox Mac packages. Previous native workflows did not retain their iOS device IPA, and their simulator ZIPs cannot substitute for one. Both Apple platforms remain available in the owner's existing internal TestFlight group. Future Apple archives retain a separate unsigned device IPA, including File Provider, with provisioning and signing material removed; the unified publisher rejects simulator packages and waits for all platform validation and delivery jobs before publishing.
