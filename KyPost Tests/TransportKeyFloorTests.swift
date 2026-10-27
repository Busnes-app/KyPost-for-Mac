//
//  TransportKeyFloorTests.swift
//  KyPost Tests
//
//  The TLS certificate-key floor in PinnedSessionDelegate
//  (docs/STRONG-CRYPTO.md). Real SecTrust evaluation of real chains, anchored
//  at a fixture root, at a fixed date, with no network: no mock decides.
//  Fixtures come from scripts/tls-key-floor-fixtures.sh (OpenSSL), which lists
//  every chain; the key sizes were checked with `openssl x509 -text`.
//

import Foundation
import Security
import Testing
@testable import KyPost

/// Base64 DER. Every leaf names relay.test; all are valid through 2026.
private enum TLSFixture {
    static let rootRSA2048 = "MIIC/DCCAeSgAwIBAgIUV1rBzou+zi6yX7cW1+IFlU/P2tcwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcm9vdFJTQTIwNDgwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAWMRQwEgYDVQQDDAtyb290UlNBMjA0ODCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAJoCJvI0JnwZhDYBSbM3LlgjTAjssGxjGQcnBLiCwMCtNSVRx+bM0lSgd8UlHhuNWlZ8R9jT7HbEB8ug7pMPh5objr4A4FIPUKjvlJDF2HIdQlQ0G4uBzflJNUhi1XexpQ5oDJZT9zvGRzIOJyuXxtQhqveD6HAIaj+T3AdPqeyNyHAK3w3iXFUqZimXFcADz38lTYa8ZBjkxjHHKzGGAm0GZC2cbUOBNvuuIo7MjrU7lcXpX075gSd+sElLzY6z04/2+CNtVcs6Zm4Iw5yPw9vtmv7D0pYBORB+nu4h3QKrJNrVXeVYRvuR3TfSZbmYARqaEc1Kg+JuRJfADMwBpc0CAwEAAaNCMEAwDwYDVR0TAQH/BAUwAwEB/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFBZ76lrokIU4z/BxKUEfEVM9/2UcMA0GCSqGSIb3DQEBCwUAA4IBAQBoi+rblevdtzKtoJ0y8x/T7V3nHfLUjP+wGD52L/PX4JmbKZVCNTim850rdhPYiHHoxDu9RFn3ml4UbBJYDeOgjSqYzvVtgSzeggyp9AzcDp6alFDH6OIX5NLAOcLPRAUF2tOrh8OP4MTFIGRBOuOMG3gOtAsFF4IgESk7K4UfnbUf2dBue7V2u3/b0zztLRwNiz1D9crsOc3XhvnQ/2wstpkXS5fosVCRFvEaJKAEHgUAvMsAOnF8tQ7RHgBkQzoaFaSUxZpJET/Tl5guWm99F2pc9mL8dZdSQEG/K1ZF76JdVn6/HZA9PHD+kY0tvb8A/Tq3oiF2yG4YIUGIxYRH"
    static let rootRSA2047 = "MIIC+zCCAeOgAwIBAgIUBh4SEpZFnehRBUDJA++PDn73shUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcm9vdFJTQTIwNDcwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAWMRQwEgYDVQQDDAtyb290UlNBMjA0NzCCASEwDQYJKoZIhvcNAQEBBQADggEOADCCAQkCggEAcCZzPuKVFEE0f4vVSNsz8ZuAd0JuV+Yb6DZk6Oaa18K/SgvORUIffXszfPFFjNbqH8BC3JChZK9wPxixvfa2xfgAEil+Uyc2/LJUponAzb1ZkJJh9d+WzB9vbjhdLYID1k/1zKx7fih2qzWpDea3b5XfV6dHPIaELkSf/ICjh7Fz5Wrw7wRmfUGN5CUOzb7OtzjaUzyAvZj0LcoGdqDLyH9ZZ8wSy/jhtilmFnvwOTbZCbImBZMtJTSLkH+Hix92G1jtqq70X/VHrMrPcsAlLizL5fv76RF+5EU+n7Rru934Toz9tx7XoOPOJe5U2vwjB7e9wjWe6UbBDGGgYS2nlwIDAQABo0IwQDAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjAdBgNVHQ4EFgQU+/JWjzqgU6uCGfuni6BPzLmfXbYwDQYJKoZIhvcNAQELBQADggEBAFMJ0WIgvfvn8+Q7hQnhshPbiK7dpz6qDqdcTTqjW6RjYI45rnxhY8Ju4vDQjx8QeEvV8eEKMN2XdCbAy12/6eHgfXPPc37WkMDTrQmVjU8yi4DdRiJDG3pCboRp61TpPgiCGLkYPiLfDHZhgmsAHIlkryb4OXNaP/jEAD1D/URJ8AE3Gvemad+aBDp95xfVfDEUfruAIRFHNIQKxZ7mqH/6P9lgVYWV8+MkPlOKuPLtKwoqwDXwUjP96qgTB76ZJR7/zsS+aR6fGC5OUfz2ci2T2gsXp4oAr2AQNriv/j4qE591dAtMaxrcCMhyVsj7i7Z3+/ubn+UmIarCrh9CgkI="
    static let intRSA2047 = "MIIDGzCCAgOgAwIBAgIUDIi2slK8uXZAFCiBottEFTk/LMswDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcm9vdFJTQTIwNDgwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAVMRMwEQYDVQQDDAppbnRSU0EyMDQ3MIIBITANBgkqhkiG9w0BAQEFAAOCAQ4AMIIBCQKCAQBj/zYBrSXkKtzbJnDw3wJ8HkeJI5XXNgDUATsxSkBGig2DRzLDBfAqCBQnOWhzPsJuyi7eaVZMe4PIsRpTFf6Oi7q4NfporzPPmREl5fV4GDVlX+rJs0YgtLWDj56ObksD/XlHUrVDiHl9xEAPN6KcZLseDp4X/6rdD9yNayWAl3dqUdyNT7sxDZwrFLbjBnlZQe61D/thJJc/3KSuQYU8s5VSfhI/zrgmHMNMcfc+g1j/ZxEL8I/CtifQUcw+V9lT1Q+oqR1zNkwnBnMnTErn4o7X3amMtwU442YKG/jtSpA6Ra7poYNdMhO/WOhQBeZEoyy+UDn8OIoYgxIGBhsVAgMBAAGjYzBhMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBTsVtpqToP8nwtTvngoeqPAA+kDFTAfBgNVHSMEGDAWgBQWe+pa6JCFOM/wcSlBHxFTPf9lHDANBgkqhkiG9w0BAQsFAAOCAQEAWvgJCCFs7JgmY7R6+x/XucDDSUuEUpOzDSjh+pKTurkjCXENJKhGTqIe431ORFy8RRtidk3dwHu2VK0NaYxR8awlDmXqSVBTHtReLVYb7IzuOrUFK59Eeg8j0bsDmW2eQc49t4bDaRxzOSDg877qZzVrtg1f34llhZOTQN3hyQ6+j7xGEyjRb57cVuq1Rl/cznjQlQlD2yjMpQ1zVyNyL0eUMceFGYfgfz1RWEAg99nabSevzyOcn87fBuJ1rvHrUAklHvLxqTfHbQ/fenyQaz9fEQWSLLHtUtNGtLcjRinK0isnXjCtccO6KfgTbqNHCK6VDpdzsApqkbSxWaDe8g=="
    static let rootP256 = "MIIBajCCARCgAwIBAgIUaynHkvgsde6/jHKMta/LzhfS+gYwCgYIKoZIzj0EAwIwEzERMA8GA1UEAwwIcm9vdFAyNTYwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjATMREwDwYDVQQDDAhyb290UDI1NjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABOa/VM/HF2KnQW2dbds6vVMG9vP2dWb3NeKicDbTl+kIACKe5yRQpsGRobIvxDBKAeI06l6yfD8SyadKXcxEtf6jQjBAMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMB0GA1UdDgQWBBSwsTeQbLK0qfskhDEIM9coxAdSWzAKBggqhkjOPQQDAgNIADBFAiEAsFuUXtbmTc8FlCQ+6dN6HaCP5M8CoTkqrxKOVlFzJvUCIDwafBwWoxJUi5SKOshu28NX6CBh5DGd+/Asakg43KiR"
    static let leafRSA2048 = "MIIDRzCCAi+gAwIBAgIUEfyadS/cm2tVu11vUofMtqmF9OgwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcm9vdFJTQTIwNDgwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAVMRMwEQYDVQQDDApyZWxheS50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2b20PANiQOqAuwtxPv+X+s0RbWSk5sGtdqW7YheGujPOFb7n+keEZLExAHh3xovUg95ZczAR4nig21MajsL8Cj8eST/3okg87+rYoG7l52kua9qY02IrBpi0PD0+XMuWLyUkv+0/M7LdaT8yBnuUkq2rMnuYiv5X4vDhuuUJItTZrGWaiRLuoeFa8r7QxLlYecf7jJ/U4IqG9rbx12n6nErfmuoGtmdBIjZa29wmxeTYSGXFNNUD0tqb4Zadfd7Z4uN+InN9GsLjLx02VBPKYweZR90EO0go77DXXM7sjXXVM4e5bWNjibrA4QsiRHLIZZRhPcu5EgmOVX3Yia7iZQIDAQABo4GNMIGKMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBUGA1UdEQQOMAyCCnJlbGF5LnRlc3QwHQYDVR0OBBYEFA6EfDcsN95L/FovbM3F8XZnEHodMB8GA1UdIwQYMBaAFBZ76lrokIU4z/BxKUEfEVM9/2UcMA0GCSqGSIb3DQEBCwUAA4IBAQA9X9FIwfmJ1M7dMN2SHX+P+K8di/dZIq4bw5QJvk03i6rSc3lMx6eEMuXutwmT/C28q89PwCW0IQX4VTvTOQ3/tsgfwKdRI239xq8fYiR2XN+V465LgKYhovTtGiFC6EkWu7I3plRfpmGB65YOQIYNzW/6mr+KY8owg//e44GEmXQyYuOQHAym7Z0PD9MRiJI3e8b6KcXFM+86BsjM8QHiD76Sw/tj5gAZ+Jhud1uNMR6ntWn1EbMnd0GFFRilPTyDfVctJzxrqggmsiLR+dxNQVjox+6rw2NSYXqrmIuU7nNPU8wkO4ENSlK1NAJ2zaRlOkNNHLVYV5sGfhrhJF8m"
    static let leafRSA2047 = "MIIDRjCCAi6gAwIBAgIUK21ZHrTp+0tYMC0yqb4NGJv0atYwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcm9vdFJTQTIwNDgwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAVMRMwEQYDVQQDDApyZWxheS50ZXN0MIIBITANBgkqhkiG9w0BAQEFAAOCAQ4AMIIBCQKCAQBjpoJh5idH3TY2FEc4hV8WXgELh32fyipBjUqiIWihNGuw4rLwwLQeHawSiyaoXigNmblaJlcpXC4cES79ALRB6r0NOu++MJLHkZEHYZKRbKUWSSQU89Vtl1FmKp4fwzas7pRt43BdwCbT1sbOF0TebX4nsWPCkXGX3TloUkR4g3Z+ph7v/ZLV/mp/7bji/e+NnG3/ciZmgdawN6wcPcKGJaLLs/IEHBjxl7F69nytM1Cdo0cO0+bOks2TPBq46bIit4Y1zRUphq7xO3sQAsAwSGujy+HfF90Q/XL9+j46kpR7btt2yKLjujYwxIBgXz3jwswXnDCagAWMyVZrLh8ZAgMBAAGjgY0wgYowDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwFQYDVR0RBA4wDIIKcmVsYXkudGVzdDAdBgNVHQ4EFgQUNrSfQaP+dp0BvO1q6JlLqKDKIjAwHwYDVR0jBBgwFoAUFnvqWuiQhTjP8HEpQR8RUz3/ZRwwDQYJKoZIhvcNAQELBQADggEBADszfYLKcmKiSzB+U2inwkt7xnKAniM6dsba3lHeLUMXpAXyi5IKBEHqPSUV7A3z8PjHkDZJtIpzymlykbkAY59Mwg3iNTEd202GlAcQTjmlutqths9r2n2o61WlPcem4hXPt1WGWKiJvjY3Go7ehOp41My/MLIQYAcT3WEFHpwPLEsYtoxIsxBR2gwqmYTDaJZ1DXCIKHq5iGIhMSj7CODtfq213tlaGViAH6PCUjnfV6ywU+H2JqZJCmrTaMU4BxNJRtsgA9WWKUj1D3eVg2FpeiipZVGflfxgAgyJRS5sBEeGJLLqM4/A0Qu0+yO1NM5ZOVrgV96hFdbD4ulGIw4="
    static let leafUnderWeakIntermediate = "MIIDRjCCAi6gAwIBAgIUKVNFrhRR35eRG95KTCXxh1EN380wDQYJKoZIhvcNAQELBQAwFTETMBEGA1UEAwwKaW50UlNBMjA0NzAeFw0yNjAxMDEwMDAwMDBaFw0yNjEyMzEwMDAwMDBaMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCJcLAqP0ORR6V1wyX4o8PEnnHFa+VdNEPq14YaAzaM70LcxzCQGV4M+GGCBWGB8da3mHuOK6XHaJnNJOgUorSqHCTbxXtD8VoauS4wQkkv9v5HiiIujNC8zpwF/P9/L2d9FwbgCVWvayJlkycF76vqBTj4GXt+/qfzOHA1p+rsctvWVPR17B2UsIHS/r879CGsDhQdlafh7MYk2oNXLEalqXBf8aLbyNyF6mjrBWMzbVR2KectNneeluoz1s/dvJai9tm/JCnhCPmfNxwmaxeyssYbH+sbW9GEzf1CUyMebAeux4//+Y4+0U2WPCrx+8OO9ArUQpJuPH7G8oazZ34VAgMBAAGjgY0wgYowDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCBaAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwFQYDVR0RBA4wDIIKcmVsYXkudGVzdDAdBgNVHQ4EFgQU4q5UEkzwcBme27+KYEZpCin5rPowHwYDVR0jBBgwFoAU7Fbaak6D/J8LU754KHqjwAPpAxUwDQYJKoZIhvcNAQELBQADggEBACZBDowhTIrP7kZjxd/R+vDtiQQSb6kwI2fhHxq7ln63KNOWpWM9bY1Y6ahMwTAQGD/NTmAqt6ttw7eZxf6sREd5BT8dqy4n4v/owoWksCD4tsiMDoTPQJs57IndmEWvDGdovIaibhjbQVss+3Afi6+wTLzlU2BeDqtBqkMpFruFommoU9KBAHdOqzIaMRPtR+P4usXYzJlPqz+iHmNw4UXEbgsnWsFGRPy0FBNYuHPYZgf23vSwe1wY5/HW1T1odLfU6wblH5zJzdL+2b6O06OFOfFtPCzrUP7rEi8Pz13dW7Rsbq6XyO1EKro1OoA0qfnPwl3FCxa57ep8loOTMqo="
    static let leafUnderWeakRoot = "MIIDRzCCAi+gAwIBAgIUCtnLid13A8bBCzevCOnp1+mJ6JowDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLcm9vdFJTQTIwNDcwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAVMRMwEQYDVQQDDApyZWxheS50ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsYKKbQChY6QfMnTous6eH1dgGGgm529v72oEPXJ31Z3FFDq/RHqS4iLR5aQEpLkNWF//DIEy/8ThF8qvS+ORYC9TPWI1Lm1YYXCK4TY2Ej8337XUlQ3jkfSVSyjmHnrL2k6P0lpwNCNRTChAOhC5z8lCbGHVyIR1twwIwPuKiW0h3nLOoZmSQIMgYeEZDhR/i/Pg4SMPQnyUP7tKz/gMPuy9IBXg3yzYbRr2Y1NhUFXAXYGcHEtuqmCrVpF2dYks5xnnl7YeQnFgg4ReCUqO/QXLyptXX9GzUHP7Sf5vfK/IgVi1zTeyFUbFnqv7zAycFCng4XBYpepfJcjG8K3MnwIDAQABo4GNMIGKMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBUGA1UdEQQOMAyCCnJlbGF5LnRlc3QwHQYDVR0OBBYEFLxL7/t8xCYjQpFNdmzS+0CAa92kMB8GA1UdIwQYMBaAFPvyVo86oFOrghn7p4ugT8y5n122MA0GCSqGSIb3DQEBCwUAA4IBAQA97in9bp+jsZ1Ns/MiRU/WmQ4zR7tlh40r1Ed2iVdDVq3HhRr87b2pKPX9nTAW3ZMNUWw9knEcA72+mXz0DYQKC4yj092jeQXXLf73i788M4hTOZEwpfDAZov0YedHec+oAAJ+7e+/SlqHqcKpIlza4hQWULdo7Ans9LaAeoKsb887J+0u4VGl1MrVWa65RUZKLj+/Spk9SP6f0ObKuoEGMW4SaLfnM3sU9By10gQrilvTaStPuc2oDRdVh8szy4eHKD/ik1OTb09obh5290S/+yHnL3vechfQWDGauRTZSeH88YhQkPr/AuYrLek0+/bgyBB9eIMNnX8oazUwRcRR"
    static let leafP256 = "MIIBtzCCAV6gAwIBAgIUVHudCZl/5ZKJCk2RGLIGGUxgBlQwCgYIKoZIzj0EAwIwEzERMA8GA1UEAwwIcm9vdFAyNTYwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAVMRMwEQYDVQQDDApyZWxheS50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZXx5vfrZ2URvojpjjnbJcGG4q92ETvEMNuH6x8TrX8KfYl1feKPIBH8legUDrTftrUfefLsVCif6LXXC5r34yKOBjTCBijAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIFoDATBgNVHSUEDDAKBggrBgEFBQcDATAVBgNVHREEDjAMggpyZWxheS50ZXN0MB0GA1UdDgQWBBR1OuPLsQn+J6jBXnKTS+9Dk0njczAfBgNVHSMEGDAWgBSwsTeQbLK0qfskhDEIM9coxAdSWzAKBggqhkjOPQQDAgNHADBEAiBBHoPX36Dg+rD3SWpLDXp85LvufC2SLdd1cMOPMcerQAIgPjXW2tKuLuHpZZbKP1lLbbRIA9SFfclk0vkrdum0iSw="
    static let leafP384 = "MIIB1jCCAXugAwIBAgIUaO0eycbgehs8yEEqdnqatm70mwcwCgYIKoZIzj0EAwIwEzERMA8GA1UEAwwIcm9vdFAyNTYwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAVMRMwEQYDVQQDDApyZWxheS50ZXN0MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEyJcJbJRXg/5akJbsPB8jXt8kgnz7gLearmTJ7YOs2QKeC9/0v3nL5JEI7tCoIjv8GnAteNG+YeZ90bH0XCRLAvJDQyD9hDGSdbrpryUToCQrLJFrs6Rn58gBE+34VfIVo4GNMIGKMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgWgMBMGA1UdJQQMMAoGCCsGAQUFBwMBMBUGA1UdEQQOMAyCCnJlbGF5LnRlc3QwHQYDVR0OBBYEFP9RzEtdNErfjiER/3FRV0rQ9OvWMB8GA1UdIwQYMBaAFLCxN5BssrSp+ySEMQgz1yjEB1JbMAoGCCqGSM49BAMCA0kAMEYCIQCwlQ+K1dnVlWn9vwTLtWGPJ3n1XFEQoHOSkNpV85CdAgIhAM/aqRYwP25emWo7/OPiFs2+3lfQgE7oi4EhDYvqTwjh"
    static let leafEd25519 = "MIIBVjCCAQigAwIBAgIUTgn2sB7Oym9Ko+TytJYZ8FAsVRwwBQYDK2VwMBUxEzARBgNVBAMMCnJlbGF5LnRlc3QwHhcNMjYwMTAxMDAwMDAwWhcNMjYxMjMxMDAwMDAwWjAVMRMwEQYDVQQDDApyZWxheS50ZXN0MCowBQYDK2VwAyEAu+grXhVuJEPs0wA2+m1ukcD2xVL5cZ2JaOF1PjPE0hujajBoMB0GA1UdDgQWBBSiSpwnxfnD5i7JaEgumPh/lYXpgDAfBgNVHSMEGDAWgBSiSpwnxfnD5i7JaEgumPh/lYXpgDAPBgNVHRMBAf8EBTADAQH/MBUGA1UdEQQOMAyCCnJlbGF5LnRlc3QwBQYDK2VwA0EAK24VhfHTpy/V9yV8zyeMCTZmlbcQcVcAZL+QlCYzJKMXaET9UkWmLpAa/8IPMuuOgZKXRIf1+i0uiL88PxZHAQ=="
}

private func certificate(_ base64: String) throws -> SecCertificate {
    let data = try #require(Data(base64Encoded: base64))
    return try #require(SecCertificateCreateWithData(nil, data as CFData))
}

/// SSL trust for `host` over `chain` (leaf first), anchored only at
/// `anchors`, evaluated on 2026-05-28 with no network fetches.
private func serverTrust(_ chain: [String], anchors: [String], host: String = "relay.test") throws -> SecTrust {
    var made: SecTrust?
    let status = SecTrustCreateWithCertificates(
        try chain.map(certificate) as CFArray,
        SecPolicyCreateSSL(true, host as CFString),
        &made
    )
    try #require(status == errSecSuccess)
    let trust = try #require(made)
    SecTrustSetAnchorCertificates(trust, try anchors.map(certificate) as CFArray)
    SecTrustSetAnchorCertificatesOnly(trust, true)
    SecTrustSetVerifyDate(trust, Date(timeIntervalSince1970: 1_780_000_000) as CFDate)
    SecTrustSetNetworkFetchAllowed(trust, false)
    return trust
}

@Suite struct TransportKeyFloorTests {
    @Test func strongChainsAreAccepted() throws {
        let rsa = try serverTrust([TLSFixture.leafRSA2048], anchors: [TLSFixture.rootRSA2048])
        let p256 = try serverTrust([TLSFixture.leafP256], anchors: [TLSFixture.rootP256])
        let p384 = try serverTrust([TLSFixture.leafP384], anchors: [TLSFixture.rootP256])
        #expect(PinnedSessionDelegate.acceptsServerTrust(rsa))
        #expect(PinnedSessionDelegate.acceptsServerTrust(p256))
        #expect(PinnedSessionDelegate.acceptsServerTrust(p384))
    }

    /// The defect the floor exists for: system trust alone accepts a 2047-bit
    /// RSA leaf. The control is asserted, so if the platform ever starts
    /// refusing it this test says so instead of passing for the wrong reason.
    @Test func systemTrustAloneAcceptsA2047BitLeafAndTheFloorRefusesIt() throws {
        let control = try serverTrust([TLSFixture.leafRSA2047], anchors: [TLSFixture.rootRSA2048])
        #expect(SecTrustEvaluateWithError(control, nil))
        let trust = try serverTrust([TLSFixture.leafRSA2047], anchors: [TLSFixture.rootRSA2048])
        #expect(!PinnedSessionDelegate.acceptsServerTrust(trust))
    }

    /// The whole evaluated chain is held to the floor, the anchor included.
    @Test func aShortIntermediateOrAnchorIsRefused() throws {
        let cases: [(name: String, chain: [String], anchor: String)] = [
            ("intermediate2047", [TLSFixture.leafUnderWeakIntermediate, TLSFixture.intRSA2047], TLSFixture.rootRSA2048),
            ("root2047", [TLSFixture.leafUnderWeakRoot], TLSFixture.rootRSA2047),
        ]
        for item in cases {
            let control = try serverTrust(item.chain, anchors: [item.anchor])
            // Recorded for docs/STRONG-CRYPTO.md, not asserted: the floor
            // must refuse whatever the platform decides.
            print("KYPOST_TLS_FLOOR case=\(item.name) systemTrust=\(SecTrustEvaluateWithError(control, nil))")
            let trust = try serverTrust(item.chain, anchors: [item.anchor])
            #expect(!PinnedSessionDelegate.acceptsServerTrust(trust), "\(item.name)")
        }
    }

    @Test func untrustedAndWrongHostChainsAreRefused() throws {
        let unanchored = try serverTrust([TLSFixture.leafRSA2048], anchors: [])
        let wrongHost = try serverTrust([TLSFixture.leafRSA2048], anchors: [TLSFixture.rootRSA2048], host: "other.test")
        #expect(!PinnedSessionDelegate.acceptsServerTrust(unanchored))
        #expect(!PinnedSessionDelegate.acceptsServerTrust(wrongHost))
    }

    /// Decided on the key's actual bits. RSA-2047 and RSA-2048 share a
    /// 256-byte block size, so the block size cannot implement the floor.
    @Test func eachCertificateKeyIsMeasured() throws {
        let expected: [(name: String, base64: String, strong: Bool)] = [
            ("rsa2048", TLSFixture.leafRSA2048, true),
            ("rsa2047", TLSFixture.leafRSA2047, false),
            ("p256", TLSFixture.leafP256, true),
            ("p384", TLSFixture.leafP384, true),
            ("ed25519", TLSFixture.leafEd25519, false),
        ]
        for item in expected {
            #expect(PinnedSessionDelegate.hasStrongKey(try certificate(item.base64)) == item.strong, "\(item.name)")
        }
        let short = try #require(SecCertificateCopyKey(try certificate(TLSFixture.leafRSA2047)))
        #expect(SecKeyGetBlockSize(short) == 256)
    }

    // MARK: - The delegate applies it

    /// A server-trust challenge as URLSession delivers one. The protection
    /// space is subclassed only to carry a SecTrust built from fixtures.
    private nonisolated final class TrustSpace: URLProtectionSpace, @unchecked Sendable {
        private let trust: SecTrust

        init(trust: SecTrust) {
            self.trust = trust
            super.init(
                host: "relay.test",
                port: 443,
                protocol: NSURLProtectionSpaceHTTPS,
                realm: nil,
                authenticationMethod: NSURLAuthenticationMethodServerTrust
            )
        }

        required init?(coder: NSCoder) { fatalError("not decoded") }

        override var serverTrust: SecTrust? { trust }
    }

    private nonisolated final class IgnoredSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func disposition(
        of delegate: PinnedSessionDelegate,
        for trust: SecTrust
    ) -> URLSession.AuthChallengeDisposition? {
        let challenge = URLAuthenticationChallenge(
            protectionSpace: TrustSpace(trust: trust),
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: IgnoredSender()
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var result: URLSession.AuthChallengeDisposition?
        delegate.urlSession(session, didReceive: challenge) { answer, _ in result = answer }
        return result
    }

    /// Before the floor this delegate answered `.performDefaultHandling` for
    /// both, and the 2047-bit chain connected.
    @Test func theDelegateRefusesAShortChainAndUsesAStrongOne() throws {
        let delegate = PinnedSessionDelegate { _ in nil }
        let request = URLRequest(url: URL(string: "https://relay.test/api/inbox")!)

        let short = try serverTrust([TLSFixture.leafRSA2047], anchors: [TLSFixture.rootRSA2048])
        #expect(disposition(of: delegate, for: short) == .cancelAuthenticationChallenge)
        #expect(delegate.pinFailure(forHost: "relay.test") == .untrusted)
        #expect(delegate.mapPinFailure(request, URLError(.cancelled)) as? NetworkError == .certificateRefused)

        let strong = try serverTrust([TLSFixture.leafRSA2048], anchors: [TLSFixture.rootRSA2048])
        #expect(disposition(of: delegate, for: strong) == .useCredential)
        #expect(delegate.pinFailure(forHost: "relay.test") == nil)
    }

    @Test func relaySessionsRequireTLS12OrLater() {
        #expect(PinnedSessionDelegate.relaySessionConfiguration().tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    /// No App Transport Security exception, so ATS's TLS 1.2 and
    /// forward-secret cipher requirements stay on for every URLSession.
    @Test func theAppDeclaresNoTransportSecurityException() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") == nil)
    }
}
