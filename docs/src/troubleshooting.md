# Troubleshooting

- **No application DMG in Releases:** distinguish dependency artifacts from a qualified application release; consult the current installation reference.
- **Pairing fails:** generate a new link and confirm HTTPS connectivity and server identity. Do not bypass certificate warnings.
- **Encrypted message needs webmail:** check the account's custody mode and whether this device completed key enrollment.
- **"Finish encryption setup":** your server requires email encryption setup first. Choose **Open KyPost on the web** (which opens its `/setup/encryption` page), finish it, then return to the app or choose **Check again**. You stay paired.
- **Send outcome is uncertain:** inspect **Sent** before choosing a retry.
- **No push:** check APNs entitlement, signing, and the server configuration on a real device.
- **Locked or wiped profile:** use the documented device reset and re-pair flow; keep independent access to the account's recovery material.

When reporting a problem, include the product version, platform, failed task and a redacted error. Exclude pairing links, device secrets, recovery codes, custodian shares and private content.
