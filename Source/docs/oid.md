# The identity extension's OID

**Open point:** the OID is a placeholder until NibblePoker has its own
Private Enterprise Number (PEN) from IANA. The owner's to request
(below), then a few lines to change here.

## Why it matters

Servers find a certificate's name and roles by its identity extension's
OID (`bakashrot_pki::IDENTITY_OID`). Changing the OID makes every
certificate issued before unreadable as a BakaShrot identity: all of them
would have to be issued again. So it's settled before certificates are in
use; what's inside the extension can still change (its `version` field)
without touching the OID.

Within a deployment, only the CA's certificates are read, so another
extension using the same OID somewhere else can't confuse a server. The OID
mostly needs to be stable, and properly ours.

## Now: a placeholder

- `IDENTITY_OID = 1.3.6.1.4.1.32473.1.1`: under PEN 32473, "Example
  Enterprise Number for Documentation Use" (RFC 5612). It works, but isn't
  meant for real use, and examples elsewhere use it too.
- `IDENTITY_OID_IS_PLACEHOLDER = true`: `bakashrot-cert` warns whenever it
  makes a CA or issues a certificate.
- Fine for development and tests; not for certificates in use.
- `OldSource/`'s UUID arc (`2.25.2320...0981`) can't be used: `rcgen`
  writes OID parts of 64 bits at most, a UUID is 128.

## Requesting a PEN

From IANA's application page (checked 2026-11-13):

1. **Check first** that NibblePoker doesn't have one: search the registry,
   <https://www.iana.org/assignments/enterprise-numbers/> (it had none on
   2026-11-13). An organization that has one hands out sub-numbers under
   it instead of asking for another.
2. **Apply** at <https://pen.iana.org/pen/PenApplication.page>. It's free.
   It asks for:
   - the **assignee**, the organization (or person) the number is for:
     name ("NibblePoker"), address, country, phone (optional);
   - a **contact**, the person IANA and others write to with questions,
     who may also request changes later: name, address, country, phone and
     fax (optional), **email** (required).
3. **Confirm** the request from the email IANA sends to that address.
4. **Wait:** if nothing else is needed, the number comes within seven days
   of that confirmation. Questions: iana-pen@iana.org.

**What's public:** the registry lists, for every number, the organization,
the contact's name and the contact's email address (written with `&` for
`@`). Use an address meant to be published (a role address, not a
personal one).

Ask for one number for NibblePoker as a whole, not one per project: every
project gets its own branch under it.

## Once the number is there

With `<PEN>` the number IANA gave:

1. **Plan the branches**, and record them in the table below; a number
   once given is never reused:

   | OID | What |
   |---|---|
   | `1.3.6.1.4.1.<PEN>` | NibblePoker |
   | `1.3.6.1.4.1.<PEN>.1` | BakaShrot |
   | `1.3.6.1.4.1.<PEN>.1.1` | BakaShrot's identity extension |

2. **In `crates/bakashrot-pki/src/lib.rs`:** `IDENTITY_OID` to
   `[1, 3, 6, 1, 4, 1, <PEN>, 1, 1]`, `IDENTITY_OID_IS_PLACEHOLDER` to
   `false`.
3. **Update** this file (the table, "Now"), `certificates.md` and the open
   point in `../../revamp.md`.
4. **Issue again** any certificate made with the placeholder, and run
   `check.ps1` (the tests issue their own, nothing to change there).
