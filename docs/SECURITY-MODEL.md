# Security Model

## Protected goals

The project is designed so that dynamic-IP reporting does not require:

- a residential HTTP server;
- a residential HTTPS server;
- a public DNS record pointing directly at the residential WAN IP;
- a public VPS listener on port 29444;
- an origin certificate specifically for the Vault backend.

## What the ISP can still know

The ISP assigning the WAN address necessarily knows that address. It may also observe connection metadata such as a subscriber IP communicating with Cloudflare infrastructure.

The project does not claim to hide the ISP-assigned address from the ISP itself.

## What Cloudflare can know

Cloudflare terminates the public HTTPS connection and handles the source IP as part of its proxy service. The application uses `CF-Connecting-IP` for update verification and browser rate limiting.

## Update authentication

An update requires:

```text
valid WRITE_TOKEN
+
posted IPv4 == CF-Connecting-IP
```

The POST request is forced through the chosen OpenWrt WAN interface.

## Browser authentication

Passwords are salted and hashed with scrypt. Browser sessions use random tokens, with only token hashes stored server-side.

## No WAN IP history

`/var/lib/wan2-vault/current.json` is atomically replaced on every accepted report. The project does not create a historical IP database.

System, Cloudflare, network-provider, or external infrastructure logs are outside that application-level guarantee.
