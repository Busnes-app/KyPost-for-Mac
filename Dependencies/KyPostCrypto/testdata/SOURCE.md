# Shared public test fixtures

Copied verbatim from Busnes-app/KyPost-Server commit
`4eb06d13e8b04993e74deacc1b1888f8e4e556e0` (PR #755), `testdata/`.
These are public test secrets. The OpenPGP fixture README records the P0
Bouncy Castle 1.87 cross-check. Do not regenerate these in the Mac repository.
`PqcFixtures.swift` embeds the subset used by XCTest; preserve exact bytes.

SHA-256 of copied files (relative to this directory):

```text
0e5b6243f7c47bd737f4a2e577734e84ead86b603c4b96045986045d9d08a3a7  device-envelope-xwing-browser.json
8084d7cded3d5bdd9d1d7af9dc890961e9298d10f406d63685ff91575ed7c5eb  device-envelope-xwing.json
f255db2d59c2ba8385408c65fc0d89e91c01d8af53afd2e1d845334360f2cfd0  openpgp-v6/README.md
6e93c5e14b241ff33b8a2566d9b9414d15cdf88f9b79d2375e8df8c32da9380d  openpgp-v6/SHA256SUMS
be09c4971373441cd44ecbb5554ec7b0b422a815fb9564294987f3297ba296f0  openpgp-v6/crosscheck/BcCheck.java
6c38cebbd8d700be155a76878693610d4400721d2739c74e821eceea1de7020c  openpgp-v6/golden-incoming.eml
bfeadcc9a1085207c60cb70674bee7ded75e95c0049cf315b6bfe81fa2333de9  openpgp-v6/golden-incoming.v4.eml
f96c2b8b44daad388a05d407b9bdcfba1bc9f954f30d895fc24c6840c3ccd28f  openpgp-v6/message.txt
acdad1f2ad389ee4631781aaff395e9add4693ca1698ac5cd7f8d2eb9d5982e6  openpgp-v6/v4-pqc.msg.asc
f97e8bd39a3d7777827c39cfff4722aff19dbf81162b3c188fe314769de0c487  openpgp-v6/v4-pqc.pub.asc
f97c0c57b2533a23245c4ddf28457ca9fa22f24c1412ba8da9d51fea5173be16  openpgp-v6/v4-pqc.sec.asc
f1f126f97c26a797a43c1be908ea7dadbc9c3d2febd0744f0370e46c07f55525  openpgp-v6/v4.msg.asc
8d91ab28c2d0aa560f2a5efed5ff4bb6d11585d241e3526782bd407de329ef12  openpgp-v6/v4.pub.asc
80b19f9801f6979c75fd0e956f1c44a3684a1cb5a4856676f48880f0cb9fe070  openpgp-v6/v4.sec.asc
12ec953c9b1e1cbac648cd33778af9ae1f0fabe43c466d2b6fc3727d166be964  openpgp-v6/v6-pqc.msg.asc
6eb45e4547003232644e60301878ab70f15d0db780234af162a04928aabd65f8  openpgp-v6/v6-pqc.pub.asc
61e1eac7019c23402db0eab633367985c521df4051aaece622ddccb48678f6e5  openpgp-v6/v6-pqc.sec.asc
1cf7b2ef95b5f9b3d7e4f824e16ae93375879438e9d7f1fe8baab307201019d5  openpgp-v6/v6-pqc.sig.asc
0496ae142010ebd6048cbe2e6a1d0a128eb02b75b7c48d246e3dd83f32c1c6d7  openpgp-v6/v6.pub.asc
020cccc779afb0161d0f7294eb6e272ad0f8544d72a2af76f664f11281c4c33c  openpgp-v6/v6.sec.asc
```
