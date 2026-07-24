# SmartCart — Coupons & Amazon Price Compare

A Chrome extension (Manifest V3) that does two things:

1. **Finds and verifies coupons at checkout.** On cart/checkout pages it locates the
   promo-code field, pulls known codes for the store, then *live-tests* them — applying
   each one and watching the order total — and leaves the single code that actually
   drops your total the most. Codes that don't work are remembered and skipped next time.
2. **Compares Amazon prices with the rest of the web.** On an Amazon product page it
   scrapes the item and shows a side panel comparing the price against Walmart, Target,
   Best Buy, eBay, and Newegg — **including shipping** — and flags the cheapest total.

Everything runs locally. No account, no telemetry.

## Install (developer mode)

1. Open `chrome://extensions`
2. Toggle **Developer mode** (top-right)
3. Click **Load unpacked** and select this `chrome-extension/` folder
4. Pin the 🛒 SmartCart icon

## How it works

| Piece | File |
|---|---|
| Service worker (coupon store, price comparison, savings log) | `background.js` |
| Checkout detection heuristics | `content/store-detect.js` |
| Coupon finder + live verifier UI | `content/coupon.js` |
| Amazon scrape + comparison panel | `content/amazon.js` |
| Popup (toggles, total saved, recent wins) | `popup/` |
| Settings (SerpAPI key, shipping estimate) | `options/` |
| Seed coupon database | `data/coupons.json` |

### Coupon verification
Because every checkout is different, detection is heuristic: the content script scores
inputs/buttons/totals by their surrounding text. The verifier records the order total,
applies each candidate code, waits for the total to change, and keeps the best real
reduction. Verified codes are cached per-domain; dead codes are pruned.

### Price comparison & shipping
Out of the box the panel links you to each retailer's search for the scraped product.
Add a free/paid **[SerpAPI](https://serpapi.com/) key** in Settings to pull **live**
Google Shopping prices with shipping inline — then SmartCart ranks retailers by *total*
landed cost (item + shipping) and shows how much you'd save versus Amazon. Retailers
without a reported shipping cost use the fallback shipping estimate from Settings.

## Extending

- Add stores/codes to `data/coupons.json` (keyed by registrable domain), or point
  `loadSeed()` in `background.js` at a remote feed.
- Add retailers to `MAJOR_RETAILERS` in `background.js` (name, host, search-URL builder).

## Limitations (honest notes)

- Coupon detection won't fire on every checkout — heavily custom or iframe-based carts
  can hide the fields; the popup's **Scan this page** button forces a retry.
- Without a SerpAPI key, comparison rows are search links, not live prices — retailer
  sites block direct scraping, so a structured price API is the reliable path.
- Scraped Amazon prices skip tax/promotions that only appear at checkout.
