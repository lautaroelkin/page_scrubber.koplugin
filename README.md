# Page Scrubber Plugin! 
This plugin allows you to quickly flip back and forth through the book, with the option to easily return to your original page using the 'x' button or stay on the new page. You can also use the interactive progress bar and bookmark browser. Streamlined, E-ink optimized, based on KOReader's browser architecture and inspired by the native Kindle page picker experience. Compatible with EPUB, CBZ, and PDFs!
   
### Features
*   **Thumbnail Grids:** Live 3-page and 6-page previews, plus a minimalist distraction-free "Simple Grid" mode.
*   **Interactive Index:** A dedicated visual Table of Contents view with its own progress bar for easy chapter navigation.
*   **Advanced Navigation:** Interactive progress slider, chapter-skip buttons, a quick-access top toolbar, and physical D-Pad support.
*   **Split-View Annotations:** A beautiful split-screen manager for Bookmarks, Highlights, and Notes, featuring a live high-res page preview and smart highlight filters.
*   **Redesigned Reading Pop-Ups (NEW):** Features a modern, pill-shaped floating dictionary and multi-word selection menu. It intelligently anchors away from your finger so it never blocks your text. Fully compatible with the AI Assistant, X-Ray, and other external plugins.
*   **Robust Customization (NEW):** Auto-adapting layout with dynamic UI Scaling and customizable Text Size (Small/Medium/Large) that prevents crashes or overlapping at any resolution.
*   **Markdown Export:** Export your highlights and notes directly to a `.md` file on your device.
*   **Native Integration:** Launch all widgets and access settings directly from KOReader's native top menu, or bind them to your own custom gestures.

---

### How different is this from the stock Skim widget and Page browser?

While it achieves similar goals as the stock tools, it merges the Page Browser and Skim Widget into a single, fluid, and highly interactive workflow.

Here is what it does differently:
*   **Smarter Rendering:** The 3-grid renders images one by one instead of processing all pages at once, making it significantly smoother.
*   **Hold to Flip:** Introduces a "hold" action to quickly scrub through pages.
*   **Classic "Simple Grid":** A transparent, older-Kindle inspired grid. Tap outside the window to instantly cancel and return to your original page.
*   **Instant Switching:** Jump seamlessly between the 3-page and 6-page grids with a single tap, no menus required.
*   **Integrated TOC & Annotations:** View chapters, bookmarks, highlights, and notes on the fly while simultaneously looking at the live page preview.

Basically, it takes the native features, removes the friction, and puts them into a streamlined tool. Give it a try!

> ⚠️¡! **IMPORTANT:** You MUST delete any old or duplicate `.lua` scrubber/browser files from your KOReader plugins/patches folder before installing this new version.

> ⚠️¡! **Compatibility Note:** Page Scrubber is *not* compatible with the `2-reader-header.lua` user patch (it will cause blank thumbnails). If you want a reading header, please use the official **Bookend** plugin instead, which is 100% compatible.

**[Get the plugin in the Releases page!]**

---

## 📱 Screenshots

<table align="center" width="100%">
  <tr>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-GridView.jpg" width="100%" alt="Grid View"/><br>
      <b>Grid View</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-SimpleGridView.jpg" width="100%" alt="Simple Grid View"/><br>
      <b>Simple Grid</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-SixGridView.jpg" width="100%" alt="Six Grid View"/><br>
      <b>Six Grid</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-Index.jpg" width="100%" alt="Index"/><br>
      <b>Index</b>
    </td>
  </tr>
  <tr>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-Bookmarks.jpg" width="100%" alt="Bookmarks"/><br>
      <b>Bookmarks</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-Highlights.jpg" width="100%" alt="Highlights"/><br>
      <b>Highlights</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-Dictionary.jpg" width="100%" alt="Dictionary Pop-up"/><br>
      <b>Dictionary</b>
    </td>
    <td align="center" width="25%" valign="top">
      <img src="images/PageScrubber-Menu.jpg" width="100%" alt="Menu"/><br>
      <b>Export your notes!</b>
    </td>
  </tr>
</table>

---

## ⚙️ Installation
 1. Go to the **Releases** page and download the `.zip` file of the latest version.
 2. Extract the archive. You will get a folder named `page_scrubber.koplugin`.
 3. Place that entire folder in your KOReader user plugins directory (usually `koreader/plugins/`).
 4. Restart KOReader.
   
## 🚀 Setup & Activation
 1. Open a book in KOReader.
 2. Go to **Settings** (⚙️) > **Gestures** > **Reader**.
 3. Choose your preferred gesture and bind it to any of the available actions: **Page browser: Grid**, **Page browser: Simple grid**, **Page browser: Multi-grid**, **Page browser: Menu (BM)**, **Page browser: Menu (highlights)**, or **Page browser: Index**.

> 💡 **Tip:** You don't *have* to use gestures! You can also launch all views and access the new configuration options directly from KOReader's top menu.

> You can only run one patch of this collection at a time; if you try to activate more than one, it won't work.
