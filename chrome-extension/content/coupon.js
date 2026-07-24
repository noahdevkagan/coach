/*
 * coupon.js — coupon finder + live verifier.
 *
 * Flow:
 *  1. Detect a checkout/cart page and a promo-code field.
 *  2. Ask the background worker for known codes for this domain.
 *  3. Offer to test them: for each code, record the order total, apply,
 *     read the new total, keep the code that yields the biggest real drop,
 *     and leave the best working code applied.
 *  4. Report verified savings to the background worker (savings log + cache).
 */
(function () {
  "use strict";
  const D = window.SmartCartDetect;
  if (!D) return;

  const registrableDomain = (() => {
    const parts = location.hostname.replace(/^www\./, "").split(".");
    return parts.length > 2 ? parts.slice(-2).join(".") : parts.join(".");
  })();

  let panel = null;
  let running = false;

  function sleep(ms) {
    return new Promise((r) => setTimeout(r, ms));
  }

  function setNativeValue(input, value) {
    const proto = Object.getPrototypeOf(input);
    const setter = Object.getOwnPropertyDescriptor(proto, "value");
    if (setter && setter.set) setter.set.call(input, value);
    else input.value = value;
    input.dispatchEvent(new Event("input", { bubbles: true }));
    input.dispatchEvent(new Event("change", { bubbles: true }));
  }

  // Wait until the total element's value settles or timeout.
  async function readTotalAfterChange(baseline, timeoutMs = 6000) {
    const start = Date.now();
    let last = baseline;
    while (Date.now() - start < timeoutMs) {
      await sleep(400);
      const t = D.findTotal();
      if (t && t.value != null) {
        last = t.value;
        if (Math.abs(t.value - baseline) > 0.001) return t.value;
      }
    }
    return last;
  }

  async function applyCode(input, applyBtn, code) {
    input.focus();
    setNativeValue(input, code);
    await sleep(150);
    if (applyBtn) {
      applyBtn.click();
    } else {
      input.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Enter", keyCode: 13, bubbles: true })
      );
    }
  }

  async function testCoupons(codes) {
    if (running) return;
    running = true;
    const input = D.findPromoInput();
    const applyBtn = D.findApplyButton(input);
    if (!input) {
      status("Couldn't find a coupon field on this page.");
      running = false;
      return;
    }
    const baseTotal = (D.findTotal() || {}).value;
    if (baseTotal == null) {
      status("Couldn't read an order total to verify against. Apply codes manually below.");
      running = false;
      renderList(codes, input, applyBtn, null);
      return;
    }

    let best = { code: null, total: baseTotal };
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      status(`Testing ${i + 1}/${codes.length}: ${c.code} …`);
      await applyCode(input, applyBtn, c.code);
      const newTotal = await readTotalAfterChange(best.total);
      if (newTotal < best.total - 0.001) {
        best = { code: c.code, total: newTotal };
        status(`✓ ${c.code} works — new total ${money(newTotal)}`);
      }
      await sleep(500);
    }

    if (best.code) {
      // Re-apply the winner so it stays on the order.
      status(`Applying best code: ${best.code}`);
      await applyCode(input, applyBtn, best.code);
      const saved = Math.max(0, baseTotal - best.total);
      status(`🎉 Best code ${best.code} — you saved ${money(saved)}`);
      chrome.runtime.sendMessage({
        type: "COUPON_VERIFIED",
        domain: registrableDomain,
        code: best.code,
        saved,
        total: best.total
      });
    } else {
      status("No code lowered your total. Nothing applied.");
      chrome.runtime.sendMessage({
        type: "COUPONS_FAILED",
        domain: registrableDomain,
        codes: codes.map((c) => c.code)
      });
    }
    running = false;
  }

  // ---------- UI ----------
  function money(n) {
    return "$" + Number(n).toFixed(2);
  }

  function ensurePanel() {
    if (panel) return panel;
    panel = document.createElement("div");
    panel.className = "smartcart-panel";
    panel.innerHTML = `
      <div class="sc-head">
        <span class="sc-logo">🛒 SmartCart</span>
        <button class="sc-close" title="Hide">×</button>
      </div>
      <div class="sc-body"></div>
      <div class="sc-status"></div>`;
    document.documentElement.appendChild(panel);
    panel.querySelector(".sc-close").addEventListener("click", () => panel.remove());
    return panel;
  }

  function status(msg) {
    const el = ensurePanel().querySelector(".sc-status");
    el.textContent = msg;
  }

  function renderList(codes, input, applyBtn, baseTotal) {
    const body = ensurePanel().querySelector(".sc-body");
    body.innerHTML = "";
    codes.forEach((c) => {
      const row = document.createElement("div");
      row.className = "sc-code-row";
      row.innerHTML = `<code>${c.code}</code><span class="sc-desc">${c.desc || ""}</span>`;
      const btn = document.createElement("button");
      btn.textContent = "Apply";
      btn.className = "sc-apply-one";
      btn.addEventListener("click", () => applyCode(input, applyBtn, c.code));
      row.appendChild(btn);
      body.appendChild(row);
    });
  }

  function offer(codes) {
    const p = ensurePanel();
    const body = p.querySelector(".sc-body");
    body.innerHTML = "";
    const head = document.createElement("div");
    head.className = "sc-offer";
    head.textContent = `${codes.length} coupon${codes.length > 1 ? "s" : ""} found for ${registrableDomain}`;
    const testBtn = document.createElement("button");
    testBtn.className = "sc-test-all";
    testBtn.textContent = "Find best & apply";
    testBtn.addEventListener("click", () => testCoupons(codes));
    body.appendChild(head);
    body.appendChild(testBtn);
    const input = D.findPromoInput();
    renderListBelow(codes, input, D.findApplyButton(input));
  }

  function renderListBelow(codes, input, applyBtn) {
    const list = document.createElement("div");
    list.className = "sc-list";
    ensurePanel().querySelector(".sc-body").appendChild(list);
    codes.forEach((c) => {
      const row = document.createElement("div");
      row.className = "sc-code-row";
      row.innerHTML = `<code>${c.code}</code><span class="sc-desc">${c.desc || ""}</span>`;
      const btn = document.createElement("button");
      btn.textContent = "Apply";
      btn.className = "sc-apply-one";
      btn.addEventListener("click", () => applyCode(input, applyBtn, c.code));
      row.appendChild(btn);
      list.appendChild(row);
    });
  }

  // ---------- init ----------
  async function init() {
    const settings = await chrome.storage.sync.get({ couponsEnabled: true });
    if (!settings.couponsEnabled) return;
    if (!D.looksLikeCheckout()) return;
    if (!D.findPromoInput()) return;

    chrome.runtime.sendMessage(
      { type: "GET_COUPONS", domain: registrableDomain },
      (resp) => {
        if (chrome.runtime.lastError) return;
        const codes = (resp && resp.codes) || [];
        if (codes.length) offer(codes);
      }
    );
  }

  // Checkout pages are dynamic; retry a few times as the DOM settles.
  let tries = 0;
  const timer = setInterval(() => {
    tries++;
    if (panel || tries > 8) {
      clearInterval(timer);
      return;
    }
    init();
  }, 1500);
  init();

  // Allow the popup to trigger a run on demand.
  chrome.runtime.onMessage.addListener((msg, _s, sendResponse) => {
    if (msg.type === "RUN_COUPON_SCAN") {
      init();
      sendResponse({ ok: true });
    }
    return true;
  });
})();
