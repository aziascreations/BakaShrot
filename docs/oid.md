# The identity extension's OID

`IDENTITY_OID = 1.3.6.1.4.1.67681.1.1` (`crates/bakashrot-pki/src/lib.rs`).

## The branches

NibblePoker's Private Enterprise Number (PEN) is **67681**, from IANA
(in the registry, <https://www.iana.org/assignments/enterprise-numbers/>,
checked 2026-11-16). One number for NibblePoker as a whole: every project
gets its own branch under it, recorded here. A number once given is never
reused.

| OID | What |
|---|---|
| `1.3.6.1.4.1.67681` | NibblePoker |
| `1.3.6.1.4.1.67681.1` | BakaShrot |
| `1.3.6.1.4.1.67681.1.1` | BakaShrot's identity extension |

## Why it never changes

Servers find a certificate's name and roles by its identity extension's
OID. Changing the OID makes every certificate issued before unreadable as
a BakaShrot identity: all of them would have to be issued again. What's
inside the extension can still change (its `version` field) without
touching the OID.

Within a deployment, only the CA's certificates are read, so another
extension using the same OID somewhere else can't confuse a server. The OID
mostly needs to be stable, and properly ours.

## Changing the registration

The registry lists the organization, the contact's name and the contact's
email address. Changes (a new contact, an address) are asked for at
<https://pen.iana.org/pen/PenApplication.page> or iana-pen@iana.org, by
the contact.
