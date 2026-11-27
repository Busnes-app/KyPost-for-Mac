package pqc

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"os"
	"testing"

	pgparmor "github.com/ProtonMail/go-crypto/openpgp/armor"
	"github.com/ProtonMail/go-crypto/openpgp/packet"
	"github.com/ProtonMail/gopenpgp/v3/crypto"
)

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestEnrollmentServerAndBrowserVectors(t *testing.T) {
	for _, name := range []string{"device-envelope-xwing.json", "device-envelope-xwing-browser.json"} {
		t.Run(name, func(t *testing.T) {
			var v struct {
				Seed, PublicKey, DeviceID, Fingerprint, Plaintext string
				Envelope                                          struct {
					V            int
					Alg, Enc, Ct string
				}
			}
			if err := json.Unmarshal(fixture(t, "device-envelope-xwing.json"), &v); err != nil {
				t.Fatal(err)
			}
			if name == "device-envelope-xwing-browser.json" {
				if err := json.Unmarshal(fixture(t, name), &v.Envelope); err != nil {
					t.Fatal(err)
				}
			}
			decode := func(s string) []byte {
				b, err := base64.StdEncoding.DecodeString(s)
				if err != nil {
					t.Fatal(err)
				}
				return b
			}
			seed, pub := decode(v.Seed), decode(v.PublicKey)
			got, err := PublicKey(bytes.Clone(seed))
			if err != nil || !bytes.Equal(got, pub) || !ValidatePublicKey(pub) {
				t.Fatalf("public key: %v", err)
			}
			info := []byte("kypost-device-envelope/v6")
			for _, field := range []string{v.DeviceID, v.Fingerprint} {
				info = binary.BigEndian.AppendUint16(info, uint16(len(field)))
				info = append(info, field...)
			}
			sealed := append([]byte{1}, decode(v.Envelope.Enc)...)
			sealed = append(sealed, decode(v.Envelope.Ct)...)
			plain, err := Open(bytes.Clone(seed), info, sealed)
			if err != nil || string(plain) != v.Plaintext {
				t.Fatalf("vector open: %v", err)
			}
			for _, offset := range []int{0, 1, 1120, len(sealed) - 1} {
				tampered := bytes.Clone(sealed)
				tampered[offset] ^= 1
				if _, err := Open(bytes.Clone(seed), info, tampered); err == nil {
					t.Fatalf("accepted altered byte %d", offset)
				}
			}
			if _, err := Open(bytes.Clone(seed), append(bytes.Clone(info), 'x'), sealed); err == nil {
				t.Fatal("accepted wrong binding")
			}
			roundtrip, err := Seal(pub, info, []byte(v.Plaintext))
			if err != nil {
				t.Fatal(err)
			}
			if plain, err = Open(bytes.Clone(seed), info, roundtrip); err != nil || string(plain) != v.Plaintext {
				t.Fatalf("roundtrip: %v", err)
			}
		})
	}
}

func TestRFC9980ReadsAndCompositeVerification(t *testing.T) {
	for _, name := range []string{"v4", "v4-pqc", "v6-pqc"} {
		t.Run(name, func(t *testing.T) {
			key, err := crypto.NewKeyFromArmored(string(fixture(t, "openpgp-v6/"+name+".sec.asc")))
			if err != nil {
				t.Fatal(err)
			}
			defer key.ClearPrivateParams()
			h, err := crypto.PGP().Decryption().DecryptionKey(key).MaxDecompressedMessageSize(32 * 1024 * 1024).New()
			if err != nil {
				t.Fatal(err)
			}
			defer h.ClearPrivateParams()
			result, err := h.Decrypt(fixture(t, "openpgp-v6/"+name+".msg.asc"), crypto.Armor)
			if err != nil || !bytes.Equal(result.Bytes(), fixture(t, "openpgp-v6/message.txt")) {
				t.Fatalf("decrypt: %v", err)
			}
			// Every fixture secret key must be importable, including ID 35 and v6 S2K.
			if _, err := InspectPrivateKeyJSON(fixture(t, "openpgp-v6/"+name+".sec.asc")); err != nil {
				t.Fatal(err)
			}
		})
	}
	pub, err := crypto.NewKeyFromArmored(string(fixture(t, "openpgp-v6/v6-pqc.pub.asc")))
	if err != nil {
		t.Fatal(err)
	}
	verifier, err := crypto.PGP().Verify().VerificationKey(pub).New()
	if err != nil {
		t.Fatal(err)
	}
	for _, changed := range []bool{false, true} {
		msg := fixture(t, "openpgp-v6/message.txt")
		if changed {
			msg[0] ^= 1
		}
		result, err := verifier.VerifyDetached(msg, fixture(t, "openpgp-v6/v6-pqc.sig.asc"), crypto.Armor)
		if err != nil {
			t.Fatal(err)
		}
		if valid := result.SignatureError() == nil; valid == changed {
			t.Fatalf("composite verification changed=%v valid=%v", changed, valid)
		}
	}
	for _, name := range []string{"v4", "v6", "v6-pqc"} {
		addresses, err := UserIDAddressesJSON(string(fixture(t, "openpgp-v6/"+name+".pub.asc")), 1795651200)
		if err != nil || string(addresses) == "[]" {
			t.Fatalf("%s identities %s: %v", name, addresses, err)
		}
	}
}

func TestXWingBoundary(t *testing.T) {
	seed, err := GenerateSeed()
	if err != nil {
		t.Fatal(err)
	}
	pub, err := PublicKey(bytes.Clone(seed))
	if err != nil {
		t.Fatal(err)
	}
	if len(seed) != 32 || len(pub) != 1216 {
		t.Fatal("key sizes")
	}
	if ValidatePublicKey(bytes.Repeat([]byte{255}, 1216)) {
		t.Fatal("invalid ML-KEM key accepted")
	}
	if _, err := PublicKey(make([]byte, 31)); err == nil {
		t.Fatal("short seed")
	}
	if _, err := Seal(pub[:1215], []byte("test"), []byte("payload")); err == nil {
		t.Fatal("short public key")
	}
}

func TestV6UserIDCannotBorrowAnotherCertification(t *testing.T) {
	for _, name := range []string{"v6", "v6-pqc"} {
		t.Run(name, func(t *testing.T) {
			key, err := crypto.NewKeyFromArmored(string(fixture(t, "openpgp-v6/"+name+".pub.asc")))
			if err != nil {
				t.Fatal(err)
			}
			entity := key.GetEntity()
			for _, identity := range entity.Identities {
				forged := *identity
				forged.UserId = packet.NewUserId("Mallory", "", "mallory@example.invalid")
				forged.Name = forged.UserId.Id
				entity.Identities[forged.Name] = &forged
				break
			}
			armor, err := key.Armor()
			if err != nil {
				t.Fatal(err)
			}
			addresses, err := UserIDAddressesJSON(armor, 1795651200)
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Contains(addresses, []byte("mallory")) || string(addresses) == "[]" {
				t.Fatalf("bad identity result: %s", addresses)
			}
		})
	}
}

func TestBridgeNeverMutatesCallerBuffers(t *testing.T) {
	seed, err := GenerateSeed()
	if err != nil {
		t.Fatal(err)
	}
	original := bytes.Clone(seed)
	pub, err := PublicKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	msg := []byte("caller-owned secret")
	sealed, err := Seal(pub, []byte("test"), msg)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(seed, original) || string(msg) != "caller-owned secret" {
		t.Fatal("mutated caller data")
	}
	if _, err := Open(seed, []byte("test"), sealed); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(seed, original) {
		t.Fatal("open mutated caller seed")
	}
	armor := fixture(t, "openpgp-v6/v6-pqc.sec.asc")
	before := bytes.Clone(armor)
	if _, err := InspectPrivateKeyJSON(armor); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before, armor) {
		t.Fatal("inspection mutated caller key")
	}
}

func TestBothCompositeSignatureComponentsAreRequired(t *testing.T) {
	key, err := crypto.NewKeyFromArmored(string(fixture(t, "openpgp-v6/v6-pqc.pub.asc")))
	if err != nil {
		t.Fatal(err)
	}
	verifier, err := crypto.PGP().Verify().VerificationKey(key).New()
	if err != nil {
		t.Fatal(err)
	}
	for _, component := range []string{"ed25519", "mldsa65"} {
		t.Run(component, func(t *testing.T) {
			block, err := pgparmor.Decode(bytes.NewReader(fixture(t, "openpgp-v6/v6-pqc.sig.asc")))
			if err != nil {
				t.Fatal(err)
			}
			p, err := packet.Read(block.Body)
			if err != nil {
				t.Fatal(err)
			}
			signature := p.(*packet.Signature)
			if len(signature.EdSig) == 0 || len(signature.MldsaSig) == 0 {
				t.Fatal("not a composite fixture")
			}
			if component == "ed25519" {
				signature.EdSig[0] ^= 1
			} else {
				signature.MldsaSig[0] ^= 1
			}
			var altered bytes.Buffer
			if err := signature.Serialize(&altered); err != nil {
				t.Fatal(err)
			}
			result, err := verifier.VerifyDetached(fixture(t, "openpgp-v6/message.txt"), altered.Bytes(), crypto.Bytes)
			if err == nil && result.SignatureError() == nil {
				t.Fatal("accepted altered " + component)
			}
		})
	}
}
