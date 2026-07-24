/*
 * store-detect.js — heuristics shared by the coupon content script.
 * Exposes window.SmartCartDetect with pure DOM helpers (no network, no state).
 * Every checkout is different, so these are best-effort scorers, not guarantees.
 */
(function () {
  "use strict";

  // Words that mark a promo-code text input.
  const PROMO_HINTS = [
    "promo", "coupon", "discount", "voucher", "gift code", "giftcard",
    "gift card", "offer code", "redeem", "reward code", "code"
  ];
  // Words that mark the running order total.
  const TOTAL_HINTS = [
    "order total", "grand total", "total", "amount due", "you pay",
    "estimated total", "subtotal"
  ];
  // Buttons that submit a code.
  const APPLY_HINTS = ["apply", "add code", "redeem", "submit"];

  function textOf(el) {
    if (!el) return "";
    return (
      (el.getAttribute && (el.getAttribute("aria-label") || "")) + " " +
      (el.getAttribute && (el.getAttribute("placeholder") || "")) + " " +
      (el.getAttribute && (el.getAttribute("name") || "")) + " " +
      (el.id || "") + " " +
      (el.className && el.className.baseVal !== undefined ? "" : el.className || "") + " " +
      (el.textContent || "")
    ).toLowerCase();
  }

  function isVisible(el) {
    if (!el) return false;
    const rect = el.getBoundingClientRect();
    if (rect.width < 2 || rect.height < 2) return false;
    const style = window.getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none" && style.opacity !== "0";
  }

  // Does this page look like a cart/checkout at all?
  function looksLikeCheckout() {
    const url = location.href.toLowerCase();
    if (/(checkout|\/cart|\/bag|payment|order|basket)/.test(url)) return true;
    const bodyText = (document.body ? document.body.innerText : "").toLowerCase();
    const hits = ["order summary", "order total", "promo code", "coupon code",
      "proceed to checkout", "place order", "billing address"]
      .filter((w) => bodyText.includes(w)).length;
    return hits >= 2;
  }

  // Find the most promo-code-like visible text input.
  function findPromoInput() {
    const inputs = Array.from(
      document.querySelectorAll('input[type="text"], input:not([type]), input[type="search"], input[type="tel"]')
    ).filter(isVisible);
    let best = null, bestScore = 0;
    for (const input of inputs) {
      const hay = textOf(input) + " " + textOf(input.closest("label,div,form,section") || {});
      let score = 0;
      for (const hint of PROMO_HINTS) if (hay.includes(hint)) score += hint === "code" ? 1 : 3;
      // Penalize obvious non-promo fields.
      if (/(email|search|address|city|zip|postal|phone|card|cvv|expir|name)/.test(hay)) score -= 4;
      if (score > bestScore) { bestScore = score; best = input; }
    }
    return bestScore >= 3 ? best : null;
  }

  // Find the apply button nearest a given input.
  function findApplyButton(nearInput) {
    const scope = (nearInput && nearInput.closest("form,div,section")) || document.body;
    const candidates = Array.from(scope.querySelectorAll('button, input[type="submit"], a[role="button"], [role="button"]'))
      .filter(isVisible);
    let best = null, bestScore = 0;
    for (const btn of candidates) {
      const hay = textOf(btn);
      let score = 0;
      for (const hint of APPLY_HINTS) if (hay.includes(hint)) score += 3;
      if (/(checkout|place order|continue|pay now|buy)/.test(hay)) score -= 5;
      if (score > bestScore) { bestScore = score; best = btn; }
    }
    return best;
  }

  // Parse a currency figure out of a string. Returns number or null.
  function parseMoney(str) {
    if (!str) return null;
    const m = String(str).replace(/[ ,]/g, "").match(/(\d+(?:\.\d{1,2})?)/);
    return m ? parseFloat(m[1]) : null;
  }

  // Find the element that most likely shows the order total, return {el, value}.
  function findTotal() {
    const nodes = Array.from(document.querySelectorAll("*")).filter((el) => {
      if (!isVisible(el) || el.children.length > 3) return false;
      const t = (el.textContent || "").trim();
      return /[$£€]\s?\d/.test(t) && t.length < 40;
    });
    let best = null, bestScore = -1, bestVal = null;
    for (const el of nodes) {
      const context = textOf(el) + " " + textOf(el.parentElement || {}) +
        " " + textOf(el.previousElementSibling || {});
      let score = 0;
      TOTAL_HINTS.forEach((h, i) => { if (context.includes(h)) score += (TOTAL_HINTS.length - i); });
      const val = parseMoney(el.textContent);
      if (val == null) continue;
      if (score > bestScore) { bestScore = score; best = el; bestVal = val; }
    }
    return best ? { el: best, value: bestVal } : null;
  }

  window.SmartCartDetect = {
    looksLikeCheckout,
    findPromoInput,
    findApplyButton,
    findTotal,
    parseMoney,
    isVisible
  };
})();
