/* options.js — persist settings to chrome.storage.sync; clear data on demand. */

const FIELDS = ["serpApiKey", "shippingEstimate", "couponsEnabled", "compareEnabled"];

function showSaved() {
  const el = document.getElementById("saved");
  el.hidden = false;
  clearTimeout(showSaved._t);
  showSaved._t = setTimeout(() => (el.hidden = true), 1200);
}

async function load() {
  const s = await chrome.storage.sync.get({
    serpApiKey: "",
    shippingEstimate: 0,
    couponsEnabled: true,
    compareEnabled: true
  });
  document.getElementById("serpApiKey").value = s.serpApiKey;
  document.getElementById("shippingEstimate").value = s.shippingEstimate || "";
  document.getElementById("couponsEnabled").checked = s.couponsEnabled;
  document.getElementById("compareEnabled").checked = s.compareEnabled;
}

function save() {
  const data = {
    serpApiKey: document.getElementById("serpApiKey").value.trim(),
    shippingEstimate: parseFloat(document.getElementById("shippingEstimate").value) || 0,
    couponsEnabled: document.getElementById("couponsEnabled").checked,
    compareEnabled: document.getElementById("compareEnabled").checked
  };
  chrome.storage.sync.set(data, showSaved);
}

FIELDS.forEach((id) => {
  document.getElementById(id).addEventListener("change", save);
});

document.getElementById("clearData").addEventListener("click", async () => {
  await chrome.storage.local.clear();
  showSaved();
});

load();
