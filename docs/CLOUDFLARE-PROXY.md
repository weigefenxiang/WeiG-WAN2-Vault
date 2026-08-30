# Cloudflare Proxy + Nginx

This mode is useful when the VPS already exposes TCP/443 through Nginx and routes TLS by SNI.

The Vault application itself remains localhost-only on:

```text
127.0.0.1:29444
```

## Example flow

```text
Browser/OpenWrt
  -> Cloudflare HTTPS
  -> VPS :443
  -> nginx stream ssl_preread
  -> 127.0.0.1:<local TLS port>
  -> nginx http reverse proxy
  -> 127.0.0.1:29444
```

Example stream entry:

```nginx
map $ssl_preread_server_name $backend {
    notify.example.com notify_backend;
    default other_backend;
}

upstream notify_backend {
    server 127.0.0.1:29445;
}
```

Example local TLS virtual host:

```nginx
server {
    listen 127.0.0.1:29445 ssl;
    server_name notify.example.com;

    ssl_certificate     /etc/nginx/ssl/example/origin.crt;
    ssl_certificate_key /etc/nginx/ssl/example/origin.key;

    location / {
        proxy_pass http://127.0.0.1:29444;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Nginx forwards original request headers by default, so Cloudflare's `CF-Connecting-IP` is preserved unless the configuration explicitly removes or overwrites it.

Recommended Cloudflare SSL mode:

```text
Full (strict)
```

Use an Origin CA certificate matching the public hostname.

Do not expose port 29444 publicly.
