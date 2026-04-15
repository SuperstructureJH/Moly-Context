# Moly Context Hub Chrome Extension

This extension automatically senses the active Chrome tab's readable DOM content and sends it to the local Moly Context Hub desktop app.

## Load it locally

1. Open `chrome://extensions`
2. Turn on `Developer mode`
3. Click `Load unpacked`
4. Select this folder

## Test flow

1. Open the `Moly Context Hub` desktop app
2. Make sure the toolbar shows the bridge as listening
3. Open any normal Chrome page you want to capture
4. Keep the tab in the foreground for a few seconds
5. Check the app `Activity` panel and local markdown export

## Auto capture behavior

- Captures when the active tab loads or becomes visible
- Re-captures after route changes and meaningful DOM mutations
- Debounces repeated captures to avoid noisy duplicates
- You can still click the extension icon to force one immediate capture

## Notes

- The extension sends data to `http://127.0.0.1:38451/chrome-context`
- It is a local-only bridge for testing
- `chrome://`, extension pages, and other restricted Chrome pages are skipped by design
