/* popup.js — wires toggles, stats, and the manual scan button. */

function money(n) {
  return "$" + Number(n || 0).toFixed(2);
}

function timeAgo(ts) {
  const s = Math.floor((Date.now() - ts) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

async function loadToggles() {
  const s = await chrome.storage.sync.get({ couponsEnabled: true, compareEnabled: true });
  document.getElementById("couponsEnabled").checked = s.couponsEnabled;
  document.getElementById("compareEnabled").checked = s.compareEnabled;
}

function bindToggle(id) {
  document.getElementById(id).addEventListener("change", (e) => {
    chrome.storage.sync.set({ [id]: e.target.checked });
  });
}

function loadStats() {
  chrome.runtime.sendMessage({ type: "GET_STATS" }, (resp) => {
    if (chrome.runtime.lastError || !resp) return;
    document.getElementById("totalSaved").textContent = money(resp.totalSaved);
    const list = document.getElementById("logList");
    const log = resp.savingsLog || [];
    if (!log.length) return;
    list.innerHTML = "";
    log.slice(0, 12).forEach((e) => {
      const li = document.createElement("li");
      li.innerHTML = `<span>${e.domain} · <code>${e.code}</code> <span class="muted">${timeAgo(e.at)}</span></span>
                      <span class="win">${money(e.saved)}</span>`;
      list.appendChild(li);
    });
  });
}

document.getElementById("scanBtn").addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return;
  chrome.tabs.sendMessage(tab.id, { type: "RUN_COUPON_SCAN" }, () => {
    void chrome.runtime.lastError; // ignore if no content script on this page
    window.close();
  });
});

document.getElementById("optionsLink").addEventListener("click", (e) => {
  e.preventDefault();
  chrome.runtime.openOptionsPage();
});

loadToggles();
bindToggle("couponsEnabled");
bindToggle("compareEnabled");
loadStats();
