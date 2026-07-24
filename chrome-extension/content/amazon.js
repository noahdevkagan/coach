/*
 * amazon.js — on an Amazon product page, scrape the item + price, then ask the
 * background worker to compare against major retailers (with shipping factored in).
 */
(function () {
  "use strict";

  function text(sel) {
    const el = document.querySelector(sel);
    return el ? el.textContent.trim() : "";
  }

  function parsePrice(str) {
    if (!str) return null;
    const m = str.replace(/[, ]/g, "").match(/(\d+(?:\.\d{1,2})?)/);
    return m ? parseFloat(m[1]) : null;
  }

  // Pull the current product's title, price, model/brand from the DOM.
  function scrapeProduct() {
    const title = text("#productTitle");
    if (!title) return null;

    // Price shows up in several spots depending on the layout.
    let price =
      parsePrice(text(".a-price .a-offscreen")) ||
      parsePrice(text("#corePrice_feature_div .a-offscreen")) ||
      parsePrice(text("#priceblock_ourprice")) ||
      parsePrice(text("#priceblock_dealprice"));

    // Brand + model help build a tighter comparison query.
    let brand = text("#bylineInfo").replace(/^Visit the |^Brand: | Store$/g, "").trim();
    let model = "";
    document.querySelectorAll("#productDetails_techSpec_section_1 tr, .prodDetTable tr").forEach((tr) => {
      const k = (tr.querySelector("th, .prodDetSectionEntry") || {}).textContent || "";
      if (/model|part number|item model/i.test(k)) {
        model = (tr.querySelector("td") || {}).textContent || model;
      }
    });

    // ASIN for reference.
    const asin = (location.pathname.match(/\/(?:dp|gp\/product)\/([A-Z0-9]{10})/) || [])[1] || "";

    return {
      title: title.slice(0, 160),
      price,
      brand: brand.slice(0, 40),
      model: model.trim().slice(0, 40),
      asin,
      url: location.href
    };
  }

  function money(n) {
    return n == null ? "—" : "$" + Number(n).toFixed(2);
  }

  let panel;
  function ensurePanel() {
    if (panel) return panel;
    panel = document.createElement("div");
    panel.className = "smartcart-amz";
    panel.innerHTML = `
      <div class="sca-head">
        <span>🛒 SmartCart price check</span>
        <button class="sca-close" title="Hide">×</button>
      </div>
      <div class="sca-body"><div class="sca-loading">Comparing prices…</div></div>
      <div class="sca-foot">Totals include estimated shipping. Prices are best-effort — verify before buying.</div>`;
    document.documentElement.appendChild(panel);
    panel.querySelector(".sca-close").addEventListener("click", () => panel.remove());
    return panel;
  }

  function render(product, results) {
    const body = ensurePanel().querySelector(".sca-body");
    body.innerHTML = "";

    const amazonTotal = product.price;
    const rows = [
      { retailer: "Amazon", total: amazonTotal, price: amazonTotal, shipping: 0, url: product.url, self: true },
      ...results
    ].filter((r) => r);

    // Cheapest by total (item + shipping) wins the badge.
    const priced = rows.filter((r) => r.total != null);
    const cheapest = priced.length ? Math.min(...priced.map((r) => r.total)) : null;

    rows.forEach((r) => {
      const row = document.createElement("a");
      row.className = "sca-row" + (r.total != null && r.total === cheapest ? " sca-best" : "");
      row.href = r.url || "#";
      row.target = "_blank";
      row.rel = "noopener";
      const badge = r.total != null && r.total === cheapest ? '<span class="sca-badge">Best</span>' : "";
      const ship = r.shipping ? `+${money(r.shipping)} ship` : (r.total != null ? "free ship" : "");
      row.innerHTML = `
        <span class="sca-store">${r.retailer}${badge}</span>
        <span class="sca-price">${money(r.total)}</span>
        <span class="sca-ship">${r.total != null ? ship : (r.note || "search →")}</span>`;
      body.appendChild(row);
    });

    if (cheapest != null && amazonTotal != null && cheapest < amazonTotal) {
      const save = document.createElement("div");
      save.className = "sca-save";
      save.textContent = `You could save ${money(amazonTotal - cheapest)} buying elsewhere.`;
      body.prepend(save);
    }
  }

  async function run() {
    const settings = await chrome.storage.sync.get({ compareEnabled: true });
    if (!settings.compareEnabled) return;
    const product = scrapeProduct();
    if (!product) return;
    ensurePanel();
    chrome.runtime.sendMessage({ type: "COMPARE_PRICES", product }, (resp) => {
      if (chrome.runtime.lastError) {
        render(product, []);
        return;
      }
      render(product, (resp && resp.results) || []);
    });
  }

  // Amazon navigates client-side; watch for product changes.
  let lastAsin = "";
  function maybeRun() {
    const asin = (location.pathname.match(/\/(?:dp|gp\/product)\/([A-Z0-9]{10})/) || [])[1] || "";
    if (asin && asin !== lastAsin) {
      lastAsin = asin;
      if (panel) { panel.remove(); panel = null; }
      run();
    }
  }
  maybeRun();
  setInterval(maybeRun, 2000);
})();
