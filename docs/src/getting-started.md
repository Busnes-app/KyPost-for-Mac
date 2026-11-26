# Getting started

## Install

Read the product reference's current distribution status before looking for an application download. A GopenPGP dependency release is not an installable KyPost DMG. Source builds require Xcode 26 or later and matching platform SDKs; physical iOS devices also need appropriate signing and capabilities.

## Pair with the server

Prepare an everyday mailbox account on an HTTPS KyPost server. Build and run the **KyPost** scheme, generate a native-device pairing QR code or link in the server's security settings, and open or paste it in the intended client. Confirm the server identity and verify inbox loading.

Test a controlled send and reply. APNs delivery requires matching server and client push configuration. Pairing the relay does not itself enroll a client-held OpenPGP private key; use the separate enrollment flow if that account requires one.
