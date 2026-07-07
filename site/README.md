# mojopulse.io — marketing site

The static site for Mojo Pulse — hub + spokes, no build step, no framework,
no external requests. Shared stylesheet and script; each page is plain HTML.

```
site/
├── index.html          homepage (conversion hub)
├── style.css           shared styles — ALL pages link this
├── site.js             shared JS (version wiring, copy buttons, reveal, videos, lightbox)
├── tools/
│   ├── speed-test/index.html        ┐
│   ├── security/index.html          │ spoke pages: own <title>/meta/OG,
│   ├── bluetooth-sonar/index.html   │ SEO-targeted per tool
│   └── network-health/index.html    ┘
├── privacy/index.html  the whole privacy policy, plain English
├── sitemap.xml         list every page here when adding one
├── robots.txt
├── favicon.svg         shield + heartbeat mark
├── assets/
│   ├── icon.png / icon-512.png      app icon (og:image, apple-touch-icon)
│   └── shots/                       real screenshots (redacted) + video loops
├── deploy-ec2.sh       THE deploy script (rsync to the box)
├── deploy.sh           unused S3 variant, kept for reference
└── README.md           this file
```

**Adding a tool page:** copy an existing `tools/*/index.html`, keep the nav /
footer / pagecta blocks identical (they're duplicated by design — no build
step), write the content in `.prose`, add the URL to `sitemap.xml`, link its
card in the homepage tools wall (`<a class="tool" href="…">` + `<span
class="go">→</span>`), and redeploy.

**The version** lives in ONE place: `var V="…"` in `site.js` — it sets every
download link and version badge on every page.

## Preview locally

```sh
cd site && python3 -m http.server 4321
# open http://localhost:4321
```

## Recommended hosting: S3 + CloudFront (not EC2)

This is a static page. Don't run a server for it — an EC2 box means an OS to
patch, a web server to configure, and TLS to renew, all to serve one HTML file.
S3 + CloudFront is a few cents a month, fast worldwide, and gets HTTPS for free.

### One-time setup

1. **Bucket** — create an S3 bucket named `mojopulse.io` (private; keep "Block
   public access" ON — CloudFront reaches it via an Origin Access Control, so
   the bucket never needs to be public).

2. **TLS cert** — in **AWS Certificate Manager, `us-east-1`** (CloudFront only
   reads certs from us-east-1), request a public cert for `mojopulse.io` and
   `www.mojopulse.io`. Validate via DNS (add the CNAME it gives you).

3. **CloudFront distribution**
   - Origin: the S3 bucket, via **Origin Access Control** (let the console
     update the bucket policy for you).
   - Alternate domain names (CNAMEs): `mojopulse.io`, `www.mojopulse.io`.
   - Custom SSL cert: the ACM cert from step 2.
   - Default root object: `index.html`.
   - Redirect HTTP → HTTPS.
   - (Optional) A CloudFront Function to redirect `www` → apex.

4. **DNS** — point the domain at the distribution:
   - **Route 53**: an **A / AAAA alias** record for `mojopulse.io` → the
     CloudFront distribution (and one for `www`).
   - **Cloudflare**: a proxied **CNAME** for both apex and `www` →
     `dxxxx.cloudfront.net` (Cloudflare flattens the apex automatically).
   - **Registrar DNS (GoDaddy / Namecheap / etc.)** — the catch: a CNAME is
     illegal at the apex and most registrar panels have no ALIAS/ANAME record,
     so `mojopulse.io` → CloudFront can't be done directly. Two ways around it:
     1. Serve the site on **`www.mojopulse.io`** (CNAME → `dxxxx.cloudfront.net`)
        and use the registrar's **domain forwarding / URL redirect** to send the
        bare `mojopulse.io` → `https://www.mojopulse.io`.
     2. Or move *just the nameservers* to **Route 53** or **Cloudflare** (keep
        the domain at the registrar) to get a clean apex alias.
   - EC2 sidesteps this entirely: apex → a plain **A record → the box's IP**,
     which every registrar supports (see the nginx section below).

### Ship a change

```sh
export PULSE_SITE_BUCKET=mojopulse.io
export PULSE_SITE_CF_DIST=E123ABC...   # your distribution id
./deploy.sh
```

## EC2 + nginx — this is how it's deployed today

The site is live on the EC2 box that also serves mojopulse.io's other apps,
out of `/opt/www/pulse` (nginx vhost `conf.d/mojopulse.io.conf` + TLS already
configured). Redeploy is one command from your Mac:

```sh
cd site && ./deploy-ec2.sh
```

That rsyncs `site/` → `mojopulse.io:/opt/www/pulse` (writing via `sudo rsync`
since the dir is owned by `www`), fixes ownership, and curls the site to check
it's serving. Override the target with `PULSE_SITE_HOST` / `PULSE_SITE_DEST`.

<details><summary>First-time-on-a-fresh-box setup (vhost + cert)</summary>

```sh
sudo certbot --nginx -d mojopulse.io -d www.mojopulse.io   # TLS
```

nginx vhost (`/etc/nginx/conf.d/mojopulse.conf`):

```nginx
# bare + www → https
server {
    listen 80;
    server_name mojopulse.io www.mojopulse.io;
    return 301 https://mojopulse.io$request_uri;
}
# www → apex (canonical)
server {
    listen 443 ssl http2;
    server_name www.mojopulse.io;
    # ssl_certificate lines added by certbot
    return 301 https://mojopulse.io$request_uri;
}
server {
    listen 443 ssl http2;
    server_name mojopulse.io;
    root /opt/www/pulse;
    index index.html;
    # ssl_certificate lines added by certbot

    gzip on;
    gzip_types text/css application/javascript image/svg+xml;

    location /assets/ { expires 1d; add_header Cache-Control "public"; }
    location = /index.html { add_header Cache-Control "public, max-age=300"; }
    try_files $uri $uri/ =404;
}
```

**DNS at the registrar:** A record `mojopulse.io` → the EC2 IP (use an Elastic
IP so it never changes), and a CNAME `www` → `mojopulse.io`.

</details>

## Keeping it current

- **Version badge / download link** — the page links to
  `github.com/NativeMojo/mojo-pulse/releases/latest`, which always resolves to
  the newest DMG, so it doesn't need editing per release. The footer version
  badge (`v1.16.3`) is cosmetic; bump it when convenient.
- **Screenshots** — the hero uses a CSS-rendered popover mock (always current);
  the "A look inside" gallery uses real captures in `assets/shots/*.jpg`. To
  refresh: grab native window shots (⌘⇧5 → "Capture Selected Window") or a new
  screen recording, crop to each window, export ~q88 JPEGs into `assets/shots/`
  under the same filenames, and redeploy.
