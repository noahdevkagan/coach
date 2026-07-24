/*
 * background.js — service worker.
 * Responsibilities:
 *   - Serve coupon codes per domain (seed DB + learned cache, failed codes pruned).
 *   - Record verified savings.
 *   - Compare an Amazon product against major retailers, shipping included.
 *
 * Price data: if the user adds a SerpAPI key in Options, we pull structured
 * Google Shopping results (price + shipping). Without a key we fall back to
 * per-retailer search links so the feature always works, just without live prices.
 */

const MAJOR_RETAILERS = [
  { name: "Walmart", host: "walmart.com", search: (q) => `https://www.walmart.com/search?q=${q}` },
  { name: "Target", host: "target.com", search: (q) => `https://www.target.com/s?searchTerm=${q}` },
  { name: "Best Buy", host: "bestbuy.com", search: (q) => `https://www.bestbuy.com/site/searchpage.jsp?st=${q}` },
  { name: "eBay", host: "ebay.com", search: (q) => `https://www.ebay.com/sch/i.html?_nkw=${q}` },
  { name: "Newegg", host: "newegg.com", search: (q) => `https://www.newegg.com/p/pl?d=${q}` }
];

// ---------- coupon store ----------

let seedCache = null;
async function loadSeed() {
  if (seedCache) return seedCache;
  try {
    const res = await fetch(chrome.runtime.getURL("data/coupons.json"));
    seedCache = (await res.json()).stores || {};
  } catch (e) {
    seedCache = {};
  }
  return seedCache;
}

async function getCouponsForDomain(domain) {
  const seed = await loadSeed();
  const store = await chrome.storage.local.get([`codes:${domain}`, `dead:${domain}`]);
  const learned = store[`codes:${domain}`] || [];
  const dead = new Set(store[`dead:${domain}`] || []);

  const merged = new Map();
  [...(seed[domain] || []), ...learned].forEach((c) => {
    const code = (c.code || "").trim().toUpperCase();
    if (code && !dead.has(code) && !merged.has(code)) {
      merged.set(code, { code, desc: c.desc || "" });
    }
  });
  return [...merged.values()];
}

async function recordVerified({ domain, code, saved }) {
  const key = `codes:${domain}`;
  const store = await chrome.storage.local.get([key, "savingsLog", "totalSaved"]);
  const list = store[key] || [];
  const up = code.toUpperCase();
  if (!list.some((c) => (c.code || "").toUpperCase() === up)) {
    list.push({ code: up, desc: "Verified working", verifiedAt: Date.now() });
  }
  const log = store.savingsLog || [];
  log.unshift({ domain, code: up, saved, at: Date.now() });
  const total = (store.totalSaved || 0) + (saved || 0);
  await chrome.storage.local.set({ [key]: list, savingsLog: log.slice(0, 100), totalSaved: total });
}

async function pruneDead({ domain, codes }) {
  const key = `dead:${domain}`;
  const store = await chrome.storage.local.get(key);
  const dead = new Set(store[key] || []);
  codes.forEach((c) => dead.add((c || "").toUpperCase()));
  await chrome.storage.local.set({ [key]: [...dead] });
}

// ---------- price comparison ----------

function buildQuery(product) {
  const bits = [product.brand, product.title, product.model]
    .filter(Boolean)
    .join(" ")
    .replace(/\s+/g, " ")
    .trim();
  // Trim overly long titles to the meaningful head.
  return bits.split(" ").slice(0, 12).join(" ");
}

function retailerFromHost(host) {
  const h = (host || "").toLowerCase();
  const match = MAJOR_RETAILERS.find((r) => h.includes(r.host));
  return match ? match.name : null;
}

// Structured results via SerpAPI Google Shopping (needs a user key).
async function serpApiCompare(query, apiKey) {
  const url = `https://serpapi.com/search.json?engine=google_shopping&q=${encodeURIComponent(
    query
  )}&api_key=${apiKey}`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`SerpAPI ${res.status}`);
  const data = await res.json();
  const items = data.shopping_results || [];
  const byRetailer = new Map();
  for (const it of items) {
    const retailer = retailerFromHost(it.source || it.link || "");
    if (!retailer) continue;
    const price = typeof it.extracted_price === "number" ? it.extracted_price : null;
    if (price == null) continue;
    // Parse shipping like "Free delivery" / "$5.99 shipping".
    let shipping = 0;
    if (it.shipping && /\d/.test(it.shipping)) {
      const m = it.shipping.replace(/[, ]/g, "").match(/(\d+(?:\.\d{1,2})?)/);
      shipping = m ? parseFloat(m[1]) : 0;
    }
    const total = price + shipping;
    const prev = byRetailer.get(retailer);
    if (!prev || total < prev.total) {
      byRetailer.set(retailer, {
        retailer,
        price,
        shipping,
        total,
        url: it.product_link || it.link
      });
    }
  }
  return byRetailer;
}

async function comparePrices(product) {
  const query = buildQuery(product);
  const q = encodeURIComponent(query);
  const cfg = await chrome.storage.sync.get({ serpApiKey: "", shippingEstimate: 0 });

  let priced = new Map();
  if (cfg.serpApiKey) {
    try {
      priced = await serpApiCompare(query, cfg.serpApiKey);
    } catch (e) {
      priced = new Map();
    }
  }

  // Every major retailer gets a row: live total if we have it, else a search link.
  return MAJOR_RETAILERS.map((r) => {
    const live = priced.get(r.name);
    if (live) return live;
    return {
      retailer: r.name,
      price: null,
      shipping: null,
      total: null,
      url: r.search(q),
      note: "search →"
    };
  });
}

// ---------- messaging ----------

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  (async () => {
    switch (msg.type) {
      case "GET_COUPONS": {
        const codes = await getCouponsForDomain(msg.domain);
        sendResponse({ codes });
        break;
      }
      case "COUPON_VERIFIED": {
        await recordVerified(msg);
        sendResponse({ ok: true });
        break;
      }
      case "COUPONS_FAILED": {
        await pruneDead(msg);
        sendResponse({ ok: true });
        break;
      }
      case "COMPARE_PRICES": {
        const results = await comparePrices(msg.product);
        sendResponse({ results });
        break;
      }
      case "GET_STATS": {
        const store = await chrome.storage.local.get({ totalSaved: 0, savingsLog: [] });
        sendResponse(store);
        break;
      }
      default:
        sendResponse({ ok: false, error: "unknown message" });
    }
  })();
  return true; // async response
});
