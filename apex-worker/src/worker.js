/**
 * ouro.bot apex Worker.
 *
 * Single job: make `https://ouro.bot/workbench-install.sh` serve the Workbench
 * one-line installer, mirroring the canonical copy hosted on Cloudflare Pages
 * (ouro-workbench-install.pages.dev, also reachable at install.ouro.bot).
 *
 * Every other apex path keeps the pre-existing behavior: a 302 to
 * https://ouroboros.bot/ — the same forward the Porkbun URL-forward used to do.
 * The Worker owns the apex end-to-end so it never depends on the apex origin
 * (the Porkbun CNAME) being reachable once the record is proxied.
 *
 * Source of truth for the script stays in ourostack/ouro-workbench:web/ →
 * the Pages project. This Worker only re-serves that file under the apex host.
 */

const INSTALL_PATH = "/workbench-install.sh";
const INSTALL_UPSTREAM =
  "https://ouro-workbench-install.pages.dev/workbench-install.sh";
const APEX_FORWARD = "https://ouroboros.bot/";

export default {
  async fetch(request) {
    const url = new URL(request.url);

    if (url.pathname === INSTALL_PATH) {
      const upstream = await fetch(INSTALL_UPSTREAM, {
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
