(function bootstrapMolyContextSensor() {
  const MIN_PAGE_CAPTURE_INTERVAL_MS = 8000;
  const MUTATION_DEBOUNCE_MS = 2000;
  const SCROLL_DEBOUNCE_MS = 1400;

  let mutationTimer = null;
  let scrollTimer = null;
  let lastFingerprint = "";
  let lastSentAt = 0;

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "CAPTURE_NOW") {
      return false;
    }

    try {
      postSnapshot(message.reason || "message", Boolean(message.force));
      sendResponse({ ok: true });
    } catch (error) {
      console.error("Moly Context Hub content capture failed:", error);
      sendResponse({ ok: false, error: String(error) });
    }
    return false;
  });

  scheduleCapture("page-ready", 1200);
  window.addEventListener("focus", () => scheduleCapture("window-focus", 400), true);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      scheduleCapture("visible", 250);
    }
  }, true);
  window.addEventListener("pageshow", () => scheduleCapture("pageshow", 400), true);
  window.addEventListener("hashchange", () => scheduleCapture("hashchange", 800), true);
  window.addEventListener("popstate", () => scheduleCapture("popstate", 800), true);
  window.addEventListener("scroll", () => {
    if (document.visibilityState !== "visible") {
      return;
    }
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => postSnapshot("scroll"), SCROLL_DEBOUNCE_MS);
  }, { passive: true });

  instrumentHistory();
  observeMutations();

  function instrumentHistory() {
    const originalPushState = history.pushState.bind(history);
    history.pushState = function pushStateProxy(...args) {
      const result = originalPushState(...args);
      scheduleCapture("pushState", 800);
      return result;
    };

    const originalReplaceState = history.replaceState.bind(history);
    history.replaceState = function replaceStateProxy(...args) {
      const result = originalReplaceState(...args);
      scheduleCapture("replaceState", 800);
      return result;
    };
  }

  function observeMutations() {
    if (!document.body) {
      scheduleCapture("await-body", 1200);
      return;
    }

    const observer = new MutationObserver(() => {
      if (document.visibilityState !== "visible") {
        return;
      }
      clearTimeout(mutationTimer);
      mutationTimer = setTimeout(() => postSnapshot("mutation"), MUTATION_DEBOUNCE_MS);
    });

    observer.observe(document.body, {
      childList: true,
      subtree: true,
      characterData: true
    });
  }

  function scheduleCapture(reason, delay = 0) {
    setTimeout(() => postSnapshot(reason), delay);
  }

  function postSnapshot(reason, force = false) {
    if (document.visibilityState !== "visible" && !force) {
      return;
    }

    const payload = extractPageContext(reason);
    const fingerprint = fingerprintSnapshot(payload);
    const now = Date.now();
    if (!force && fingerprint === lastFingerprint && now - lastSentAt < MIN_PAGE_CAPTURE_INTERVAL_MS) {
      return;
    }

    lastFingerprint = fingerprint;
    lastSentAt = now;

    chrome.runtime.sendMessage({
      type: "PAGE_CONTEXT_SNAPSHOT",
      reason,
      force,
      payload
    }, () => {
      if (chrome.runtime.lastError) {
        // The desktop bridge may not be available yet; fail quietly on the page.
      }
    });
  }

  function extractPageContext(reason) {
    const siteAdapter = pickSiteAdapter(window.location.hostname);
    const bodyText = siteAdapter();
    const selectedText = normalizeText(window.getSelection()?.toString() || "").slice(0, 4000);
    const metaDescription = normalizeText(
      document.querySelector('meta[name="description"]')?.getAttribute("content") ||
      document.querySelector('meta[property="og:description"]')?.getAttribute("content") ||
      ""
    ).slice(0, 4000);
    const visibleText = extractVisibleViewportText().slice(0, 6000);
    const contentText = truncate(bodyText || visibleText || metaDescription || selectedText || document.title || "", 16000);

    return {
      browserName: "Google Chrome",
      title: document.title || "Untitled Page",
      url: window.location.href,
      hostname: window.location.hostname,
      selectionText: selectedText,
      metaDescription,
      visibleText,
      contentText,
      captureReason: reason,
      capturedAt: new Date().toISOString()
    };
  }

  function extractVisibleViewportText() {
    const candidates = [];
    const selectors = [
      "main",
      '[role="main"]',
      "article",
      ".ProseMirror",
      ".ql-editor",
      ".doc-content",
      ".wiki-content",
      ".text-content",
      ".markdown-body",
      ".message-list",
      ".chat-messages"
    ];

    for (const selector of selectors) {
      for (const node of document.querySelectorAll(selector)) {
        const rect = safeRect(node);
        if (!isVisibleRect(rect)) {
          continue;
        }
        const text = normalizeText(node.innerText || node.textContent || "");
        if (text.length >= 40) {
          candidates.push({ text, score: scoreViewportNode(node, rect, text) });
        }
      }
    }

    if (!candidates.length) {
      const visibleLeaves = Array.from(document.querySelectorAll("p, h1, h2, h3, li, pre, code, blockquote, td, th, span, div"))
        .map((node) => ({ node, rect: safeRect(node) }))
        .filter(({ node, rect }) => isVisibleLeaf(node, rect))
        .map(({ node, rect }) => ({
          text: normalizeText(node.innerText || node.textContent || ""),
          score: rect.top >= 0 && rect.top < window.innerHeight ? 500 - rect.top : 0
        }))
        .filter((entry) => entry.text.length >= 20);

      visibleLeaves.sort((left, right) => right.score - left.score);
      const joined = visibleLeaves.slice(0, 40).map((entry) => entry.text).join("\n\n");
      return truncate(joined, 8000);
    }

    candidates.sort((left, right) => right.score - left.score);
    return truncate(candidates[0].text, 8000);
  }

  function pickSiteAdapter(hostname) {
    const lower = hostname.toLowerCase();

    if (lower.includes("chatgpt.com")) {
      return () => extractFromSelectors([
        "main [data-message-author-role]",
        "main article",
        "main"
      ]);
    }

    if (lower.includes("claude.ai")) {
      return () => extractFromSelectors([
        'main [data-testid="conversation-turn"]',
        "main article",
        "main"
      ]);
    }

    if (lower.includes("feishu.cn") || lower.includes("larkoffice.com")) {
      return () => extractFromSelectors([
        '[role="main"]',
        "main",
        ".doc-content",
        ".wiki-content",
        ".ql-editor",
        ".ProseMirror",
        ".text-content"
      ]);
    }

    return extractGenericMainText;
  }

  function extractFromSelectors(selectors) {
    for (const selector of selectors) {
      const nodes = Array.from(document.querySelectorAll(selector));
      if (!nodes.length) {
        continue;
      }

      const text = nodes
        .map((node) => normalizeText(node.innerText || node.textContent || ""))
        .filter((value) => value.length >= 20)
        .join("\n\n")
        .trim();

      if (text.length >= 40) {
        return truncate(text, 16000);
      }
    }

    return extractGenericMainText();
  }

  function extractGenericMainText() {
    const candidates = [];
    const selectors = ["main", '[role="main"]', "article", ".main", ".content", "#content"];

    for (const selector of selectors) {
      for (const node of document.querySelectorAll(selector)) {
        const text = normalizeText(node.innerText || node.textContent || "");
        if (text.length >= 80) {
          candidates.push({ text, score: scoreNode(node, text) });
        }
      }
    }

    if (!candidates.length) {
      const bodyClone = document.body.cloneNode(true);
      for (const selector of ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside"]) {
        bodyClone.querySelectorAll(selector).forEach((node) => node.remove());
      }
      const text = normalizeText(bodyClone.innerText || bodyClone.textContent || "");
      if (text.length >= 20) {
        return truncate(text, 16000);
      }

      return "";
    }

    candidates.sort((left, right) => right.score - left.score);
    return truncate(candidates[0].text, 16000);
  }

  function scoreNode(node, text) {
    const rect = safeRect(node);
    let score = text.length;

    if (rect.width > window.innerWidth * 0.35) {
      score += 600;
    }
    if (rect.height > window.innerHeight * 0.3) {
      score += 400;
    }
    if (rect.top < 120) {
      score -= 180;
    }
    if (rect.left < window.innerWidth * 0.12) {
      score -= 120;
    }
    if (node.matches("main, article, [role='main']")) {
      score += 800;
    }

    return score;
  }

  function scoreViewportNode(node, rect, text) {
    let score = text.length;
    const centerDistance = Math.abs((rect.top + rect.height / 2) - (window.innerHeight / 2));
    score += Math.max(0, 600 - centerDistance);

    if (rect.width > window.innerWidth * 0.42) {
      score += 400;
    }
    if (rect.height > 180) {
      score += 300;
    }
    if (node.matches("main, article, [role='main'], .ProseMirror, .ql-editor")) {
      score += 900;
    }

    return score;
  }

  function isVisibleLeaf(node, rect) {
    if (!isVisibleRect(rect)) {
      return false;
    }
    if (rect.width < 40 || rect.height < 16) {
      return false;
    }
    if (node.children.length > 3) {
      return false;
    }
    return true;
  }

  function isVisibleRect(rect) {
    if (!rect) {
      return false;
    }
    return rect.bottom > 0 &&
      rect.right > 0 &&
      rect.top < window.innerHeight &&
      rect.left < window.innerWidth;
  }

  function safeRect(node) {
    try {
      return node.getBoundingClientRect();
    } catch (_error) {
      return null;
    }
  }

  function fingerprintSnapshot(payload) {
    const title = normalizeText(payload?.title || "");
    const url = normalizeText(payload?.url || "");
    const content = normalizeText(payload?.contentText || "").slice(0, 3000);
    const visible = normalizeText(payload?.visibleText || "").slice(0, 2000);
    return hashString([title, url, content, visible].join("|"));
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

  function truncate(text, limit) {
    if (text.length <= limit) {
      return text;
    }
    return `${text.slice(0, limit)}...`;
  }
})();
