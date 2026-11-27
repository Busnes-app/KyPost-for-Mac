// Package pqc is the gomobile boundary for KyPost's X-Wing enrollment and
// packet-level checks absent from the upstream GopenPGP mobile API.
package pqc

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"time"

	"github.com/Busnes-app/ky-primitives/xwing"
	"github.com/ProtonMail/gopenpgp/v3/crypto"
)

// GenerateSeed returns a fresh X-Wing seed. The caller must protect it with
// ThisDeviceOnly user-presence Keychain access and wipe its byte buffer.
func GenerateSeed() ([]byte, error) {
	key, err := xwing.Generate()
	if err != nil {
		return nil, err
	}
	return key.Seed(), nil
}

func PublicKey(seed []byte) ([]byte, error) {
	seed = bytes.Clone(seed)
	defer clear(seed)
	key, err := xwing.FromSeed(seed)
	if err != nil {
		return nil, err
	}
	return key.Public().Bytes(), nil
}

func ValidatePublicKey(raw []byte) bool {
	_, err := xwing.ParsePublicKey(raw)
	return err == nil
}

// Seal returns the library framing 0x01 || enc(1120) || ct. info is the
// caller's domain-separated transcript; enrollment uses empty AEAD aad.
func Seal(publicKey, info, plaintext []byte) ([]byte, error) {
	plaintext = bytes.Clone(plaintext)
	defer clear(plaintext)
	key, err := xwing.ParsePublicKey(publicKey)
	if err != nil {
		return nil, err
	}
	return xwing.Seal(key, info, nil, plaintext)
}

func Open(seed, info, sealed []byte) ([]byte, error) {
	seed = bytes.Clone(seed)
	defer clear(seed)
	key, err := xwing.FromSeed(seed)
	if err != nil {
		return nil, err
	}
	return xwing.Open(key, info, nil, sealed)
}

// UserIDAddressesJSON verifies each identity's own self-certification. v6
// direct-key validity alone does not certify an appended User ID.
func UserIDAddressesJSON(armor string, unixTime int64) ([]byte, error) {
	key, err := crypto.NewKeyFromArmored(armor)
	if err != nil {
		return nil, err
	}
	entity := key.GetEntity()
	now := time.Unix(unixTime, 0)
	if _, err = entity.VerifyPrimaryKey(now, nil); err != nil {
		return []byte("[]"), nil
	}
	addresses := make([]string, 0, len(entity.Identities))
	for _, identity := range entity.Identities {
		if _, err = identity.Verify(now, nil); err == nil && identity.UserId != nil {
			addresses = append(addresses, identity.UserId.Email)
		}
	}
	sort.Strings(addresses)
	out, err := json.Marshal(addresses)
	return out, err
}

// InspectPrivateKeyJSON rejects protected, dummy and unbound subkeys before
// import. Swift additionally checks exact armor/packet framing and inventory.
func InspectPrivateKeyJSON(armor []byte) ([]byte, error) {
	armor = bytes.Clone(armor)
	defer clear(armor)
	key, err := crypto.NewKey(armor)
	if err != nil {
		return nil, err
	}
	defer key.ClearPrivateParams()
	entity := key.GetEntity()
	if entity.PrivateKey == nil || entity.PrivateKey.Encrypted || entity.PrivateKey.Dummy() {
		return nil, errors.New("unusable private key")
	}
	fp := func(raw []byte) string { return strings.ToUpper(hex.EncodeToString(raw)) }
	fingerprints := []string{fp(entity.PrimaryKey.Fingerprint)}
	for _, subkey := range entity.Subkeys {
		if subkey.PrivateKey == nil || subkey.PrivateKey.Encrypted || subkey.PrivateKey.Dummy() {
			return nil, errors.New("unusable private subkey")
		}
		if _, err = subkey.LatestValidBindingSignature(time.Time{}, nil); err != nil {
			return nil, err
		}
		fingerprints = append(fingerprints, fp(subkey.PublicKey.Fingerprint))
	}
	out, err := json.Marshal(struct {
		PrimaryFingerprint string   `json:"primaryFingerprint"`
		KeyFingerprints    []string `json:"keyFingerprints"`
	}{fingerprints[0], fingerprints})
	return out, err
}
