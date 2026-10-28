# OpenSSH private key test fixtures

Throwaway keys generated with `ssh-keygen` for the private key import tests only.
They are not used by the app and protect nothing. Regenerate them with:

```sh
ssh-keygen -t ed25519 -N '' -C remora-test-unencrypted -f ed25519_unencrypted
ssh-keygen -t ed25519 -N 'remora-test-pass' -C remora-test-encrypted -f ed25519_aes256ctr
ssh-keygen -t ed25519 -N 'remora-test-pass' -Z aes128-ctr -C remora-test-enc128 -f ed25519_aes128ctr
ssh-keygen -t ed25519 -N 'remora-test-pass' -Z aes192-ctr -C remora-test-enc192 -f ed25519_aes192ctr
ssh-keygen -t ed25519 -N 'remora-test-pass' -Z aes256-cbc -C remora-test-enc-cbc -f ed25519_aes256cbc
ssh-keygen -t ecdsa -b 256 -N '' -C remora-test-ecdsa -f ecdsa_openssh_unsupported
ssh-keygen -t ecdsa -b 256 -N 'remora-test-pass' -C remora-test-ecdsa-enc -f ecdsa_openssh_encrypted
```
