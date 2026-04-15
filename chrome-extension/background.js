const DEFAULT_SERVER_URL = "http://127.0.0.1:38451/chrome-context";
const DEFAULT_SETTINGS = {
  serverUrl: DEFAULT_SERVER_URL,
  autoCaptureEnabled: true
};
const MIN_CAPTURE_INTERVAL_MS = 12000;
const MAX_DEDUP_WINDOW_MS = 5 * 60 * 1000;

const tabState = new Map();

chrome.runtime.onInstalled.addListener(async () => {
  await chrome.storage.local.set(DEFAULT_SETTINGS);
});

chrome.runtime.onStartup.addListener(async () => {
  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  if (typeof settings.autoCaptureEnabled !== "boolean") {
    await chrome.storage.local.set(DEFAULT_SETTINGS);
  }
});

chrome.action.onClicked.addListener(async (tab) => {
  if (!tab.id || !tab.url) {
    return;
  }

  if (isRestrictedUrl(tab.url)) {
    console.warn("Moly Context Hub skipped restricted URL:", tab.url);
    await flashBadge(tab.id, "SKIP", "#64748b");
    return;
  }

  const delivered = await requestCapture(tab.id, "manual", true);
  if (!delivered) {
    await flashBadge(tab.id, "WAIT", "#64748b");
  }
});

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  await requestCapture(tabId, "activated");
});

chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (changeInfo.status !== "complete" || !tab.active || !tab.url || isRestrictedUrl(tab.url)) {
    return;
  }

  await requestCapture(tabId, "updated");
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) {
    return;
  }

  const [activeTab] = await chrome.tabs.query({ active: true, windowId });
  if (!activeTab?.id) {
    return;
  }

  await requestCapture(activeTab.id, "window-focus");
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.type === "PAGE_CONTEXT_SNAPSHOT") {
    void handleSnapshot(message.payload, sender.tab, Boolean(message.force), message.reason)
      .then(() => sendResponse({ ok: true }))
      .catch(async (error) => {
        console.error("Moly Context Hub auto capture failed:", error);
        if (sender.tab?.id) {
          await flashBadge(sender.tab.id, "ERR", "#d14343");
        }
        sendResponse({ ok: false, error: String(error) });
      });
    return true;
  }

  return false;
});

async function requestCapture(tabId, reason, force = false) {
  try {
    await chrome.tabs.sendMessage(tabId, {
      type: "CAPTURE_NOW",
      reason,
      force
    });
    return true;
  } catch (error) {
    const message = String(error);
    if (!message.includes("Receiving end does not exist")) {
      console.warn("Moly Context Hub could not request capture:", error);
    }
    return false;
  }
}

async function handleSnapshot(payload, tab, force, reason) {
  if (!tab?.id || !tab.url || isRestrictedUrl(tab.url)) {
    return;
  }

  const settings = await chrome.storage.local.get(DEFAULT_SETTINGS);
  if (!settings.autoCaptureEnabled && !force) {
    return;
  }

  const [latestTab, window] = await Promise.all([
    chrome.tabs.get(tab.id),
    chrome.windows.get(tab.windowId)
  ]);
  if (!latestTab.active || !window.focused) {
    return;
  }

  const fingerprint = fingerprintSnapshot(payload);
  const previousState = tabState.get(tab.id);
  const now = Date.now();
  if (!force && previousState) {
    const sameFingerprint = previousState.fingerprint === fingerprint;
    const withinDedupeWindow = now - previousState.sentAt < MAX_DEDUP_WINDOW_MS;
    if (sameFingerprint && withinDedupeWindow) {
      return;
    }
    const sameUrl = previousState.url === payload.url;
    const withinInterval = now - previousState.sentAt < MIN_CAPTURE_INTERVAL_MS;
    if (sameUrl && withinInterval) {
      return;
    }
  }

  const response = await fetch(settings.serverUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(errorText || `Bridge returned ${response.status}`);
  }

  tabState.set(tab.id, { fingerprint, sentAt: now, reason, url: payload.url });
  await flashBadge(tab.id, force ? "NOW" : "AUTO", "#1f9d55");
}

function fingerprintSnapshot(payload) {
  const title = normalizeText(payload?.title || "");
  const url = normalizeText(payload?.url || "");
  const selection = normalizeText(payload?.selectionText || "").slice(0, 400);
  const content = normalizeText(payload?.contentText || "").slice(0, 4000);
  return hashString([title, url, selection, content].join("|"));
}

function hashString(input) {
  let hash = 5381;
  for (let index = 0; index < input.length; index += 1) {
    hash = ((hash << 5) + hash) ^ input.charCodeAt(index);
  }
  return String(hash >>> 0);
}

function normalizeText(text) {
  return (text || "")
    .replace(/\u0000/g, "")
    .replace(/\r/g, "\n")
    .split("\n")
    .map((line) => line.replace(/\s+/g, " ").trim())
    .filter(Boolean)
    .join("\n")
    .trim();
}

function isRestrictedUrl(url) {
  return /^(chrome|chrome-extension|devtools|edge|about):\/\//i.test(url);
}

async function flashBadge(tabId, text, color) {
  await chrome.action.setBadgeBackgroundColor({ tabId, color });
  await chrome.action.setBadgeText({ tabId, text });
  setTimeout(() => {
    chrome.action.setBadgeText({ tabId, text: "" });
  }, 2200);
}
