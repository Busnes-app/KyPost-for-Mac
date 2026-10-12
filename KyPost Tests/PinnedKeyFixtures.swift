//
//  PinnedKeyFixtures.swift
//  KyPost Tests
//
//  Public keys for the pinned-key revocation tests. Never real keys.
//
//  Generated with ProtonMail/go-crypto's v1 `openpgp` package (no gpg, sq or rnp
//  was available on the machine that made them). That is the same library family
//  GopenPGP is built on, so these prove the merge and the checks behave on
//  keys and revocations go-crypto emits — not that other implementations' bytes
//  agree; the gpg-made fixtures in TestPgpFixtures still cover reading.
//

enum PinnedKeyFixtures {
    /// The key as pinned: ed25519 primary (certify+sign), cv25519 encryption subkey.
    static let alicePinned = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xjMEaVW5ABYJKwYBBAHaRw8BAQdAuib3CosEF/84tqUr0vFkN3HttEWJDmheT9+4
    rfwNKYzNIUFsaWNlIFBpbiA8YWxpY2VAZXhhbXBsZS5pbnZhbGlkPsK9BBMWCABv
    BYJpVbkAAgsHCRDCg+AVx9Ma9jUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5vcGVu
    cGdwanMub3JnnTYQHmAwTBnvNdUK/WDn6gIVCAIWAAIZAQKbAwIeARYhBK4/1i/K
    rvd8jBkiHcKD4BXH0xr2AAAwWQEArIAEqmLxdg1qD6/gFR6dErbRsxUFG3kbjWhP
    j3x/p9ABAPxwOQdcHu6iKpsbfIGStxvpR1nHJWh/1Nq1k19hOBAHzjgEaVW5ABIK
    KwYBBAGXVQEFAQEHQAPQ+0qOX4L+hZe5nxkC8oRY8422mdmAMEmM5NOslHwyAwEK
    CcKuBBgWCABgBYJpVbkACRDCg+AVx9Ma9jUUAAAAAAAcABBzYWx0QG5vdGF0aW9u
    cy5vcGVucGdwanMub3JnhnxmXLK1G2uxdB6w2MzbbAKbDBYhBK4/1i/Krvd8jBki
    HcKD4BXH0xr2AAAR9AD9G4viaRBt5z+puh4s9jPNQUjIamAyqvbjXhT+WfPQF5sA
    /25nXFwTr94XyLLnMhHpRJVPxGF8Xd7bdzb3ez4sxfwJ
    =dKmr
    -----END PGP PUBLIC KEY BLOCK-----
    """

    /// The same key after its owner revoked the primary (reason: compromised).
    static let aliceRevokedPrimary = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xjMEaVW5ABYJKwYBBAHaRw8BAQdAuib3CosEF/84tqUr0vFkN3HttEWJDmheT9+4
    rfwNKYzCuQQgFggAawWCaVW5AAkQwoPgFcfTGvY1FAAAAAAAHAAQc2FsdEBub3Rh
    dGlvbnMub3BlbnBncGpzLm9yZ3G7cLNXAg5ywwIlyiQG5wUNnQJjb21wcm9taXNl
    ZBYhBK4/1i/Krvd8jBkiHcKD4BXH0xr2AAAAuAEA2rbQSRyc85gMtQZjqOi60nzL
    SSj41YxNJ1TOUngZRqIBAJpj6mBFqgt5DZtOCq9qFCrm9kYUCCC0iUlj+XrTAaMK
    zSFBbGljZSBQaW4gPGFsaWNlQGV4YW1wbGUuaW52YWxpZD7CvQQTFggAbwWCaVW5
    AAILBwkQwoPgFcfTGvY1FAAAAAAAHAAQc2FsdEBub3RhdGlvbnMub3BlbnBncGpz
    Lm9yZ502EB5gMEwZ7zXVCv1g5+oCFQgCFgACGQECmwMCHgEWIQSuP9Yvyq73fIwZ
    Ih3Cg+AVx9Ma9gAAMFkBAKyABKpi8XYNag+v4BUenRK20bMVBRt5G41oT498f6fQ
    AQD8cDkHXB7uoiqbG3yBkrcb6UdZxyVof9TatZNfYTgQB844BGlVuQASCisGAQQB
    l1UBBQEBB0AD0PtKjl+C/oWXuZ8ZAvKEWPONtpnZgDBJjOTTrJR8MgMBCgnCrgQY
    FggAYAWCaVW5AAkQwoPgFcfTGvY1FAAAAAAAHAAQc2FsdEBub3RhdGlvbnMub3Bl
    bnBncGpzLm9yZ4Z8ZlyytRtrsXQesNjM22wCmwwWIQSuP9Yvyq73fIwZIh3Cg+AV
    x9Ma9gAAEfQA/RuL4mkQbec/qboeLPYzzUFIyGpgMqr2414U/lnz0BebAP9uZ1xc
    E6/eF8iy5zIR6USVT8RhfF3e23c293s+LMX8CQ==
    =SvAm
    -----END PGP PUBLIC KEY BLOCK-----
    """

    /// The same key after its owner revoked the encryption subkey.
    static let aliceRevokedSubkey = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xjMEaVW5ABYJKwYBBAHaRw8BAQdAuib3CosEF/84tqUr0vFkN3HttEWJDmheT9+4
    rfwNKYzNIUFsaWNlIFBpbiA8YWxpY2VAZXhhbXBsZS5pbnZhbGlkPsK9BBMWCABv
    BYJpVbkAAgsHCRDCg+AVx9Ma9jUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5vcGVu
    cGdwanMub3JnnTYQHmAwTBnvNdUK/WDn6gIVCAIWAAIZAQKbAwIeARYhBK4/1i/K
    rvd8jBkiHcKD4BXH0xr2AAAwWQEArIAEqmLxdg1qD6/gFR6dErbRsxUFG3kbjWhP
    j3x/p9ABAPxwOQdcHu6iKpsbfIGStxvpR1nHJWh/1Nq1k19hOBAHzjgEaVW5ABIK
    KwYBBAGXVQEFAQEHQAPQ+0qOX4L+hZe5nxkC8oRY8422mdmAMEmM5NOslHwyAwEK
    CcK5BCgWCABrBYJpVbkACRDCg+AVx9Ma9jUUAAAAAAAcABBzYWx0QG5vdGF0aW9u
    cy5vcGVucGdwanMub3Jn0RFL0dGlZahL8SMcOvcjVg2dAnN1YmtleSBsb3N0FiEE
    rj/WL8qu93yMGSIdwoPgFcfTGvYAAGeDAQDCYrNV/8h+9hzOALiCZVUHgWr1kiuP
    ni/7C4q8B1BxyQD9HybmZuAGt3wSrqNKUWsspsL3rm29faAYABd7Oyj1GwzCrgQY
    FggAYAWCaVW5AAkQwoPgFcfTGvY1FAAAAAAAHAAQc2FsdEBub3RhdGlvbnMub3Bl
    bnBncGpzLm9yZ4Z8ZlyytRtrsXQesNjM22wCmwwWIQSuP9Yvyq73fIwZIh3Cg+AV
    x9Ma9gAAEfQA/RuL4mkQbec/qboeLPYzzUFIyGpgMqr2414U/lnz0BebAP9uZ1xc
    E6/eF8iy5zIR6USVT8RhfF3e23c293s+LMX8CQ==
    =AOBM
    -----END PGP PUBLIC KEY BLOCK-----
    """

    /// The same key carrying a key-revocation signature made by a **different** key (Mallory's) — a revocation packet that does not verify against Alice's primary.
    static let aliceForgedRevocation = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xjMEaVW5ABYJKwYBBAHaRw8BAQdAuib3CosEF/84tqUr0vFkN3HttEWJDmheT9+4
    rfwNKYzCqwQgFggAXQWCaVW5AAkQkNnIKjoc7Xg1FAAAAAAAHAAQc2FsdEBub3Rh
    dGlvbnMub3BlbnBncGpzLm9yZ5n52V3hVepoHQvK2znUcs8WIQQVdf9QHHqq0XZX
    X5CQ2cgqOhzteAAAkZkBAMYU7HMTUfJCVfNxVCpl7sa9vE8n1juhDZt6E9ujpE64
    AQCYgIuHUy4HYH6eATjddkKN5mpgo3ji9Rkti4IUfwvrCM0hQWxpY2UgUGluIDxh
    bGljZUBleGFtcGxlLmludmFsaWQ+wr0EExYIAG8FgmlVuQACCwcJEMKD4BXH0xr2
    NRQAAAAAABwAEHNhbHRAbm90YXRpb25zLm9wZW5wZ3Bqcy5vcmedNhAeYDBMGe81
    1Qr9YOfqAhUIAhYAAhkBApsDAh4BFiEErj/WL8qu93yMGSIdwoPgFcfTGvYAADBZ
    AQCsgASqYvF2DWoPr+AVHp0SttGzFQUbeRuNaE+PfH+n0AEA/HA5B1we7qIqmxt8
    gZK3G+lHWcclaH/U2rWTX2E4EAfOOARpVbkAEgorBgEEAZdVAQUBAQdAA9D7So5f
    gv6Fl7mfGQLyhFjzjbaZ2YAwSYzk06yUfDIDAQoJwq4EGBYIAGAFgmlVuQAJEMKD
    4BXH0xr2NRQAAAAAABwAEHNhbHRAbm90YXRpb25zLm9wZW5wZ3Bqcy5vcmeGfGZc
    srUba7F0HrDYzNtsApsMFiEErj/WL8qu93yMGSIdwoPgFcfTGvYAABH0AP0bi+Jp
    EG3nP6m6Hiz2M81BSMhqYDKq9uNeFP5Z89AXmwD/bmdcXBOv3hfIsucyEelElU/E
    YXxd3tt3Nvd7PizF/Ak=
    =cBKT
    -----END PGP PUBLIC KEY BLOCK-----
    """

    /// The same key with a new encryption subkey added and nothing revoked: material a synced copy must never carry into the pin.
    static let aliceWithExtraSubkey = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xjMEaVW5ABYJKwYBBAHaRw8BAQdAuib3CosEF/84tqUr0vFkN3HttEWJDmheT9+4
    rfwNKYzNIUFsaWNlIFBpbiA8YWxpY2VAZXhhbXBsZS5pbnZhbGlkPsK9BBMWCABv
    BYJpVbkAAgsHCRDCg+AVx9Ma9jUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5vcGVu
    cGdwanMub3JnnTYQHmAwTBnvNdUK/WDn6gIVCAIWAAIZAQKbAwIeARYhBK4/1i/K
    rvd8jBkiHcKD4BXH0xr2AAAwWQEArIAEqmLxdg1qD6/gFR6dErbRsxUFG3kbjWhP
    j3x/p9ABAPxwOQdcHu6iKpsbfIGStxvpR1nHJWh/1Nq1k19hOBAHzjgEaVW5ABIK
    KwYBBAGXVQEFAQEHQAPQ+0qOX4L+hZe5nxkC8oRY8422mdmAMEmM5NOslHwyAwEK
    CcKuBBgWCABgBYJpVbkACRDCg+AVx9Ma9jUUAAAAAAAcABBzYWx0QG5vdGF0aW9u
    cy5vcGVucGdwanMub3JnhnxmXLK1G2uxdB6w2MzbbAKbDBYhBK4/1i/Krvd8jBki
    HcKD4BXH0xr2AAAR9AD9G4viaRBt5z+puh4s9jPNQUjIamAyqvbjXhT+WfPQF5sA
    /25nXFwTr94XyLLnMhHpRJVPxGF8Xd7bdzb3ez4sxfwJzjgEaVW5ABIKKwYBBAGX
    VQEFAQEHQGBqKcbF5aKV51qnusiseILkYXW8jciWytrbwxZ/f+1jAwEKCcKuBBgW
    CABgBYJpVbkACRDCg+AVx9Ma9jUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5vcGVu
    cGdwanMub3JneF0jbJFzCeU+TSVr+wmnQgKbDBYhBK4/1i/Krvd8jBkiHcKD4BXH
    0xr2AAAnmAD6Atd3+rg7D8oB+gtPhEL3HVllhrSP+uslHfj0lDkuSLYBAPNmPYee
    WleZUNaH9HxHCMai8OFEklRQRjBzgJFYEkcJ
    =QGg1
    -----END PGP PUBLIC KEY BLOCK-----
    """

    /// A different primary key, revoked by its owner.
    static let bobRevoked = """
    -----BEGIN PGP PUBLIC KEY BLOCK-----

    xjMEaVW5ABYJKwYBBAHaRw8BAQdAhQ5LDo18mXI/utFNBeRu6wth+AeD6DYEbWNQ
    l+PS7zbCrgQgFggAYAWCaVW5AAkQBoFSCeFTTY81FAAAAAAAHAAQc2FsdEBub3Rh
    dGlvbnMub3BlbnBncGpzLm9yZ/JKp74dMgiUCRCK700jOI8CnQIWIQSS/VeT71Gx
    8k6yC/kGgVIJ4VNNjwAA2+gA/26muaJweQ7Vej9+6CHfq0139xtEsQpTjXzgif3J
    09xeAP9/4YK0Lp3yHuq20njzX4DFl3jHAwp/BwUFmf+pXKRxD80fQm9iIE90aGVy
    IDxib2JAZXhhbXBsZS5pbnZhbGlkPsK9BBMWCABvBYJpVbkAAgsHCRAGgVIJ4VNN
    jzUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5vcGVucGdwanMub3JnQdqipc3hHUbr
    wj0wUUZ84gIVCAIWAAIZAQKbAwIeARYhBJL9V5PvUbHyTrIL+QaBUgnhU02PAACa
    HwD+L0Yacl5ro0/2fysrdtETmI3+QSWOxFulqVuEtdAx8q0BAJngfMvbH8SyeymN
    TdDGurphw45Z4auDwPOMF2JIaMcNzjgEaVW5ABIKKwYBBAGXVQEFAQEHQCy1ouYY
    PgsjnSs4XJlzxzc+5zepWhKAk6pZUWOs+v1pAwEKCcKuBBgWCABgBYJpVbkACRAG
    gVIJ4VNNjzUUAAAAAAAcABBzYWx0QG5vdGF0aW9ucy5vcGVucGdwanMub3Jnrcq5
    P4jPNUhSrtjLIPpC1QKbDBYhBJL9V5PvUbHyTrIL+QaBUgnhU02PAABtNAD7BHHG
    ugU8lDI5XvkDTkeyxVbYUGUyoDoTW85OS47cuCgA/3Ysn5DHFM9FgATOmB4EA4AP
    CJut9DeF8seX9FsgqJsB
    =YnPG
    -----END PGP PUBLIC KEY BLOCK-----
    """
}
