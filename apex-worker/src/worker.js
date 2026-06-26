/**
 * ouro.bot apex Worker.
 *
 * Job: serve the Ouro one-line installers under the apex host —
 *   https://ouro.bot/workbench-install.sh  (Ouro Workbench)
 *   https://ouro.bot/ouro-md-install.sh     (Ouro MD)
 * — each mirroring its canonical source.
 *
 * Every other apex path keeps the pre-existing behavior: a 302 to
 * https://ouroboros.bot/ — the same forward the Porkbun URL-forward used to do.
 * The Worker owns the apex end-to-end so it never depends on the apex origin
 * (the Porkbun CNAME) being reachable once the record is proxied.
 *
 * Sources of truth stay in their product repos:
 *   workbench-install.sh -> ourostack/ouro-workbench:web/ (via GitHub raw on main)
 *   ouro-md-install.sh   -> ourostack/ouro-md:web/        (via GitHub raw on main)
 * This Worker only re-serves those files under the apex host.
 */

const INSTALL_UPSTREAMS = {
  "/workbench-install.sh":
    "https://raw.githubusercontent.com/ourostack/ouro-workbench/main/web/workbench-install.sh",
  "/ouro-md-install.sh":
    "https://raw.githubusercontent.com/ourostack/ouro-md/main/web/ouro-md-install.sh",
};
const APEX_FORWARD = "https://ouroboros.bot/";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    const upstreamURL = INSTALL_UPSTREAMS[url.pathname];
    if (upstreamURL) {
      const upstream = await fetch(upstreamURL, {
        cf: { cacheTtl: 300, cacheEverything: true },
      });
      const headers = new Headers(upstream.headers);
      headers.set("content-type", "application/x-sh; charset=utf-8");
      headers.set("cache-control", "public, max-age=300");
      return new Response(upstream.body, {
        status: upstream.status,
        statusText: upstream.statusText,
        headers,
      });
    }

    // Preserve the historical apex forward (path is intentionally dropped, as
    // the previous Porkbun URL-forward did).
    return Response.redirect(APEX_FORWARD, 302);
  },
};
